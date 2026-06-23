-- =====================================================================
-- Forest Coffee CTRM — MOTOR DE ESCRITURA de fixings (apply_fixing)
-- =====================================================================
--  Auto-distribuye una compra/fixing entre posiciones abiertas, sin
--  asignación manual. Dos cubetas por mes KC:
--    • BOLSA    → reparte proporcional entre HEDGES abiertos → hedge_closures
--    • NO BOLSA → reparte proporcional entre CONTRATOS fijados sin hedge
--                 → commercial_closures (P&L comercial, separado)
--  Reparto: proporcional con "resto mayor" (suma exacta al saco).
--  Sobre-fijación: BLOQUEADA en ambas cubetas.
--
--  ⚠️ SEGURIDAD
--   - apply_fixing(...) tiene p_dry_run = TRUE por defecto → NO escribe;
--     solo devuelve el reparto. Para escribir, pasar p_dry_run := false.
--   - Todo fixing real queda bajo un batch_id → void_fixing(batch_id) lo
--     deshace por completo (transaccional).
--   - Los cambios de esquema son ADITIVOS (add column if not exists,
--     create table/ view if not exists). No alteran datos existentes.
--
--  ORDEN SUGERIDO PARA CORRERLO EN SUPABASE (ver notas al final):
--    1) Bloque ESQUEMA   2) Bloque FUNCIONES   3) Prueba en dry-run
-- =====================================================================


-- ─────────────────────────────────────────────────────────────────────
-- 1) ESQUEMA (aditivo, no toca datos)
-- ─────────────────────────────────────────────────────────────────────
alter table physical_purchases add column if not exists batch_id text;
alter table hedge_closures     add column if not exists batch_id text;

create table if not exists commercial_closures (
  id               text primary key,
  batch_id         text,
  contract_id      text not null,
  sacos            int  not null,
  precio_kc_fijado numeric not null,   -- referencia fijada del contrato
  precio_kc_cierre numeric not null,   -- mercado al cerrar (= precio del fixing)
  fecha            date not null,
  registrado_por   text default 'auto',
  created_at       timestamptz default now()
);

-- P&L comercial realizado (mismo signo que el no realizado: baja = ganancia)
create or replace view v_pnl_comercial as
select cc.*,
  (cc.precio_kc_fijado - cc.precio_kc_cierre) * cc.sacos * 70 * 2.20462 / 100
    as pnl_comercial_usd
from commercial_closures cc;


-- ─────────────────────────────────────────────────────────────────────
-- 2) FUNCIÓN PRINCIPAL — apply_fixing
--    Decisiones: reparto proporcional en ambas cubetas;
--    precio_kc_cierre de la cubeta no-bolsa = el mismo precio del fixing.
-- ─────────────────────────────────────────────────────────────────────
create or replace function apply_fixing(
  p_kc_month             text,
  p_kc_year              int,
  p_precio_cierre_clb    numeric,        -- precio KC del fixing (c/lb)
  p_precio_compra_usd_lb numeric,        -- precio físico de compra (USD/lb)
  p_fecha                date,
  p_sacos_bolsa          int  default 0, -- sacos a cerrar contra hedges (en bolsa)
  p_sacos_nobolsa        int  default 0, -- sacos a fijar de contratos sin hedge
  p_dry_run              boolean default true   -- TRUE = no escribe (simula)
) returns table (
  cubeta        text,
  ref_id        text,    -- hedge_id (bolsa) o contract_id (no bolsa)
  contrato      text,
  cliente       text,
  sacos         int,
  precio_ref    numeric, -- precio_entrada (bolsa) o precio_kc_fijado (no bolsa)
  pnl_usd       numeric,
  batch_id      text     -- null en dry-run; el lote real si se escribió
)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_total_bolsa   bigint;
  v_total_nobolsa bigint;
  v_batch text := 'BATCH-' || to_char(now(),'YYYYMMDDHH24MISS') || '-' || substr(md5(random()::text),1,4);
  v_n int := 0;
  v_pid text;
  rec record;
begin
  -- Universo BOLSA: hedges abiertos del mes
  create temp table _bolsa on commit drop as
    select h.id as hedge_id, h.contract_id, c.cliente,
           h.precio_entrada_clb, h.sacos_abiertos::int as open_sacos, h.days_to_ltd
    from v_hedge_positions h
    left join contracts c on c.id = h.contract_id
    where h.kc_month = p_kc_month and h.kc_year = p_kc_year and h.sacos_abiertos > 0;
  select coalesce(sum(open_sacos),0) into v_total_bolsa from _bolsa;

  -- Universo NO-BOLSA: contratos fijados con exposición sin hedge
  create temp table _nob on commit drop as
    select c.id as contract_id, c.cliente, c.precio_kc_fijado,
           greatest(c.sacos_abiertos - coalesce(hh.hedge_open,0),0)::int as exp_sacos
    from v_contracts c
    left join (
      select contract_id, sum(sacos_abiertos) as hedge_open
      from v_hedge_positions where sacos_abiertos > 0 group by contract_id
    ) hh on hh.contract_id = c.id
    where c.precio_kc_fijado is not null
      and greatest(c.sacos_abiertos - coalesce(hh.hedge_open,0),0) > 0
      and c.kc_month = p_kc_month and c.kc_year = p_kc_year;
  select coalesce(sum(exp_sacos),0) into v_total_nobolsa from _nob;

  -- Validaciones
  if p_sacos_bolsa <= 0 and p_sacos_nobolsa <= 0 then
    raise exception 'Nada que fijar: indica p_sacos_bolsa y/o p_sacos_nobolsa';
  end if;
  if p_sacos_bolsa > v_total_bolsa then
    raise exception 'Sobre-fijación BOLSA: % > % abiertos en % %',
      p_sacos_bolsa, v_total_bolsa, p_kc_month, p_kc_year;
  end if;
  if p_sacos_nobolsa > v_total_nobolsa then
    raise exception 'Sobre-fijación NO-BOLSA: % > % expuestos en % %',
      p_sacos_nobolsa, v_total_nobolsa, p_kc_month, p_kc_year;
  end if;

  -- Reparto BOLSA (proporcional + resto mayor)
  create temp table _abolsa on commit drop as
  with base as (
    select b.*,
      floor(p_sacos_bolsa::numeric * open_sacos / nullif(v_total_bolsa,0))                                            as fl,
      (p_sacos_bolsa::numeric * open_sacos / nullif(v_total_bolsa,0))
        - floor(p_sacos_bolsa::numeric * open_sacos / nullif(v_total_bolsa,0))                                        as frac
    from _bolsa b
  ),
  ranked as (
    select base.*, sum(fl) over () as suma_fl,
      row_number() over (order by frac desc, days_to_ltd asc nulls last, hedge_id) as rn
    from base
  )
  select hedge_id, contract_id, cliente, precio_entrada_clb,
    (fl + case when rn <= (p_sacos_bolsa - suma_fl) then 1 else 0 end)::int as alloc
  from ranked;

  -- Reparto NO-BOLSA (proporcional + resto mayor)
  create temp table _anob on commit drop as
  with base as (
    select n.*,
      floor(p_sacos_nobolsa::numeric * exp_sacos / nullif(v_total_nobolsa,0))                                         as fl,
      (p_sacos_nobolsa::numeric * exp_sacos / nullif(v_total_nobolsa,0))
        - floor(p_sacos_nobolsa::numeric * exp_sacos / nullif(v_total_nobolsa,0))                                     as frac
    from _nob n
  ),
  ranked as (
    select base.*, sum(fl) over () as suma_fl,
      row_number() over (order by frac desc, contract_id) as rn
    from base
  )
  select contract_id, cliente, precio_kc_fijado,
    (fl + case when rn <= (p_sacos_nobolsa - suma_fl) then 1 else 0 end)::int as alloc
  from ranked;

  -- Escritura (solo si NO es dry-run)
  if not p_dry_run then
    for rec in select * from _abolsa where alloc > 0 loop
      v_n := v_n + 1;
      v_pid := 'PHA-' || v_batch || '-' || v_n;
      insert into physical_purchases
        (id, contract_id, hedge_id, sacos, precio_compra_usd_lb, precio_kc_cierre_clb,
         fecha_compra, tipo, registrado_por, batch_id)
      values
        (v_pid, rec.contract_id, rec.hedge_id, rec.alloc, p_precio_compra_usd_lb, p_precio_cierre_clb,
         p_fecha, 'Purchase', 'auto', v_batch);
      insert into hedge_closures
        (id, hedge_id, contract_id, purchase_id, precio_cierre_clb, precio_entrada_clb,
         sacos, fecha_cierre, tipo_cierre, registrado_por, batch_id)
      values
        ('CLA-'||v_batch||'-'||v_n, rec.hedge_id, rec.contract_id, v_pid, p_precio_cierre_clb,
         rec.precio_entrada_clb, rec.alloc, p_fecha, 'Purchase', 'auto', v_batch);
    end loop;

    for rec in select * from _anob where alloc > 0 loop
      v_n := v_n + 1;
      v_pid := 'PHA-' || v_batch || '-' || v_n;
      insert into physical_purchases
        (id, contract_id, hedge_id, sacos, precio_compra_usd_lb, precio_kc_cierre_clb,
         fecha_compra, tipo, registrado_por, batch_id)
      values
        (v_pid, rec.contract_id, null, rec.alloc, p_precio_compra_usd_lb, p_precio_cierre_clb,
         p_fecha, 'Purchase', 'auto', v_batch);
      insert into commercial_closures
        (id, batch_id, contract_id, sacos, precio_kc_fijado, precio_kc_cierre, fecha, registrado_por)
      values
        ('CC-'||v_batch||'-'||v_n, v_batch, rec.contract_id, rec.alloc, rec.precio_kc_fijado,
         p_precio_cierre_clb, p_fecha, 'auto');
    end loop;
  end if;

  -- Desglose (preview o confirmación)
  return query
    select 'BOLSA'::text, a.hedge_id, a.contract_id, a.cliente, a.alloc, a.precio_entrada_clb,
           round((p_precio_cierre_clb - a.precio_entrada_clb) * a.alloc * 70 * 2.20462 / 100, 2),
           case when p_dry_run then null else v_batch end
    from _abolsa a where a.alloc > 0
    union all
    select 'NO_BOLSA', n.contract_id, n.contract_id, n.cliente, n.alloc, n.precio_kc_fijado,
           round((n.precio_kc_fijado - p_precio_cierre_clb) * n.alloc * 70 * 2.20462 / 100, 2),
           case when p_dry_run then null else v_batch end
    from _anob n where n.alloc > 0;
end;
$$;


-- ─────────────────────────────────────────────────────────────────────
-- 3) ANULAR un fixing completo por lote (transaccional)
-- ─────────────────────────────────────────────────────────────────────
create or replace function void_fixing(p_batch_id text)
returns text
language plpgsql
as $$
declare n1 int; n2 int; n3 int;
begin
  delete from hedge_closures      where batch_id = p_batch_id;  get diagnostics n1 = row_count;
  delete from commercial_closures where batch_id = p_batch_id;  get diagnostics n2 = row_count;
  delete from physical_purchases  where batch_id = p_batch_id;  get diagnostics n3 = row_count;  -- al final (FK purchase_id)
  if n1 + n2 + n3 = 0 then
    raise exception 'Lote % no encontrado (nada que anular)', p_batch_id;
  end if;
  return format('Anulado %s: %s cierres hedge, %s cierres comerciales, %s compras', p_batch_id, n1, n2, n3);
end;
$$;


-- =====================================================================
-- USO Y ROLLOUT SEGURO
-- =====================================================================
-- A) SIMULAR (no escribe nada — p_dry_run = true por defecto):
--    select * from apply_fixing('U', 2026, 264.00, 3.10, current_date,
--                               200 /*bolsa*/, 100 /*no bolsa*/);
--
-- B) Probar la guarda de sobre-fijación (debe dar ERROR controlado):
--    select * from apply_fixing('U', 2026, 264.00, 3.10, current_date, 999999, 0);
--
-- C) ESCRIBIR de verdad (¡toma backup antes!):  pasar p_dry_run := false
--    select * from apply_fixing('U', 2026, 264.00, 3.10, current_date,
--                               200, 100, false);
--    -- guarda el batch_id que devuelve para poder anular.
--
-- D) ANULAR ese fixing por completo:
--    select void_fixing('BATCH-20260623....');
--
-- E) VALIDACIÓN EN PARALELO (después de escribir): la suma debe cuadrar
--    select sum(sacos) from hedge_closures      where batch_id = '...';  -- = p_sacos_bolsa
--    select sum(sacos) from commercial_closures where batch_id = '...';  -- = p_sacos_nobolsa
--
-- Quitar todo (no afecta datos previos; solo borra columnas/funciones nuevas):
--   drop function if exists apply_fixing(text,int,numeric,numeric,date,int,int,boolean);
--   drop function if exists void_fixing(text);
--   drop view if exists v_pnl_comercial;
--   drop table if exists commercial_closures;
--   alter table physical_purchases drop column if exists batch_id;
--   alter table hedge_closures     drop column if exists batch_id;
-- =====================================================================
