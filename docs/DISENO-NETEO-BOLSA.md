# Diseño técnico — Capa operativa de neteo de posiciones en bolsa (KC)

**Proyecto:** Forest Coffee CTRM
**Autor:** Análisis asistido (Claude Code)
**Fecha:** 2026-06-22
**Estado:** PROPUESTA — pendiente de revisión antes de implementar
**Branch:** `claude/friendly-mccarthy-1pt08x`

---

## 1. Objetivo

Reducir dos problemas que el equipo reporta como **insostenibles**:

1. **Demasiados lotes KC reales** abiertos/cerrados con el bróker.
2. **Demasiados registros de cierre parcial** en el sistema (un cierre por cada hedge).

Sin perder la trazabilidad analítica por contrato/cliente que existe hoy.

**Estrategia elegida:** *Capa operativa separada.* Los hedges siguen siendo el
**requerimiento de cobertura** (analítico, fraccional, por contrato). Encima se
añade una capa nueva de **posiciones reales en bolsa**, neteadas por mes de
entrega KC y expresadas en **lotes enteros**. Solo se registra una operación
real cuando cambia el número de lotes enteros netos.

---

## 2. Diagnóstico del estado actual

### 2.1 Arquitectura
- App de una sola página: toda la lógica en `index.html` (~13.9k líneas; JS entre 4071–13850).
- Backend Supabase (PostgreSQL). El frontend lee **vistas** y escribe en **tablas base**.
- Estado en memoria (`index.html:4079`): `CONTRACTS, HEDGES, PURCHASES, CLOSURES, ROLLS, KC_CAL, OPTIONS`.

### 2.2 Modelo actual (la "cruz")
```
CONTRATO (venta)  ──1:N──►  HEDGE (cobertura KC)  ──1:N──►  CLOSURE (+ PURCHASE)
contracts                   hedge_positions                hedge_closures / physical_purchases
```

### 2.3 Conversión física → bolsa (`index.html:4073-4075`)
```js
const KG_SACO = 70;        // 1 saco = 70 kg
const KG_KC   = 17009.73;  // 1 lote KC = 17 009,73 kg ≈ 243 sacos
// contratos = (sacos * 70) / 17009.73   → se guarda en DECIMAL
```
> Spec real del contrato Coffee "C" (KC): **37 500 lb = 17 009,71 kg**.
> ⇒ **1 lote ≈ 243,0 sacos de 70 kg.** (A confirmar, ver §9.)

### 2.4 Causa raíz de la multiplicidad
| # | Problema | Evidencia |
|---|----------|-----------|
| 1 | Los contratos se manejan como **fracciones decimales**; nunca se netean a lotes enteros. | `(kg/KG_KC).toFixed(2)` en `index.html:4098-4101, 5097-5099` |
| 2 | Diseño rígido **"1 hedge = 1 cierre"**. El cierre masivo itera por hedge y crea un `physical_purchase` + un `hedge_closure` por cada uno. | `cmSave()` loop en `index.html:5825` |
| 3 | **Sin neteo ni agrupación** por `contract_id` ni por mes KC. | `cmSave()` `index.html:5796-5886` |
| 4 | Los rolls inflan el historial: un registro por hedge. | `executeRollMasivo()` `index.html:12756-12817` |

### 2.5 Hallazgo crítico
El conteo de contratos (`contratos_kc`, `contratos_kc_abiertos`, `sacos_abiertos`,
`estado_cobertura`, `roll_status`) **se calcula en vistas SQL de Supabase**
(`v_contracts`, `v_hedge_positions`, `v_pnl`), que **no están en el repositorio**.
Parte de este rediseño debe ocurrir en Supabase, no solo en `index.html`.

---

## 3. Modelo objetivo (capa operativa separada)

Separamos explícitamente **dos planos**:

```
PLANO ANALÍTICO (requerimiento)            PLANO OPERATIVO (realidad en bolsa)
─────────────────────────────             ──────────────────────────────────
CONTRATO → HEDGE → CLOSURE                 exchange_trades  (lotes ENTEROS)
(fraccional, por cliente)                       │
   │ se agrega por mes KC                       ▼
   ▼                                        v_exchange_net (posición neta por mes)
v_hedge_requirement_by_month
(sacos abiertos → lotes requeridos)             ▲
   │                                            │
   └──────────►  CONCILIACIÓN / DELTA  ◄────────┘
                 v_exchange_rebalance
                 "abrir/cerrar X lotes en mes M"
```

- **Plano analítico = lo que existe hoy, sin cambios disruptivos.** Sigue dando
  cobertura %, P&L por cliente, rolls analíticos, etc.
- **Plano operativo = nuevo.** Es la **fuente de verdad de lo que realmente
  tienes en el bróker**: solo lotes enteros, pocas operaciones, neteado por mes.
- Una **vista de conciliación** compara *requerido* vs *real* y dice exactamente
  cuántos lotes abrir o cerrar (en enteros) por mes. Ahí el operador actúa una
  sola vez por mes/sesión, no una vez por hedge.

---

## 4. Nuevo modelo de datos (Supabase)

### 4.1 Tabla nueva: `exchange_trades` (operaciones reales en bolsa)
Fuente de verdad de la posición real. **Solo lotes enteros.**

```sql
create table exchange_trades (
  id            text primary key,           -- 'XT-2026-001'
  kc_month      text not null,              -- 'H','K','N','U','Z'
  kc_year       int  not null,
  side          text not null check (side in ('BUY','SELL')),
  lots          int  not null check (lots > 0),   -- ENTERO
  price_clb     numeric not null,           -- precio de ejecución c/lb
  fecha         date not null,
  motivo        text not null check (motivo in ('OPEN','CLOSE','ROLL_OUT','ROLL_IN','ADJUST','OPENING_BALANCE')),
  broker_ref    text,                       -- folio/ticket del bróker (opcional)
  notas         text,
  created_at    timestamptz default now()
);
```

### 4.2 Vista nueva: `v_exchange_net` (posición neta real por mes)
```sql
create view v_exchange_net as
select
  kc_month, kc_year,
  sum(case when side='BUY'  then lots else -lots end)              as net_lots,
  sum(case when side='SELL' then lots else 0 end)                  as sold_lots,
  sum(case when side='BUY'  then lots else 0 end)                  as bought_lots,
  -- precio promedio ponderado de la posición vendida (corta = hedge de venta física)
  sum(price_clb * lots) filter (where side='SELL') /
      nullif(sum(lots) filter (where side='SELL'),0)               as avg_sell_clb
from exchange_trades
group by kc_month, kc_year;
```

### 4.3 Vista nueva: `v_hedge_requirement_by_month` (requerimiento agregado)
Agrega el requerimiento analítico **a lotes** por mes KC. **Aquí vive la política
de redondeo** (ver §6).
```sql
create view v_hedge_requirement_by_month as
select
  h.kc_month, h.kc_year,
  sum(h.sacos_abiertos)                                  as sacos_abiertos,
  sum(h.sacos_abiertos) * 70.0 / 17009.73                as lots_fraccional,
  round(sum(h.sacos_abiertos) * 70.0 / 17009.73)         as lots_requeridos  -- política: redondeo al entero más cercano
from v_hedge_positions h
where h.sacos_abiertos > 0
group by h.kc_month, h.kc_year;
```

### 4.4 Vista nueva: `v_exchange_rebalance` (la recomendación operativa)
```sql
create view v_exchange_rebalance as
select
  coalesce(r.kc_month, n.kc_month)            as kc_month,
  coalesce(r.kc_year , n.kc_year )            as kc_year,
  coalesce(r.lots_requeridos,0)               as lots_requeridos,
  coalesce(n.net_lots,0) * -1                 as lots_actuales,   -- corto = positivo
  coalesce(r.lots_requeridos,0) - (coalesce(n.net_lots,0)*-1)  as delta_lots
from v_hedge_requirement_by_month r
full outer join v_exchange_net n
  on r.kc_month=n.kc_month and r.kc_year=n.kc_year;
```
> `delta_lots > 0` ⇒ faltan lotes ⇒ **vender** (abrir cobertura corta).
> `delta_lots < 0` ⇒ sobran lotes ⇒ **comprar/levantar** (cerrar cobertura).
> `delta_lots = 0` ⇒ no operar. **Con banda de tolerancia (§6), solo se actúa
> cuando |delta| supera el umbral.**

### 4.5 Lo que NO cambia
`contracts`, `hedge_positions`, `hedge_closures`, `physical_purchases`,
`roll_log`, `options_positions` y sus vistas **se mantienen** para preservar
analítica y P&L por cliente. El cierre parcial sigue existiendo como **evento
analítico**, pero **deja de disparar una operación de bolsa**.

---

## 5. Cambios en `index.html`

### 5.1 Estado y carga
- `index.html:4079` → añadir arrays `EXCHANGE_TRADES`, `EXCHANGE_NET`, `REBALANCE`.
- `loadAll()` `index.html:4202-4222` → añadir 3 lecturas:
  `exchange_trades`, `v_exchange_net`, `v_exchange_rebalance`.

### 5.2 Constantes
- Añadir junto a `index.html:4073-4075`:
  ```js
  const SACOS_POR_LOTE = KG_KC / KG_SACO;   // ≈ 243
  const BANDA_TOLERANCIA_LOTES = 0.5;        // umbral de rebalanceo (§6, configurable)
  const POLITICA_REDONDEO = 'cercano';       // 'cercano' | 'arriba' | 'abajo'
  ```

### 5.3 Pantalla nueva: "Posición de bolsa / Rebalanceo"
Una vista por mes KC que muestra: `lots_requeridos`, `lots_actuales`, `delta`,
y un botón **"Registrar operación"** que inserta UN `exchange_trade` (entero).
Sustituye el flujo de "muchos cierres parciales" por "un rebalanceo por mes".

### 5.4 Función nueva: `registrarOperacionBolsa()`
```js
// Inserta UNA fila en exchange_trades (lotes enteros) y refresca v_exchange_*.
// Reemplaza el efecto "bolsa" de saveCompra()/cmSave() para la parte operativa.
```

### 5.5 Ajuste de los cierres existentes (desacople)
- `saveCompra()` `index.html:5114-5204` y `cmSave()` `index.html:5796-5886`:
  siguen registrando el **fixing analítico** (P&L por cliente) en `hedge_closures`,
  pero **ya no se interpretan como operación de bolsa**. La bolsa se mueve solo
  desde la pantalla de rebalanceo.
- Opción de consolidación de registros: agrupar `assignments` por `contract_id`
  antes del insert para reducir filas (línea `index.html:5825`). *(Decisión abierta, §9.)*

### 5.6 Rolls operativos
- Nuevo flujo: rolar la **posición neta** por mes = 1 `exchange_trade` motivo
  `ROLL_OUT` + 1 `ROLL_IN`, en lugar de N registros por hedge. `roll_log` analítico
  se mantiene para el plano por cliente.

---

## 6. Política de neteo y rebalanceo (clave anti-churn)

El objetivo de **menos operaciones** se logra con dos parámetros:

1. **Redondeo** del requerimiento fraccional a lotes enteros:
   - `cercano` (recomendado): redondeo al entero más próximo.
   - `arriba`: nunca quedar sub-cubierto (más conservador, más lotes).
   - `abajo`: nunca sobre-cubrir (menos lotes, asume base física).
2. **Banda de tolerancia (histéresis):** solo rebalancear cuando
   `|delta_lots| ≥ BANDA_TOLERANCIA_LOTES`. Esto evita abrir/cerrar por cada
   fixing pequeño. Ej.: con banda 0,5, un fixing de 50 sacos (~0,2 lotes) **no**
   genera operación; se acumula hasta cruzar el umbral.

> Este par (redondeo + banda) es el corazón de la solución: **decenas de fixings
> parciales se convierten en unas pocas operaciones enteras por mes.**

---

## 7. Conciliación de P&L (importante)

Con neteo, los **precios de ejecución reales** existen a nivel de lote entero, no
por cliente. Por eso habrá dos P&L que se concilian:

- **P&L analítico por cliente** (como hoy): `(precio_cierre − precio_entrada) × sacos`.
- **P&L operativo real** (nuevo): desde `exchange_trades` con precios de fill reales.
- **Diferencia = "base de neteo"**: una línea de conciliación que captura el
  desfase entre el precio analítico asignado y el fill real promedio. Se reporta,
  no se pierde.

Esto mantiene intacta la contabilidad por cliente y a la vez refleja la caja real.

---

## 8. Plan de migración (cuando aprobemos el diseño)

1. **Esquema:** crear `exchange_trades` + las 3 vistas nuevas. Versionar el SQL en
   `docs/sql/` (hoy no hay esquema en el repo).
2. **Backfill:** sembrar una posición inicial por mes KC con motivo
   `OPENING_BALANCE` = lotes netos requeridos hoy (redondeados). Así el sistema
   arranca conciliado.
3. **Frontend:** añadir carga + pantalla de rebalanceo (read-only primero).
4. **Desacople:** quitar el efecto "bolsa" de los cierres analíticos.
5. **Rolls operativos** y consolidación de registros.
6. **Validación** en paralelo (la posición neta nueva debe igualar la suma
   redondeada de hoy) antes de apagar el flujo viejo.

---

## 9. Lo que necesito de ti para implementar

1. **Definiciones de las vistas SQL** (correr en Supabase y pasarme el resultado):
   ```sql
   select table_name, view_definition
   from information_schema.views
   where table_name in ('v_contracts','v_hedge_positions','v_pnl','v_options')
   order by table_name;
   ```
2. **Confirmar la spec del lote KC:** ¿37 500 lb (≈243 sacos)? El código usa
   `KG_KC = 17009.73`, consistente, pero conviene confirmarlo con operaciones.
3. **Política de redondeo** preferida: `cercano` / `arriba` / `abajo` (§6).
4. **Banda de tolerancia** inicial (sugerido: 0,5 lote).
5. **Consolidación de registros analíticos:** ¿agrupar cierres por `contract_id`
   (menos filas) o mantener 1 por hedge para auditoría? (§5.5)

---

## 10. Decisiones abiertas (resumen)
- [ ] Redondeo: cercano / arriba / abajo
- [ ] Banda de tolerancia (lotes)
- [ ] ¿Consolidar `hedge_closures` por contrato o no?
- [ ] ¿Rebalanceo manual (operador confirma) o sugerido-automático?
- [ ] ¿Versionar todo el esquema SQL en el repo? (recomendado: sí)

---

*Este documento es solo diseño. No se ha modificado ninguna lógica de la
aplicación. La implementación arranca tras tu visto bueno sobre las decisiones
de §9–§10.*
