-- =====================================================================
-- Forest Coffee CTRM — Definiciones ACTUALES de vistas en Supabase
-- Capturadas: 2026-06-22 (information_schema.views)
-- Propósito: versionar el esquema (antes no estaba en el repo) como
-- línea base antes de implementar el motor de asignación automática.
-- NO ejecutar tal cual sin revisar; es la foto del estado vigente.
-- =====================================================================

-- ---------------------------------------------------------------------
-- v_contracts
-- ---------------------------------------------------------------------
create or replace view v_contracts as
 SELECT c.id,
    c.cliente,
    c.region,
    c.sacos,
    c.precio_venta_clb,
    c.fecha_contrato,
    c.ventana_inicio,
    c.ventana_fin,
    c.kc_month,
    c.kc_year,
    c.precio_kc_fijado,
    c.diferencial,
    c.expected_coverage_date,
    c.baseline_cost_usd_kg,
    c.notas,
    c.created_at,
    (c.sacos * 70) AS kg,
    (((c.sacos * 70))::numeric / 17009.73) AS contratos_kc,
    COALESCE(pp.sacos_comprados, (0)::bigint) AS sacos_comprados,
    (COALESCE(pp.sacos_comprados, (0)::bigint) * 70) AS kg_comprados,
    (c.sacos - COALESCE(pp.sacos_comprados, (0)::bigint)) AS sacos_abiertos,
    ((c.sacos - COALESCE(pp.sacos_comprados, (0)::bigint)) * 70) AS kg_abiertos,
        CASE
            WHEN (c.sacos > 0) THEN ((COALESCE(pp.sacos_comprados, (0)::bigint))::numeric / (c.sacos)::numeric)
            ELSE (0)::numeric
        END AS cobertura_pct,
        CASE
            WHEN (COALESCE(pp.sacos_comprados, (0)::bigint) >= c.sacos) THEN 'CLOSED'::text
            WHEN ((c.sacos > 0) AND (((COALESCE(pp.sacos_comprados, (0)::bigint))::numeric / (c.sacos)::numeric) >= 0.95)) THEN 'OK'::text
            WHEN ((c.sacos > 0) AND (((COALESCE(pp.sacos_comprados, (0)::bigint))::numeric / (c.sacos)::numeric) >= 0.50)) THEN 'PARTIAL'::text
            ELSE 'OPEN'::text
        END AS estado_cobertura,
    (((((c.sacos * 70))::numeric * c.precio_venta_clb) * 2.20462) / (100)::numeric) AS ingreso_estimado_usd
   FROM (contracts c
     LEFT JOIN ( SELECT physical_purchases.contract_id,
            sum(physical_purchases.sacos) AS sacos_comprados
           FROM physical_purchases
          GROUP BY physical_purchases.contract_id) pp ON ((pp.contract_id = c.id)));

-- ---------------------------------------------------------------------
-- v_hedge_positions
-- ---------------------------------------------------------------------
create or replace view v_hedge_positions as
 SELECT h.id,
    h.parent_hedge_id,
    h.contract_id,
    h.tipo,
    h.kc_month,
    h.kc_year,
    h.precio_entrada_clb,
    h.sacos,
    h.fecha_apertura,
    h.expected_resolution_date,
    h.notas,
    h.created_at,
    (h.sacos * 70) AS kg_total,
    (((h.sacos * 70))::numeric / 17009.73) AS contratos_kc_total,
    COALESCE(cl.sacos_cerrados, (0)::bigint) AS sacos_cerrados,
    (COALESCE(cl.sacos_cerrados, (0)::bigint) * 70) AS kg_cerrados,
    (h.sacos - COALESCE(cl.sacos_cerrados, (0)::bigint)) AS sacos_abiertos,
    ((h.sacos - COALESCE(cl.sacos_cerrados, (0)::bigint)) * 70) AS kg_abiertos,
    ((((h.sacos - COALESCE(cl.sacos_cerrados, (0)::bigint)) * 70))::numeric / 17009.73) AS contratos_kc_abiertos,
    kc.last_trade_day,
    kc.next_month_code,
    kc.next_year,
    (kc.last_trade_day - CURRENT_DATE) AS days_to_ltd,
        CASE
            WHEN ((h.sacos - COALESCE(cl.sacos_cerrados, (0)::bigint)) <= 0) THEN 'CLOSED'::text
            WHEN (kc.last_trade_day < CURRENT_DATE) THEN 'EXPIRED'::text
            WHEN ((kc.last_trade_day - CURRENT_DATE) <= 5) THEN 'ROLL NOW'::text
            WHEN ((kc.last_trade_day - CURRENT_DATE) <= 15) THEN 'ROLL SOON'::text
            ELSE 'OK'::text
        END AS roll_status
   FROM ((hedge_positions h
     LEFT JOIN ( SELECT hedge_closures.hedge_id,
            sum(hedge_closures.sacos) AS sacos_cerrados
           FROM hedge_closures
          GROUP BY hedge_closures.hedge_id) cl ON ((cl.hedge_id = h.id)))
     LEFT JOIN kc_futures_calendar kc ON (((kc.month_code = h.kc_month) AND (kc.year = h.kc_year))));

-- ---------------------------------------------------------------------
-- v_pnl
-- ---------------------------------------------------------------------
create or replace view v_pnl as
 SELECT id,
    hedge_id,
    contract_id,
    purchase_id,
    precio_cierre_clb,
    precio_entrada_clb,
    sacos,
    fecha_cierre,
    tipo_cierre,
    registrado_por,
    created_at,
    (((((precio_cierre_clb - precio_entrada_clb) * (sacos)::numeric) * (70)::numeric) * 2.20462) / (100)::numeric) AS pnl_usd
   FROM hedge_closures hc;

-- ---------------------------------------------------------------------
-- v_options
-- ---------------------------------------------------------------------
create or replace view v_options as
 SELECT o.id,
    o.tipo,
    o.contract_id,
    o.hedge_id,
    o.kc_month,
    o.kc_year,
    o.strike_price,
    o.sacos,
    o.premium_clb,
    o.fecha_apertura,
    o.fecha_vencimiento,
    o.estado,
    o.precio_kc_cierre,
    o.notas,
    o.created_at,
    o.pnl_usd,
    o.resultado,
    o.precio_cierre_clb,
    o.fecha_cierre,
    (o.sacos * 70) AS kg,
    (((o.sacos * 70))::numeric / 17009.73) AS contratos_kc,
    ((((o.premium_clb * (o.sacos)::numeric) * (70)::numeric) * 2.20462) / (100)::numeric) AS premium_usd,
    (o.fecha_vencimiento - CURRENT_DATE) AS days_to_expiry,
        CASE
            WHEN (o.tipo = 'Compra Call'::text) THEN (o.strike_price - o.premium_clb)
            ELSE NULL::numeric
        END AS costo_neto_clb,
    c.cliente,
    h.precio_entrada_clb AS hedge_precio_entrada
   FROM ((options_positions o
     LEFT JOIN contracts c ON ((c.id = o.contract_id)))
     LEFT JOIN hedge_positions h ON ((h.id = o.hedge_id)));
