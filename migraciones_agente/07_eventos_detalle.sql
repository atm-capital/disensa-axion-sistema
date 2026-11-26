-- v263 (25-nov-2026): la Actividad de Axion guarda A QUÉ afectó (venta, pedido, producto, caja, cuenta por pagar)
-- y los datos del cambio (antes → después, motivo), para picar el renglón y ver el detalle.
-- Idempotente.
begin;
alter table eventos add column if not exists ref_tipo text;
alter table eventos add column if not exists ref_id   bigint;
alter table eventos add column if not exists datos    jsonb;
commit;
select column_name from information_schema.columns where table_name='eventos' order by ordinal_position;
