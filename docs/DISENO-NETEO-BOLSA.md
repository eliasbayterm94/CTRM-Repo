# Diseño técnico — Motor de asignación automática de compras/fixings

**Proyecto:** Forest Coffee CTRM
**Autor:** Análisis asistido (Claude Code)
**Fecha:** 2026-06-22 · **Versión:** 2 (reemplaza el enfoque de "neteo a lotes enteros")
**Estado:** PROPUESTA — pendiente de visto bueno antes de implementar
**Branch:** `claude/friendly-mccarthy-1pt08x`

> **Cambio de enfoque respecto a la v1:** El problema NO es el número de lotes en
> bolsa (se pueden abrir/cerrar parciales con el bróker sin dificultad), así que
> **se descarta el redondeo a lotes enteros y la banda de tolerancia**. El dolor
> real es **la asignación manual** de cada compra física a varios contratos
> ("50 sacos a éste, 100 a aquél…"). Este documento resuelve eso.

---

## 1. Objetivo

Eliminar el trabajo manual de **repartir cada compra física / fixing entre los
contratos y hedges abiertos**, sin perder la trazabilidad ni el P&L por cliente.

**Decisiones tomadas:**
- **Auto-distribución por contrato** (se mantiene P&L por cliente).
- **Reparto proporcional** a los `sacos_abiertos` de cada hedge del mes KC.
- Sin redondeo a lotes enteros (se permiten parciales).

---

## 2. Por qué hoy la asignación es manual (causa raíz confirmada con las vistas)

El P&L de cada cierre se calcula así (vista `v_pnl`):

```sql
pnl_usd = (precio_cierre_clb - precio_entrada_clb) * sacos * 70 * 2.20462 / 100
```

Y **cada hedge tiene su propio `precio_entrada_clb`** (`hedge_positions`). Por eso,
para saber el P&L, el sistema necesita saber **a qué hedge pertenece cada saco
cerrado** → hoy obliga al operador a asignar a mano.

Flujo manual actual (`cmSave()`, `index.html:5796-5886`):
1. El operador ingresa la compra total.
2. En el paso 2, **reparte sacos hedge por hedge a mano**.
3. Por cada asignación se inserta `physical_purchases` + `hedge_closures`.

```js
// index.html:5825 — un registro por asignación MANUAL
for (const a of assignments) {
  insert physical_purchases {...}
  insert hedge_closures { sacos: a.sac, precio_entrada_clb: a.precioEntrada, ... }
}
```

Cómo impactan los datos (de las vistas):
- `physical_purchases.contract_id` → alimenta `v_contracts.sacos_comprados`,
  `cobertura_pct`, `estado_cobertura`.
- `hedge_closures.hedge_id` → alimenta `v_hedge_positions.sacos_cerrados` /
  `sacos_abiertos` y el `v_pnl`.

**Conclusión:** la asignación es un subproducto del cálculo de P&L por precio de
entrada. La solución es **calcular el reparto automáticamente**, no eliminar la
atribución.

---

## 3. Solución: motor de asignación proporcional

El operador registra **una sola entrada** (un fixing/compra) con:

| Campo | Ejemplo | Uso |
|-------|---------|-----|
| `kc_month` + `kc_year` | `K` / `2026` | Selecciona el universo de hedges a cerrar |
| `sacos` | `300` | Cantidad total a distribuir |
| `precio_cierre_clb` | `185.40` | Precio KC del fixing (igual para todos) |
| `precio_compra_usd_lb` | `3.10` | Lado físico (compra) |
| `fecha` | `2026-06-22` | Fecha de la operación |
| `region` *(opcional)* | `Perú` | Filtro opcional del universo |

El sistema:
1. Toma **todos los hedges abiertos** de ese `kc_month/kc_year`
   (`sacos_abiertos > 0`), filtrados por región si se indicó.
2. Calcula el total abierto: `total_open = Σ sacos_abiertos`.
3. Reparte `sacos` **proporcionalmente** a `sacos_abiertos` de cada hedge.
4. Crea automáticamente `physical_purchases` + `hedge_closures` por hedge.
5. El P&L por cliente sale solo, vía `v_pnl`, exactamente como hoy.

> El operador pasa de **N decisiones manuales** a **1 entrada + confirmar**.

### 3.1 Algoritmo de reparto (proporcional con resto mayor)

Para que la suma cuadre exacto al saco (sin perder ni inventar sacos):

```
total_open = Σ open_i                        (open_i = sacos_abiertos del hedge i)
raw_i      = sacos_total * open_i / total_open
alloc_i    = floor(raw_i)                     (piso entero)
resto      = sacos_total − Σ alloc_i
→ repartir 'resto' sumando +1 saco a los hedges con mayor parte fraccional
  (desempate: el de Last Trade Day más cercano primero)
restricción: alloc_i ≤ open_i  (no cerrar más de lo abierto;
             si por tope sobra, se redistribuye a hedges con capacidad)
```

**Ejemplo.** Fixing de 300 sacos en KC K-2026, 3 hedges abiertos:

| Hedge | abiertos | proporción | asignado |
|-------|---------:|-----------:|---------:|
| HG-12 | 400 | 44,4 % | 133 |
| HG-19 | 300 | 33,3 % | 100 |
| HG-25 | 200 | 22,2 % | 67 |
| **Σ** | **900** | 100 % | **300** ✓ |

Todo automático. Si el operador quiere ajustar un caso puntual, puede
sobreescribir (ver §5.3).

### 3.2 Casos borde y políticas

| Caso | Política propuesta |
|------|--------------------|
| `sacos` > `total_open` (sobre-fijación) | Avisar y **topar** al total abierto; el excedente no se asigna (decisión abierta, §8). |
| No hay hedges abiertos en el mes | Bloquear con mensaje claro. |
| Hedge con `roll_status` `EXPIRED`/`CLOSED` | Se excluye del universo. |
| Reparto deja a un hedge con 0 sacos (muy chico) | Permitido; simplemente no recibe asignación. |
| Redondeo | Método de **resto mayor** para que Σ asignado = `sacos` exacto. |

---

## 4. Dónde vive la lógica: función en Postgres (recomendado)

Como tienes acceso total a Supabase, lo más robusto es una **función SQL (RPC)
atómica**, en vez de un bucle en el navegador. Ventajas: atomicidad (todo o nada),
redondeo consistente, una sola llamada de red.

```sql
-- PROPUESTA (a afinar): reparte un fixing proporcionalmente e inserta los cierres.
create or replace function apply_fixing(
  p_kc_month            text,
  p_kc_year             int,
  p_sacos               int,
  p_precio_cierre_clb   numeric,
  p_precio_compra_usd_lb numeric,
  p_fecha               date,
  p_region              text default null,
  p_tipo                text default 'Purchase'
) returns table (hedge_id text, contract_id text, sacos int, pnl_usd numeric)
language plpgsql as $$
declare
  v_total_open bigint;
begin
  -- 1) universo de hedges abiertos del mes (con filtro opcional de región)
  create temp table _open on commit drop as
    select h.id as hedge_id, h.contract_id, h.precio_entrada_clb,
           h.sacos_abiertos as open_sacos
    from v_hedge_positions h
    left join contracts c on c.id = h.contract_id
    where h.kc_month = p_kc_month and h.kc_year = p_kc_year
      and h.sacos_abiertos > 0
      and (p_region is null or c.region = p_region);

  select coalesce(sum(open_sacos),0) into v_total_open from _open;
  if v_total_open = 0 then
    raise exception 'No hay hedges abiertos en % %', p_kc_month, p_kc_year;
  end if;

  -- 2) reparto proporcional + resto mayor  (detalle omitido por brevedad)
  --    produce _alloc(hedge_id, contract_id, precio_entrada_clb, sacos)

  -- 3) inserts atómicos en physical_purchases + hedge_closures
  --    (IDs vía secuencias dedicadas — ver §6)

  -- 4) devolver el desglose para que el front muestre el preview/confirmación
  return query select a.hedge_id, a.contract_id, a.sacos,
    (p_precio_cierre_clb - a.precio_entrada_clb)*a.sacos*70*2.20462/100
  from _alloc a;
end;
$$;
```

**Alternativa sin SQL:** replicar el mismo algoritmo en `index.html` y hacer los
inserts en bucle (como hoy, pero **calculados, no manuales**). Es más rápido de
entregar pero menos atómico. *(Decisión abierta, §8.)*

---

## 5. Cambios en `index.html`

### 5.1 Pantalla de fixing simplificada
Reemplaza el paso 2 manual de `cmSave()` por **un solo formulario**: mes KC,
sacos totales, precio de cierre, precio de compra, fecha, (región opcional).

### 5.2 Llamada al motor
```js
const { data, error } = await sb.rpc('apply_fixing', {
  p_kc_month, p_kc_year, p_sacos, p_precio_cierre_clb,
  p_precio_compra_usd_lb, p_fecha, p_region
});
// data = desglose por hedge (para mostrar y confirmar)
```

### 5.3 Preview + override opcional
Antes de confirmar, mostrar la tabla **ya calculada** (como el ejemplo de §3.1).
El operador normalmente solo confirma; si necesita, puede editar una fila y el
resto se recalcula. Así se conserva la flexibilidad sin el trabajo manual diario.

### 5.4 Lo que se mantiene
`saveCompra()` (cierre de un solo hedge) puede quedarse como camino rápido para
casos 1-a-1. `roll_log`, opciones y P&L por cliente **no cambian**.

---

## 6. Detalles a cerrar en implementación
- **IDs:** hoy se generan en el cliente por conteo (`'CL-'+length+1`), propenso a
  carreras. Con RPC conviene **secuencias** (`create sequence …`) o
  `max(id)+1` dentro de la transacción. A decidir.
- **`registrado_por`:** marcar `'auto'` para distinguir fixings automáticos.
- **Auditoría:** opcional, una columna `batch_id` que agrupe todos los cierres de
  un mismo fixing (facilita revertir/anular en bloque).

---

## 7. Migración
Cambio **aditivo**: no migra datos existentes. El flujo viejo manual puede
convivir como override. Pasos:
1. Crear `apply_fixing()` (+ secuencias / `batch_id` si se aprueban).
2. Versionar el SQL en `docs/sql/` (las vistas actuales ya quedaron en
   `docs/sql/current-views.sql`).
3. Nuevo formulario de fixing + preview en `index.html`.
4. Validar en paralelo (P&L y coberturas deben coincidir con el flujo manual)
   antes de jubilar el paso 2 manual.

---

## 8. Decisiones abiertas
- [ ] Sobre-fijación (`sacos` > abiertos): ¿topar y avisar, o permitir excedente?
- [ ] Motor en **RPC de Postgres** (recomendado) vs bucle en `index.html`.
- [ ] Estrategia de IDs (secuencias vs conteo) y `batch_id` para anular en bloque.
- [ ] ¿`region` como filtro fijo del fixing, u opcional?
- [ ] ¿Mantener `saveCompra()` 1-a-1 como atajo, o unificar todo en el motor?

---

*Solo diseño. No se ha modificado ninguna lógica de la aplicación. La
implementación arranca tras tu visto bueno sobre §8.*
