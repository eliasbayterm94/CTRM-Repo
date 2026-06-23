# Diseño técnico — Motor de asignación automática de compras/fixings

**Proyecto:** Forest Coffee CTRM
**Autor:** Análisis asistido (Claude Code)
**Fecha:** 2026-06-22 · **Versión:** 3 (FINAL — todas las decisiones cerradas)
**Estado:** APROBADO PARA IMPLEMENTAR — pendiente de tu "adelante"
**Branch:** `claude/friendly-mccarthy-1pt08x`

> **Historial:** v1 proponía netear a lotes enteros (descartado: en bolsa sí se
> operan parciales). v2 introdujo la auto-asignación. v3 cierra todas las
> decisiones tras la revisión del equipo.

---

## 1. Objetivo

Eliminar el trabajo manual de **repartir cada compra/fixing entre contratos y
hedges abiertos** ("50 sacos a éste, 100 a aquél…"), conservando trazabilidad y
P&L por cliente.

### Decisiones cerradas

| Tema | Decisión |
|------|----------|
| **Apertura** | Sigue **1:1 con el contrato** (la posición nace ligada a un contrato). Sin cambios. |
| **Cierre** | La compra entra al **pool del mes KC** y se reparte **proporcional** a `sacos_abiertos`. Automático. |
| **Reparto** | Proporcional puro (método de resto mayor para cuadrar al saco). |
| **Dejar abierto** | Solo por **cantidad**: se fija menos y el resto queda abierto, repartido proporcional. Sin exclusión de contratos. |
| **Alcance del pool** | Por **mes de entrega KC** (no se mezclan meses). |
| **Sobre-fijación** | **Bloqueada**: nunca se fija más que los sacos abiertos del mes. |
| **Dónde corre el cálculo** | Función **RPC en Postgres** (atómica). |
| **Anulación** | `batch_id` por fixing → permite **anular el fixing completo en bloque**. |
| **Filtro por región** | **No** se usa. |
| **Cierre 1-a-1 manual** | Se **elimina**; todo cierre pasa por el motor de pool. |
| **Redondeo a lotes** | **No** (se permiten parciales). |

---

## 2. Causa raíz (confirmada con las vistas SQL)

El P&L de cada cierre es `(precio_cierre_clb − precio_entrada_clb) × sacos × 70 ×
2.20462 / 100` (vista `v_pnl`), y **cada hedge tiene su propio
`precio_entrada_clb`**. Por eso hoy el sistema obliga a asignar a mano: necesita
saber qué precio de entrada aplicar a cada saco. La asignación manual es un
subproducto de ese cálculo → la solución es **calcularla automáticamente**.

Flujo manual actual: `cmSave()` (`index.html:5796-5886`), bucle de asignación en
`index.html:5825`.

---

## 3. Modelo conceptual: apertura por contrato, cierre por pool

```
APERTURA (1:1, sin cambios)              CIERRE (pool por mes KC, automático)
────────────────────────────            ─────────────────────────────────────
Se abre un hedge ligado a un             Entra UNA compra/fixing del mes KC.
contrato específico:                     El motor toma TODOS los hedges abiertos
  hedge_positions.contract_id            de ese mes y reparte proporcional a
                                         sacos_abiertos → crea los cierres solos.
```

### Trazabilidad (el punto importante)
- La **apertura conserva el contrato** ⇒ siempre se conoce la exposición original
  por cliente.
- El **cierre actualiza `sacos_abiertos` por hedge** ⇒ en todo momento se sabe,
  por contrato: cuánto se abrió, cuánto se cerró y cuánto queda abierto.
- **Dejar abierto** = fijar menos cantidad; el remanente queda repartido
  proporcionalmente entre los contratos del mes. No hay que elegir cuál.
- El **P&L por cliente** sigue saliendo de `v_pnl`, sin cambios.

---

## 4. Motor de reparto (proporcional con resto mayor)

El operador registra **una sola entrada**: `kc_month`, `kc_year`, `sacos`,
`precio_cierre_clb`, `precio_compra_usd_lb`, `fecha`.

```
total_open = Σ open_i                       (open_i = sacos_abiertos del hedge i del mes)
si sacos > total_open → ERROR (sobre-fijación bloqueada)
raw_i   = sacos * open_i / total_open
alloc_i = floor(raw_i)
resto   = sacos − Σ alloc_i
→ sumar +1 saco a los hedges con mayor parte fraccional hasta repartir 'resto'
  (desempate: Last Trade Day más cercano primero)
```

**Ejemplo.** Fixing de 300 sacos, KC K-2026, 3 hedges abiertos:

| Hedge | abiertos | proporción | asignado |
|-------|---------:|-----------:|---------:|
| HG-12 | 400 | 44,4 % | 133 |
| HG-19 | 300 | 33,3 % | 100 |
| HG-25 | 200 | 22,2 % | 67 |
| **Σ** | **900** | 100 % | **300** ✓ |

Si en cambio se fijan 200 (no 300), el remanente de 700 queda abierto repartido
en los mismos tres contratos. Cero asignación manual.

---

## 5. Función Postgres `apply_fixing` (motor)

```sql
-- Reparte un fixing proporcionalmente entre los hedges abiertos del mes KC,
-- inserta physical_purchases + hedge_closures de forma atómica y los agrupa
-- bajo un batch_id para poder anular en bloque. Bloquea la sobre-fijación.
create or replace function apply_fixing(
  p_kc_month             text,
  p_kc_year              int,
  p_sacos                int,
  p_precio_cierre_clb    numeric,
  p_precio_compra_usd_lb numeric,
  p_fecha                date
) returns table (batch_id text, hedge_id text, contract_id text,
                 sacos int, pnl_usd numeric)
language plpgsql as $$
declare
  v_total_open bigint;
  v_batch      text := 'BATCH-' || to_char(now(),'YYYYMMDDHH24MISS');
begin
  create temp table _open on commit drop as
    select h.id as hedge_id, h.contract_id, h.precio_entrada_clb,
           h.sacos_abiertos as open_sacos, h.days_to_ltd
    from v_hedge_positions h
    where h.kc_month = p_kc_month and h.kc_year = p_kc_year
      and h.sacos_abiertos > 0;

  select coalesce(sum(open_sacos),0) into v_total_open from _open;
  if v_total_open = 0 then
     raise exception 'No hay hedges abiertos en % %', p_kc_month, p_kc_year;
  end if;
  if p_sacos > v_total_open then
     raise exception 'Sobre-fijación: % sacos > % abiertos', p_sacos, v_total_open;
  end if;

  -- reparto proporcional + resto mayor → _alloc(hedge_id, contract_id,
  --                                              precio_entrada_clb, sacos)
  -- inserts atómicos en physical_purchases (con batch_id) y hedge_closures
  --   (con batch_id, registrado_por='auto'); IDs vía secuencias.

  return query
    select v_batch, a.hedge_id, a.contract_id, a.sacos,
           (p_precio_cierre_clb - a.precio_entrada_clb)*a.sacos*70*2.20462/100
    from _alloc a;
end;
$$;
```

**Cambios de esquema asociados:**
- `physical_purchases` y `hedge_closures`: nueva columna `batch_id text`.
- Secuencias dedicadas para IDs (`seq_purchase`, `seq_closure`) en lugar de
  conteo en el cliente (evita colisiones por concurrencia).
- Función `void_fixing(p_batch_id text)`: borra los `physical_purchases` y
  `hedge_closures` de un batch (reabre los sacos automáticamente vía vistas).

---

## 6. Cambios en `index.html`

| Acción | Detalle |
|--------|---------|
| **Reemplazar** el paso 2 manual de `cmSave()` | Un solo formulario: mes KC, sacos, precio cierre, precio compra, fecha. |
| **Preview** antes de confirmar | Mostrar la tabla ya calculada (como §4) — el operador solo confirma. |
| **Llamar** al motor | `sb.rpc('apply_fixing', {...})`. |
| **Eliminar** el cierre 1-a-1 (`saveCompra`) | Todo cierre pasa por el pool. |
| **Anular** | Botón "anular fixing" → `sb.rpc('void_fixing', { p_batch_id })`. |
| **Estado** | Cargar `batch_id` y exponer un historial de fixings agrupado. |
| **Sin cambios** | Apertura de hedges, rolls, opciones, P&L por cliente. |

---

## 7. Plan de implementación

1. **SQL** (`docs/sql/`): `batch_id` en las 2 tablas, secuencias, `apply_fixing`,
   `void_fixing`. Versionar todo en el repo.
2. **Frontend:** nuevo formulario de fixing + preview + confirmación.
3. **Anulación:** UI de historial por `batch_id` con botón anular.
4. **Validación en paralelo:** comparar coberturas y P&L del flujo automático vs
   el manual con datos reales antes de jubilar el paso 2 manual.
5. **Limpieza:** retirar el código de asignación manual (`cmSave` paso 2,
   `saveCompra`).

---

## 8. Riesgos y validación
- **Cuadre al saco:** el método de resto mayor garantiza `Σ asignado = sacos`.
  Test unitario obligatorio con casos no divisibles.
- **Concurrencia de IDs:** resuelta con secuencias.
- **Anulación segura:** `void_fixing` debe ser transaccional y reversible.
- **Paridad:** el P&L total de un fixing automático debe igualar al que daría el
  reparto manual equivalente (test de regresión).

---

*Diseño final. No se ha modificado ninguna lógica de la aplicación todavía. Listo
para implementar en este branch tras tu visto bueno.*
