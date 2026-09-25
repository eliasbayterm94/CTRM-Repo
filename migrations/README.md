# Migraciones SQL — Forest Coffee CTRM

Scripts SQL para Supabase (PostgreSQL). Cópialos y córrelos en el **SQL Editor** de Supabase.

## Orden de ejecución

| Archivo | Qué hace | ¿Obligatorio? |
|---|---|---|
| `001_baseline_views.sql` | Vistas base de referencia (`v_contracts`, `v_hedge_positions`, `v_pnl`, `v_options`). Es el estado de partida del sistema. | Referencia / re-crear vistas |
| `002_fixing_engine.sql` | **Motor de fixing (el principal).** Agrega columnas `batch_id`, crea la tabla `commercial_closures` (con su política RLS), la vista `v_pnl_comercial`, y las funciones `apply_fixing()` y `void_fixing()`. Idempotente: se puede correr varias veces. | **Sí** |
| `003_v_unrealized.sql` | Vista de P&L no realizado de contratos fijados-sin-cubrir. | Opcional |
| `tools_fixing_preview.sql` | Función de **solo lectura** para previsualizar (dry-run) una asignación de fixing antes de aplicarla. No escribe nada. | Opcional (herramienta) |

## Notas

- `002_fixing_engine.sql` es idempotente (`create or replace`, `drop policy if exists`, `add column if not exists`). Si algo cambia, vuelve a correr solo ese archivo.
- La apertura de posiciones en bolsa sigue siendo 1:1 por contrato. El **cierre** hace pooling proporcional por mes KC (largest-remainder), sin redondeo a lotes enteros.
- `commercial_closures` guarda los cierres de sacos de contratos que **no** estaban en bolsa (sin hedge asociado); estos no se filtran por mes.
- Cada aplicación de fixing agrupa sus filas con un `batch_id` para poder deshacerla con `void_fixing()`.
