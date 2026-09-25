-- =====================================================================
-- Forest Coffee CTRM — Vista v_unrealized (P&L NO REALIZADO unificado)
-- =====================================================================
--  ⚠️ SOLO LECTURA: una vista no modifica datos. Crearla es aditivo e
--  inofensivo. OPCIONAL: el reporte de la app calcula esto en memoria;
--  esta vista sirve para consultarlo desde SQL/BI.
--
--  Une dos exposiciones con SIGNOS OPUESTOS:
--   - HEDGE abierto (futuro largo):           (KC_actual − precio_entrada)  → gana si SUBE
--   - Contrato fijado SIN hedge (corto com.):  (precio_kc_fijado − KC_actual) → gana si BAJA
--  Usa los precios de kc_current_prices (los mismos que cargas en la app).
-- =====================================================================

create or replace view v_unrealized as
-- Hedges abiertos (largo): gana si sube
select
  'HEDGE'::text          as tipo,
  h.id                   as ref,
  h.contract_id,
  h.kc_month, h.kc_year,
  h.sacos_abiertos       as sacos,
  h.precio_entrada_clb   as precio_ref,
  p.precio               as kc_actual,
  (p.precio - h.precio_entrada_clb) * h.sacos_abiertos * 70 * 2.20462 / 100
                         as pnl_no_real_usd
from v_hedge_positions h
join kc_current_prices p on p.kc_key = h.kc_month || h.kc_year
where h.sacos_abiertos > 0

union all

-- Contratos fijados sin hedge (corto comercial): gana si baja
select
  'CONTRATO_SIN_HEDGE'::text,
  c.id,
  c.id,
  c.kc_month, c.kc_year,
  greatest(c.sacos_abiertos - coalesce(hh.hedge_open, 0), 0),
  c.precio_kc_fijado,
  p.precio,
  (c.precio_kc_fijado - p.precio)
    * greatest(c.sacos_abiertos - coalesce(hh.hedge_open, 0), 0)
    * 70 * 2.20462 / 100
from v_contracts c
left join (
  select contract_id, sum(sacos_abiertos) as hedge_open
  from v_hedge_positions where sacos_abiertos > 0
  group by contract_id
) hh on hh.contract_id = c.id
join kc_current_prices p on p.kc_key = c.kc_month || c.kc_year
where c.precio_kc_fijado is not null
  and greatest(c.sacos_abiertos - coalesce(hh.hedge_open, 0), 0) > 0;

-- Resumen por mes y tipo:
--   select tipo, kc_month, kc_year, sum(sacos) sacos, round(sum(pnl_no_real_usd),2) pnl
--   from v_unrealized group by tipo, kc_month, kc_year order by kc_year, kc_month, tipo;
--
-- Quitar la vista (no afecta datos):  drop view if exists v_unrealized;
