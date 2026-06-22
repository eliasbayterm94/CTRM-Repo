-- =====================================================================
-- Forest Coffee CTRM — SIMULACIÓN de fixing (DRY-RUN, 100% SOLO LECTURA)
-- =====================================================================
--  ⚠️ SEGURIDAD: este archivo NO inserta, NO actualiza y NO borra nada.
--  Solo CONSULTA (SELECT). Es seguro ejecutarlo en producción: muestra
--  cómo se repartiría un fixing entre los hedges abiertos, sin tocar la
--  data. Nada cambia hasta que decidamos pasar al motor real (otra fase).
--
--  Reparto: proporcional a sacos_abiertos, con método de "resto mayor"
--  para que la suma cuadre EXACTA al saco. Bloquea la sobre-fijación.
-- =====================================================================


-- ---------------------------------------------------------------------
-- OPCIÓN A — CONSULTA SUELTA (no crea nada; pégala y córrela)
-- ---------------------------------------------------------------------
-- Edita los 4 valores de abajo y ejecuta. Cambia SOLO el bloque 'params'.

with params as (
  select
    'K'::text        as kc_month,          -- mes KC a fijar
    2026::int        as kc_year,           -- año KC
    300::int         as sacos,             -- sacos totales del fixing
    185.40::numeric  as precio_cierre_clb  -- precio KC de cierre (c/lb)
),
open_hedges as (
  select h.id as hedge_id, h.contract_id, c.cliente,
         h.precio_entrada_clb, h.sacos_abiertos as open_sacos,
         h.days_to_ltd
  from v_hedge_positions h
  left join contracts c on c.id = h.contract_id
  cross join params p
  where h.kc_month = p.kc_month
    and h.kc_year  = p.kc_year
    and h.sacos_abiertos > 0
),
tot as (select coalesce(sum(open_sacos),0) as total_open from open_hedges),
base as (
  select o.*, t.total_open, p.sacos as sacos_fix, p.precio_cierre_clb,
         (p.sacos::numeric * o.open_sacos / t.total_open)           as raw_alloc,
         floor(p.sacos::numeric * o.open_sacos / t.total_open)::int as floor_alloc
  from open_hedges o cross join tot t cross join params p
),
resto as (
  select (select sacos from params) - coalesce(sum(floor_alloc),0) as resto from base
),
ranked as (
  select b.*,
         (b.raw_alloc - b.floor_alloc) as frac,
         row_number() over (
           order by (b.raw_alloc - b.floor_alloc) desc,
                    b.days_to_ltd asc nulls last, b.hedge_id
         ) as rn
  from base b
),
alloc as (
  select r.*,
         r.floor_alloc + case when r.rn <= (select resto from resto) then 1 else 0 end
           as sacos_asignados
  from ranked r
)
select
  hedge_id,
  contract_id,
  cliente,
  open_sacos                                             as sacos_abiertos,
  round(100.0 * open_sacos / nullif(total_open,0), 1)    as pct_del_pool,
  sacos_asignados,
  precio_entrada_clb,
  precio_cierre_clb,
  round((precio_cierre_clb - precio_entrada_clb)
        * sacos_asignados * 70 * 2.20462 / 100, 2)       as pnl_usd_estimado,
  -- guarda de sobre-fijación: marca si el fixing excede lo abierto
  case when sacos_fix > total_open
       then '⚠️ SOBRE-FIJACIÓN: ' || sacos_fix || ' > ' || total_open || ' abiertos'
       else 'OK' end                                     as validacion
from alloc
order by sacos_asignados desc, hedge_id;

-- Comprobación rápida (otra consulta de solo lectura): la suma debe dar
-- EXACTAMENTE los sacos del fixing, y el total no debe exceder lo abierto.
-- Cámbiale los mismos valores de 'params' para verificar el cuadre.


-- ---------------------------------------------------------------------
-- OPCIÓN B — FUNCIÓN REUTILIZABLE (solo lectura: SELECT, no escribe)
-- ---------------------------------------------------------------------
-- Crear la función es aditivo e inofensivo (no modifica datos). Luego se
-- llama desde la app o el SQL Editor. NO inserta nada: solo devuelve el
-- reparto simulado. Bloquea explícitamente la sobre-fijación.

create or replace function apply_fixing_preview(
  p_kc_month          text,
  p_kc_year           int,
  p_sacos             int,
  p_precio_cierre_clb numeric
) returns table (
  hedge_id          text,
  contract_id       text,
  cliente           text,
  sacos_abiertos    bigint,
  pct_del_pool      numeric,
  sacos_asignados   int,
  precio_entrada_clb numeric,
  pnl_usd_estimado  numeric
)
language plpgsql
stable                      -- 'stable' = no modifica la base de datos
as $$
declare
  v_total_open bigint;
begin
  select coalesce(sum(h.sacos_abiertos),0) into v_total_open
  from v_hedge_positions h
  where h.kc_month = p_kc_month and h.kc_year = p_kc_year
    and h.sacos_abiertos > 0;

  if v_total_open = 0 then
    raise exception 'No hay hedges abiertos en % %', p_kc_month, p_kc_year;
  end if;
  if p_sacos > v_total_open then
    raise exception 'Sobre-fijación bloqueada: % sacos > % abiertos en % %',
      p_sacos, v_total_open, p_kc_month, p_kc_year;
  end if;

  return query
  with open_hedges as (
    select h.id as hid, h.contract_id as cid, c.cliente as cli,
           h.precio_entrada_clb as pe, h.sacos_abiertos as os, h.days_to_ltd as dl
    from v_hedge_positions h
    left join contracts c on c.id = h.contract_id
    where h.kc_month = p_kc_month and h.kc_year = p_kc_year
      and h.sacos_abiertos > 0
  ),
  base as (
    select o.*,
           (p_sacos::numeric * o.os / v_total_open)           as raw_alloc,
           floor(p_sacos::numeric * o.os / v_total_open)::int  as floor_alloc
    from open_hedges o
  ),
  resto as (select p_sacos - coalesce(sum(floor_alloc),0) as r from base),
  ranked as (
    select b.*,
           row_number() over (
             order by (b.raw_alloc - b.floor_alloc) desc,
                      b.dl asc nulls last, b.hid
           ) as rn
    from base b
  ),
  alloc as (
    select r.*,
           r.floor_alloc + case when r.rn <= (select r from resto) then 1 else 0 end as sa
    from ranked r
  )
  select a.hid, a.cid, a.cli, a.os,
         round(100.0 * a.os / v_total_open, 1),
         a.sa, a.pe,
         round((p_precio_cierre_clb - a.pe) * a.sa * 70 * 2.20462 / 100, 2)
  from alloc a
  order by a.sa desc, a.hid;
end;
$$;

-- Uso de la función (solo lectura):
--   select * from apply_fixing_preview('K', 2026, 300, 185.40);
--
-- Para probar la guarda de sobre-fijación, pide más sacos de los abiertos:
--   select * from apply_fixing_preview('K', 2026, 999999, 185.40);  -- debe dar ERROR controlado
--
-- Para revertir/eliminar la función (no afecta datos):
--   drop function if exists apply_fixing_preview(text,int,int,numeric);
