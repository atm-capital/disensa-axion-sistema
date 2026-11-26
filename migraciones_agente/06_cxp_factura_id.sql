-- v263 (25-nov-2026): cada cuenta por pagar queda LIGADA a su factura, para abrir el PDF desde
-- Cuentas por pagar sin ir a buscarla a Facturas (pedido de Andrés).
-- Cómo liga:
--   1) concepto "Factura <folio>" / "Factura CD <folio>"  → factura de ingreso con ese folio
--      (si hay varias con el mismo folio, la del mismo proveedor vía su pedido).
--   2) concepto con el folio del pedido (ej. "Pedido Truper #913119598") → la factura de ese pedido,
--      solo si el pedido tiene UNA factura (si tiene varias no adivina).
-- Se liga sola al crear la cuenta, al cambiar su concepto, y cuando llega la factura después.
-- Idempotente: se puede correr dos veces.
begin;

alter table cuentas_pagar add column if not exists factura_id bigint references facturas(id) on delete set null;
create index if not exists idx_cxp_factura on cuentas_pagar(factura_id);

create or replace function cxp_buscar_factura(p_concepto text, p_proveedor bigint)
returns bigint language sql stable security definer set search_path = public as $$
  with por_folio as (
    select f.id, (pc.proveedor_id = p_proveedor) as mismo_prov
      from facturas f left join pedidos_compra pc on pc.id = f.pedido_id
     where coalesce(f.tipo,'I') = 'I' and f.folio is not null and f.folio <> ''
       and p_concepto ~* ('factura\s+(cd\s+)?' || regexp_replace(f.folio, '([.*+?^${}()|\[\]\\])', '\\\1', 'g') || '(\M|$|\s|\))')
     order by (pc.proveedor_id = p_proveedor) desc nulls last, f.id desc
     limit 1
  ), por_pedido as (
    select min(f.id) as id
      from pedidos_compra pc join facturas f on f.pedido_id = pc.id and coalesce(f.tipo,'I') = 'I'
     where pc.folio_externo is not null and length(pc.folio_externo) >= 4
       and p_concepto ilike '%' || pc.folio_externo || '%'
       and (p_proveedor is null or pc.proveedor_id = p_proveedor)
     group by pc.id
    having count(f.id) = 1
     limit 1
  )
  select coalesce((select id from por_folio), (select id from por_pedido));
$$;

create or replace function cxp_ligar_factura() returns trigger language plpgsql as $$
begin
  if new.factura_id is null then
    new.factura_id := cxp_buscar_factura(new.concepto, new.proveedor_id);
  end if;
  return new;
end $$;

drop trigger if exists trg_cxp_ligar_factura on cuentas_pagar;
create trigger trg_cxp_ligar_factura before insert or update of concepto, proveedor_id on cuentas_pagar
  for each row execute function cxp_ligar_factura();

-- cuando la factura llega DESPUÉS que la cuenta por pagar
create or replace function factura_ligar_cxp() returns trigger language plpgsql security definer set search_path = public as $$
begin
  update cuentas_pagar c set factura_id = cxp_buscar_factura(c.concepto, c.proveedor_id)
   where c.factura_id is null and c.estado <> 'pagada'
     and cxp_buscar_factura(c.concepto, c.proveedor_id) is not null;
  return null;
end $$;

drop trigger if exists trg_factura_ligar_cxp on facturas;
create trigger trg_factura_ligar_cxp after insert or update of folio, pedido_id on facturas
  for each statement execute function factura_ligar_cxp();

-- ligar las que ya existen (todas, pagadas también, para poder consultar)
update cuentas_pagar set factura_id = cxp_buscar_factura(concepto, proveedor_id) where factura_id is null;

commit;

select estado, count(*) total, count(factura_id) con_factura from cuentas_pagar group by estado order by 1;
