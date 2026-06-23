# Diseño técnico — P&L no realizado y cierre dividido (bolsa / no-bolsa)

**Proyecto:** Forest Coffee CTRM
**Fecha:** 2026-06-22 · **Versión:** 1
**Estado:** PROPUESTA — pendiente de implementar
**Branch:** `claude/friendly-mccarthy-1pt08x`
**Relacionado:** `docs/DISENO-NETEO-BOLSA.md` (motor de asignación automática)

---

## 1. Motivación

Dos necesidades del equipo:

- **(A)** Marcar a mercado (**P&L no realizado**) las **posiciones fijadas pero sin
  cubrir** — contratos con `precio_kc_fijado` que **no tienen hedge abierto**.
- **(B)** Al cerrar compras, poder **dividir** la cantidad entre **contratos EN
  bolsa** (con hedge) y **contratos NO en bolsa** (sin hedge), para ir cerrando
  ambos.

---

## 2. Lo que ya existe (reutilizar)

`index.html:12983-13109`:
- Tabla **`kc_current_prices`** (`kc_key, kc_month, kc_year, precio, updated_at`):
  el operador ingresa el **precio KC actual de mercado por mes**; se guarda.
- **`renderKcPnlCards()`**: marca a mercado **los hedges abiertos** por mes KC:
  ```js
  pnl = (precioActual − precioEntradaPromedio) × lbs / 100   // convención "largo"
  ```

**Hueco:** solo cubre lo que está **en bolsa**. Los contratos **fijados sin hedge**
no se marcan. Eso es lo que añade este diseño.

---

## 3. Análisis A — P&L no realizado de posiciones sin cubrir

### 3.1 Dos exposiciones, signos opuestos (¡clave!)

| Tipo | Instrumento | Fórmula (c/lb) | Gana cuando |
|------|-------------|----------------|-------------|
| **Hedge abierto** | Futuro largo | `(KC_actual − precio_entrada)` | sube |
| **Contrato fijado sin hedge** | Venta fijada (corto comercial) | `(precio_kc_fijado − KC_actual)` | **baja** |

**Confirmado con el equipo:** para la venta fijada sin cubrir, **baja = ganancia**.
Ej.: fijado 240 c/lb, mercado 230 c/lb → `(240 − 230) = +10 c/lb` → ganancia no
realizada. El signo es opuesto al hedge porque una venta fijada sin cubrir se
beneficia cuando el mercado cae (se compra el físico más barato manteniendo el
precio de venta); el hedge largo hace lo contrario y por eso se compensan al
cubrir.

USD = `(precio_kc_fijado − KC_actual) × sacos_exposición × 70 × 2.20462 / 100`.

### 3.2 ¿Qué sacos están "expuestos sin hedge"?
Aproximación de primera pasada:
```
exposicion_sin_hedge = max( sacos_abiertos_del_contrato − sacos_con_hedge_abierto, 0 )
```
donde `sacos_abiertos_del_contrato` = sacos aún sin comprar físicamente
(`v_contracts.sacos_abiertos`) y `sacos_con_hedge_abierto` = suma de
`v_hedge_positions.sacos_abiertos` del contrato. *(A refinar si hay solapes raros.)*

### 3.3 Vista propuesta `v_unrealized` (solo lectura)
Unifica ambas exposiciones marcadas a mercado con `kc_current_prices`:

```sql
create or replace view v_unrealized as
-- Hedges abiertos (largo): gana si sube
select 'HEDGE'::text as tipo, h.id as ref, h.contract_id,
       h.kc_month, h.kc_year, h.sacos_abiertos as sacos,
       h.precio_entrada_clb as precio_ref, p.precio as kc_actual,
       (p.precio - h.precio_entrada_clb) * h.sacos_abiertos * 70 * 2.20462 / 100
         as pnl_no_real_usd
from v_hedge_positions h
join kc_current_prices p on p.kc_key = h.kc_month || h.kc_year
where h.sacos_abiertos > 0

union all

-- Contratos fijados sin hedge (corto comercial): gana si baja
select 'CONTRATO_SIN_HEDGE', c.id, c.id,
       c.kc_month, c.kc_year,
       greatest(c.sacos_abiertos - coalesce(hh.hedge_open,0),0),
       c.precio_kc_fijado, p.precio,
       (c.precio_kc_fijado - p.precio)
         * greatest(c.sacos_abiertos - coalesce(hh.hedge_open,0),0)
         * 70 * 2.20462 / 100
from v_contracts c
left join (
  select contract_id, sum(sacos_abiertos) as hedge_open
  from v_hedge_positions where sacos_abiertos > 0 group by contract_id
) hh on hh.contract_id = c.id
join kc_current_prices p on p.kc_key = c.kc_month || c.kc_year
where c.precio_kc_fijado is not null
  and greatest(c.sacos_abiertos - coalesce(hh.hedge_open,0),0) > 0;
```

### 3.4 Validación inmediata (solo lectura, sin crear nada)
Query para ver el P&L no realizado de contratos fijados sin hedge con datos reales:

```sql
with hedged as (
  select contract_id, sum(sacos_abiertos) as hedge_open
  from v_hedge_positions where sacos_abiertos > 0 group by contract_id
),
px as (select kc_key, precio from kc_current_prices)
select c.id as contrato, c.cliente, c.kc_month, c.kc_year,
       c.precio_kc_fijado, p.precio as kc_actual,
       c.sacos_abiertos as sacos_sin_comprar,
       coalesce(h.hedge_open,0) as sacos_con_hedge,
       greatest(c.sacos_abiertos - coalesce(h.hedge_open,0),0) as exposicion_sin_hedge,
       round((c.precio_kc_fijado - p.precio)
             * greatest(c.sacos_abiertos - coalesce(h.hedge_open,0),0)
             * 70 * 2.20462 / 100, 2) as pnl_no_realizado_usd
from v_contracts c
left join hedged h on h.contract_id = c.id
left join px      p on p.kc_key = c.kc_month || c.kc_year
where c.precio_kc_fijado is not null and c.sacos_abiertos > 0
order by pnl_no_realizado_usd;
```

---

## 4. Análisis B — cierre dividido (bolsa / no-bolsa)

### 4.1 Formulario
```
┌─ Fixing / compra ───────────────────────────────┐
│ Mes KC: U-2026   Precio cierre: ___  Fecha: ___  │
│   Sacos para contratos EN bolsa:    [ 200 ]      │  → motor proporcional (hedges)
│   Sacos para contratos NO en bolsa: [ 100 ]      │  → contratos fijados sin hedge
└──────────────────────────────────────────────────┘
```

### 4.2 Comportamiento por cubeta
- **EN bolsa** → motor `apply_fixing` ya diseñado: reparte proporcional entre
  hedges abiertos del mes, crea `physical_purchases` + `hedge_closures`.
- **NO en bolsa** → reparte proporcional entre **contratos fijados sin hedge** del
  mes (`v_unrealized` tipo `CONTRATO_SIN_HEDGE`), crea `physical_purchases` y
  **registra el P&L comercial realizado** (decisión §5: tabla separada).
- Ambas cubetas comparten el mismo `batch_id` para anular en bloque.

### 4.3 P&L comercial realizado (decisión confirmada: separado)
Nueva tabla, **independiente** de los cierres de hedge:

```sql
create table commercial_closures (
  id              text primary key,     -- 'CC-0001'
  batch_id        text,
  contract_id     text not null,
  sacos           int  not null,
  precio_kc_fijado    numeric not null, -- referencia fijada del contrato
  precio_kc_cierre    numeric not null, -- mercado al cerrar
  fecha           date not null,
  registrado_por  text default 'auto',
  created_at      timestamptz default now()
);

-- P&L comercial realizado (mismo signo que el no realizado: baja = ganancia)
create or replace view v_pnl_comercial as
select cc.*,
  (cc.precio_kc_fijado - cc.precio_kc_cierre) * cc.sacos * 70 * 2.20462 / 100
    as pnl_comercial_usd
from commercial_closures cc;
```

El P&L total del negocio = **P&L hedges** (`v_pnl`) **+ P&L comercial**
(`v_pnl_comercial`), mostrados por separado para no mezclarlos.

---

## 5. Cambios en `index.html`
| Acción | Detalle |
|--------|---------|
| Tarjetas no realizado | Extender `renderKcPnlCards()` para incluir `CONTRATO_SIN_HEDGE` (o leer `v_unrealized`). |
| Formulario de cierre | Dos cubetas (en bolsa / no en bolsa). |
| Motor no-bolsa | Reparto proporcional entre contratos fijados sin hedge → `physical_purchases` + `commercial_closures`. |
| P&L realizado | Nueva sección "P&L comercial" junto al P&L de hedges. |
| Estado | Cargar `v_unrealized`, `v_pnl_comercial`, `commercial_closures`. |

---

## 6. Decisiones
**Confirmadas:**
- Signo no realizado contratos sin hedge: **baja = ganancia** `(fijado − actual)`.
  → **Validado con data real** (Au79: mercado sube → pérdida; Little Waves: mercado
  baja → ganancia).
- P&L comercial al cerrar: **tabla separada** (`commercial_closures`), no se mezcla
  con hedges.
- **No hay categoría PTBF:** en producción los 20 contratos sin hedge tienen
  `precio_kc_fijado`. Se descarta tratar PTBF aparte (si en el futuro aparece un
  contrato sin precio fijado, queda fuera de `v_unrealized` por el `where`).
- Base de `exposicion_sin_hedge` = `max(sacos_abiertos − hedge_open, 0)`:
  **validada** (los contratos sin hedge dan exposición = sacos abiertos).

**Hallazgo operativo:** el P&L no realizado de lo no-cubierto era, al validar,
≈ **−$2.120 neto** (+$19,2k / −$21,3k bruto), concentrado en contratos fijados
barato. Hoy NO se ve en la app (las tarjetas solo cubren hedges) → justifica A.

**Nota de datos:** falta cargar el precio KC del mes **Z-2026** en
`kc_current_prices` (un contrato queda sin valorar hasta entonces).

**Pendientes:**
- [x] El reparto "no en bolsa" **también es proporcional** (resto mayor), igual que bolsa.
- [x] `precio_kc_cierre` de la cubeta no-bolsa = **el mismo precio del fixing**.

> Motor implementado en `docs/sql/apply_fixing.sql` (`apply_fixing` con `dry_run`,
> `void_fixing`, `commercial_closures`, `v_pnl_comercial`).

---

*Solo diseño/análisis. No se ha modificado lógica de la aplicación. Validar con el
query de §3.4 antes de construir.*
