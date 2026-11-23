-- v260: el agente de la Mac mini importa solo las facturas de proveedores (XML) — misma lógica que
-- "Aplicar y archivar" en Importar (aplicarFacturas + limpiarCanceladosIndar), pero en la base y protegida
-- con la llave del agente. REGLA DE ANDRÉS: automático, pero si algo no cuadra contra el pedido NO se aplica
-- (queda "revisar" y el agente avisa). Notas de crédito y traslados solo se archivan (como en la pantalla).
-- Idempotente: se puede correr dos veces.

create or replace function public.agente_facturas_conocidas(p_llave text)
returns jsonb language plpgsql stable security definer set search_path to 'public','extensions' as $$
begin
  if not agente_llave_ok(p_llave) then raise exception 'llave invalida'; end if;
  return jsonb_build_object(
    'uuids',   coalesce((select jsonb_agg(upper(uuid)) from facturas), '[]'::jsonb),
    'folios',  coalesce((select jsonb_agg(distinct folio) from facturas), '[]'::jsonb),
    'pedidos_indar', coalesce((select jsonb_agg(distinct p.folio_externo) from pedidos_compra p join proveedores v on v.id = p.proveedor_id
                       where v.nombre ilike '%indar%' and p.estado <> 'cancelado' and coalesce(p.folio_externo,'') <> ''), '[]'::jsonb));
end $$;

create or replace function public.agente_importar_factura(p_llave text, p_doc jsonb)
returns jsonb language plpgsql security definer set search_path to 'public','extensions' as $$
declare
  v_uuid text := upper(coalesce(p_doc->>'uuid',''));
  v_folio text := coalesce(p_doc->>'folio','?');
  v_tipo text := coalesce(p_doc->>'tipo','?');
  v_fecha date := nullif(p_doc->>'fecha','')::date;
  v_total numeric := coalesce((p_doc->>'total')::numeric,0);
  v_sub numeric := coalesce((p_doc->>'subtotal')::numeric,0);
  v_dias int := coalesce(nullif(p_doc->>'dias','')::int, 30);
  v_items jsonb := coalesce(p_doc->'items','[]'::jsonb);
  v_emisor text := upper(coalesce(p_doc->>'emisor',''));
  v_prov bigint; v_reg boolean; v_ped record; v_best bigint; v_best_folio text; v_score numeric := 0; v_n int;
  it jsonb; r record; v_fuera jsonb := '[]'::jsonb; v_precios jsonb := '[]'::jsonb; v_cancel jsonb := '[]'::jsonb;
  v_partidas int := 0; v_sub2 numeric; v_cod text;
begin
  if not agente_llave_ok(p_llave) then raise exception 'llave invalida'; end if;
  if v_uuid = '' or v_tipo = '?' then return jsonb_build_object('estado','error','motivo','XML sin UUID o sin tipo'); end if;

  -- proveedor por el nombre del emisor
  select id into v_prov from proveedores where
       (v_emisor like '%INDAR%' and nombre ilike '%indar%')
    or (v_emisor like '%TRUPER%' and nombre ilike '%truper%')
    or (v_emisor like '%PLOMER%UNIVERSAL%' and nombre ilike '%plomer%universal%')
    or ((v_emisor like '%HOLCIM%' or v_emisor like '%DISENSA%') and nombre ilike '%holcim%')
    or (v_emisor like '%ARCA%' and nombre ilike '%arca%')
    or (v_emisor like '%PEREZ MEZA%' and nombre ilike '%perez meza%')
  order by id limit 1;

  if exists (select 1 from facturas where upper(uuid) = v_uuid) then
    return jsonb_build_object('estado','ya','folio',v_folio,'tipo',v_tipo);
  end if;

  -- notas de crédito / traslados: solo se archivan (en pantalla: "aplícala con Pagar en Finanzas")
  if v_tipo <> 'I' then
    insert into facturas(uuid, folio, tipo, fecha, subtotal, total, dias, pedido_id, items)
    values (v_uuid, v_folio, v_tipo, v_fecha, v_sub, v_total, v_dias, null, v_items);
    return jsonb_build_object('estado','archivada','folio',v_folio,'tipo',v_tipo,'total',v_total,'proveedor_id',v_prov);
  end if;

  if v_prov is null then
    return jsonb_build_object('estado','revisar','folio',v_folio,'total',v_total,'motivo','proveedor no reconocido: '||left(v_emisor,60));
  end if;

  select exists(select 1 from cuentas_pagar where concepto ilike 'Factura '||v_folio||'%') into v_reg;
  if v_reg then -- ya conciliada a mano: solo archivar
    insert into facturas(uuid, folio, tipo, fecha, subtotal, total, dias, pedido_id, items)
    values (v_uuid, v_folio, v_tipo, v_fecha, v_sub, v_total, v_dias, null, v_items);
    return jsonb_build_object('estado','archivada','folio',v_folio,'tipo',v_tipo,'motivo','ya tenía cuenta por pagar');
  end if;

  -- pedido con más partidas en común (mismo criterio que la pantalla: >= 30%)
  v_n := jsonb_array_length(v_items);
  for v_ped in
    select p.id, p.folio_externo,
           (select count(*) from jsonb_array_elements(v_items) x
             where exists (select 1 from pedido_compra_items i join productos pr on pr.id = i.producto_id
                            where i.pedido_id = p.id and pr.codigo = x->>'cod')) as hits
      from (select * from pedidos_compra where estado in ('enviado','parcial','recibido') and proveedor_id = v_prov
            order by id desc limit 80) p
  loop
    if v_n > 0 and v_ped.hits::numeric / v_n > v_score then
      v_score := v_ped.hits::numeric / v_n; v_best := v_ped.id; v_best_folio := v_ped.folio_externo;
    end if;
  end loop;
  if v_best is null or v_score < 0.3 then
    return jsonb_build_object('estado','revisar','folio',v_folio,'total',v_total,'motivo','no encontré su pedido (mejor coincidencia '||round(v_score*100)||'%)');
  end if;

  -- partidas que vienen en la factura pero no en el pedido → no se aplica
  for it in select * from jsonb_array_elements(v_items) loop
    if not exists (select 1 from pedido_compra_items i join productos pr on pr.id = i.producto_id
                    where i.pedido_id = v_best and pr.codigo = it->>'cod') then
      v_fuera := v_fuera || to_jsonb(it->>'cod');
    end if;
  end loop;
  if jsonb_array_length(v_fuera) > 0 then
    return jsonb_build_object('estado','revisar','folio',v_folio,'total',v_total,'pedido',v_best_folio,
      'motivo','partidas que no están en el pedido: '||(select string_agg(x,', ') from jsonb_array_elements_text(v_fuera) x));
  end if;

  -- aplicar: costo al precio facturado, cantidad facturada, CxP real (igual que aplicarFacturas)
  for it in select * from jsonb_array_elements(v_items) loop
    select i.id, i.producto_id, i.cantidad, i.cantidad_facturada, i.costo_unit, pr.precio into r
      from pedido_compra_items i join productos pr on pr.id = i.producto_id
     where i.pedido_id = v_best and pr.codigo = it->>'cod' order by i.id limit 1;
    if abs(r.costo_unit - (it->>'pu')::numeric) > 0.015 then
      v_precios := v_precios || jsonb_build_object('cod', it->>'cod', 'antes', r.costo_unit, 'ahora', (it->>'pu')::numeric,
                                                   'cant', (it->>'cant')::numeric, 'precio_venta', r.precio);
    end if;
    update pedido_compra_items set costo_unit = (it->>'pu')::numeric,
           importe = round(cantidad * (it->>'pu')::numeric, 2),
           cantidad_facturada = coalesce(cantidad_facturada,0) + (it->>'cant')::numeric
     where id = r.id;
    if (it->>'pu')::numeric > 0 then update productos set costo = (it->>'pu')::numeric where id = r.producto_id; end if;
    v_partidas := v_partidas + 1;
  end loop;

  insert into cuentas_pagar(proveedor_id, concepto, referencia, fecha_emision, fecha_vencimiento, monto, saldo)
  values (v_prov, 'Factura '||v_folio||coalesce(' (pedido '||v_best_folio||')',''),
          'PPD crédito '||v_dias||' días · '||left(coalesce(p_doc->>'nombre', v_uuid||'.xml'),30)||' · agente Mac',
          coalesce(v_fecha, current_date), coalesce(v_fecha, current_date) + v_dias, v_total, v_total);
  if v_best_folio is not null then
    update cuentas_pagar set saldo = 0, estado = 'pagada', referencia = 'Sustituida por facturas XML del pedido'
     where concepto = 'Pedido Web #'||v_best_folio and estado <> 'pagada';
  end if;
  insert into facturas(uuid, folio, tipo, fecha, subtotal, total, dias, pedido_id, items)
  values (v_uuid, v_folio, v_tipo, v_fecha, v_sub, v_total, v_dias, v_best, v_items);

  -- Indar: renglones que no se facturaron en una parte ya facturada = cancelados por falta de existencia
  if exists (select 1 from proveedores where id = v_prov and nombre ilike '%indar%') then
    for r in select i.id, i.parte, i.cantidad, coalesce(i.cantidad_recibida,0) rec, coalesce(i.cantidad_facturada,0) fac, i.costo_unit, pr.codigo
               from pedido_compra_items i left join productos pr on pr.id = i.producto_id
              where i.pedido_id = v_best
                and exists (select 1 from pedido_compra_items j where j.pedido_id = v_best and coalesce(j.parte,'') = coalesce(i.parte,'')
                             and coalesce(j.cantidad_facturada,0) > 0) loop
      if r.fac = 0 and r.rec = 0 then
        delete from pedido_compra_items where id = r.id; v_cancel := v_cancel || to_jsonb(coalesce(r.codigo,'?'));
      elsif r.fac > 0 and r.fac < r.cantidad and r.rec <= r.fac then
        update pedido_compra_items set cantidad = r.fac, importe = round(r.fac * r.costo_unit, 2) where id = r.id;
        v_cancel := v_cancel || to_jsonb(coalesce(r.codigo,'?')||' ('||r.cantidad||'→'||r.fac||')');
      end if;
    end loop;
  end if;

  select round(coalesce(sum(importe),0),2) into v_sub2 from pedido_compra_items where pedido_id = v_best;
  update pedidos_compra set subtotal = v_sub2, iva = round(v_sub2*0.16,2), total = round(v_sub2*1.16,2) where id = v_best;

  return jsonb_build_object('estado','aplicada','folio',v_folio,'total',v_total,'pedido',v_best_folio,'partidas',v_partidas,
    'coincidencia',round(v_score*100),'cambios_precio',v_precios,'cancelados_indar',v_cancel,
    'vence', coalesce(v_fecha, current_date) + v_dias);
end $$;

-- para el PDF: la Edge Function agente-factura-pdf sube el archivo y llama esta para ligarlo
create or replace function public.agente_ligar_pdf_factura(p_llave text, p_uuid text, p_path text)
returns boolean language plpgsql security definer set search_path to 'public','extensions' as $$
begin
  if not agente_llave_ok(p_llave) then raise exception 'llave invalida'; end if;
  update facturas set pdf_path = p_path where upper(uuid) = upper(p_uuid) and pdf_path is null;
  return found;
end $$;

revoke all on function public.agente_facturas_conocidas(text) from public;
revoke all on function public.agente_importar_factura(text, jsonb) from public;
revoke all on function public.agente_ligar_pdf_factura(text, text, text) from public;
grant execute on function public.agente_facturas_conocidas(text) to anon, authenticated;
grant execute on function public.agente_importar_factura(text, jsonb) to anon, authenticated;
grant execute on function public.agente_ligar_pdf_factura(text, text, text) to anon, authenticated;
