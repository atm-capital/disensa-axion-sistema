-- v261: el agente de la Mac importa solo los pedidos de Indar y Truper que no están en el sistema.
-- Misma lógica que "Importar" (Indar: ejecutarImport/importarUnPedido) y "Pedido de Truper" (trPedGuardar).
-- DECISIÓN DE ANDRÉS (23-nov-2026): productos nuevos se dan de alta solos (stock 0) y se le avisa para revisar el precio;
--   Indar: precio = regla de margen del sistema (config_sistema.regla_margen, 40/35/30 s/venta sobre el costo de lista);
--   Truper: precio público con IVA de su catálogo (lista_truper), o la regla si no viene.
--   Nunca abajo del costo con IVA. Plazo: crédito 30 días para los dos.
-- Los productos que ya existen: Indar actualiza SOLO el costo (v100); el precio de venta nunca se toca.
create or replace function public.agente_importar_pedido(p_llave text, p_ped jsonb)
returns jsonb language plpgsql security definer set search_path to 'public','extensions' as $$
declare
  v_tipo text := lower(coalesce(p_ped->>'proveedor',''));
  v_folio text := regexp_replace(coalesce(p_ped->>'folio',''), '^0+', '');
  v_fecha date := coalesce(nullif(p_ped->>'fecha','')::date, (now() at time zone 'America/Mexico_City')::date);
  v_prov bigint; v_pid bigint; v_regla jsonb; it jsonb; v_lt record; v_cod text; v_desc text; v_costo numeric; v_precio numeric;
  v_ref numeric; v_m numeric; v_prod bigint; v_fam text; v_uni text; v_ean text; v_pub numeric; v_sub numeric := 0; v_nuevos jsonb := '[]'::jsonb; v_n int := 0; v_tot numeric; v_cxp text;
begin
  if not agente_llave_ok(p_llave) then raise exception 'llave invalida'; end if;
  if v_folio = '' or v_tipo not in ('indar','truper') then return jsonb_build_object('estado','error','motivo','falta folio o proveedor'); end if;
  select id into v_prov from proveedores where nombre ilike v_tipo||'%' order by id limit 1;
  if v_prov is null then return jsonb_build_object('estado','error','motivo','no existe el proveedor '||v_tipo); end if;
  if exists (select 1 from pedidos_compra where proveedor_id = v_prov and regexp_replace(coalesce(folio_externo,''),'^0+','') = v_folio) then
    return jsonb_build_object('estado','ya','folio',v_folio);
  end if;
  if jsonb_array_length(coalesce(p_ped->'items','[]'::jsonb)) = 0 then return jsonb_build_object('estado','error','folio',v_folio,'motivo','sin partidas'); end if;
  select valor into v_regla from config_sistema where clave = 'regla_margen';
  if v_regla is null or jsonb_array_length(v_regla) <> 3 then v_regla := '[40,35,30]'::jsonb; end if;

  insert into pedidos_compra(proveedor_id, folio_externo, fecha, estado, plazo_dias, subtotal, iva, total, notas)
  values (v_prov, v_folio, v_fecha, 'enviado', 30, 0, 0, 0,
          case v_tipo when 'indar' then 'Importado solo por el agente de la Mac (portal Indar). Partes: '||coalesce(p_ped->>'partes','')||'. Capturado a precio de lista; se ajusta contra factura.'
                      else 'Pedido Truper en línea #'||v_folio||coalesce(' (orden '||nullif(p_ped->>'orden','')||')','')||'. Importado solo por el agente de la Mac. Pago: crédito 30 días.' end)
  returning id into v_pid;

  for it in select * from jsonb_array_elements(p_ped->'items') loop
    v_cod := trim(it->>'cod'); v_desc := coalesce(nullif(trim(it->>'desc'),''), v_cod);
    v_costo := round(coalesce((it->>'costo')::numeric,0), 4);
    v_fam := null; v_uni := null; v_ean := null; v_pub := null;
    if v_tipo = 'truper' then -- el CSV trae el "material"; el código del producto es la CLAVE del catálogo Truper
      select nullif(trim(clave),'') as clave2, descripcion, familia_desc, unidad, ean, precio_publico_iva
        into v_lt from lista_truper where codigo = v_cod limit 1;
      if found then
        v_cod := coalesce(v_lt.clave2, v_cod); v_desc := coalesce(v_lt.descripcion, v_desc);
        v_fam := v_lt.familia_desc; v_uni := v_lt.unidad; v_ean := v_lt.ean; v_pub := v_lt.precio_publico_iva;
      end if;
    end if;
    v_prod := null;
    select id into v_prod from productos where upper(codigo) = upper(v_cod) limit 1;
    if v_prod is null then
      -- producto nuevo: público Truper o regla de margen del sistema; nunca abajo del costo con IVA
      v_precio := case when v_tipo = 'truper' then ceil(coalesce(v_pub,0) - 0.001) else 0 end;
      if coalesce(v_precio,0) <= 0 then
        v_ref := case when coalesce((it->>'sugerido')::numeric,0) > 0 then (it->>'sugerido')::numeric else v_costo*1.16/0.754 end;
        v_m := (case when v_ref <= 200 then (v_regla->>0)::numeric when v_ref <= 500 then (v_regla->>1)::numeric else (v_regla->>2)::numeric end)/100;
        v_precio := case when v_costo > 0 and v_m < 1 then ceil(v_costo/(1-v_m)*1.16 - 0.001) else ceil(coalesce((it->>'sugerido')::numeric,0) - 0.001) end;
      end if;
      v_precio := greatest(coalesce(v_precio,0), ceil(v_costo*1.16 - 0.001));
      if coalesce(v_ean,'') <> '' and exists (select 1 from productos where codigo_barras = v_ean) then v_ean := null; end if;
      insert into productos(codigo, descripcion, categoria, costo, precio, stock, stock_min, unidad, codigo_barras, activo)
      values (v_cod, v_desc, case when v_tipo='truper' then coalesce(v_fam,'Truper') else 'General' end,
              round(v_costo,2), v_precio, 0, 3,
              case when lower(coalesce(v_uni,'pza')) like 'pieza%' then 'pza' else lower(coalesce(v_uni,'pza')) end, coalesce(v_ean,''), true)
      returning id into v_prod;
      v_nuevos := v_nuevos || jsonb_build_object('cod', v_cod, 'desc', left(v_desc,60), 'costo', round(v_costo,2), 'precio', v_precio);
    elsif v_tipo = 'indar' and v_costo > 0 then
      update productos set costo = round(v_costo,2) where id = v_prod;   -- v100: solo el costo
    end if;
    insert into pedido_compra_items(pedido_id, producto_id, parte, cantidad, costo_unit, importe)
    values (v_pid, v_prod, coalesce(it->>'parte',''), (it->>'cant')::numeric, v_costo, round((it->>'cant')::numeric * v_costo, 2));
    v_sub := v_sub + round((it->>'cant')::numeric * v_costo, 2); v_n := v_n + 1;
  end loop;

  v_tot := round(v_sub*1.16, 2);
  update pedidos_compra set subtotal = round(v_sub,2), iva = round(v_sub*0.16,2), total = v_tot where id = v_pid;
  v_cxp := case v_tipo when 'indar' then 'Pedido Web #'||v_folio else 'Pedido Truper #'||v_folio end;
  insert into cuentas_pagar(proveedor_id, concepto, referencia, fecha_emision, fecha_vencimiento, monto, saldo)
  values (v_prov, v_cxp, 'Plazo 30 días · agente Mac', v_fecha, v_fecha + 30, v_tot, v_tot);
  return jsonb_build_object('estado','importado','proveedor',v_tipo,'folio',v_folio,'partidas',v_n,'total',v_tot,'nuevos',v_nuevos);
end $$;
revoke all on function public.agente_importar_pedido(text, jsonb) from public;
grant execute on function public.agente_importar_pedido(text, jsonb) to anon, authenticated;

-- la CxP estimada del pedido de Truper también se sustituye al aplicar su factura real (antes solo la de Indar)
-- (se aplica con un replace dentro de agente_importar_factura; ver 03)

-- (aplicado también) agente_facturas_conocidas ahora regresa pedidos_truper y los pedidos de Indar aunque estén cancelados,
-- para que el agente no vuelva a importar un pedido que se canceló a propósito.
