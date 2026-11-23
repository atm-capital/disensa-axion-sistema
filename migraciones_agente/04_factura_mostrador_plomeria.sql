-- v262: Facturas de proveedores de MOSTRADOR (Plomería Universal): la factura ES el pedido.
-- Si llega una factura de un proveedor de mostrador y no existe su pedido "CD <folio>", el agente
-- crea el pedido desde la factura (estado 'enviado', para que la tienda lo reciba y entre al stock),
-- da de alta los productos nuevos con la regla de margen y deja la CxP contra entrega (vence el mismo día).
-- Idempotente: se puede correr dos veces.
begin;

-- Proveedores de mostrador y su plazo en días (0 = contra entrega). Andrés lo cambia aquí cuando le den crédito.
insert into config_sistema(clave, valor)
select 'proveedores_mostrador', '{"3": 0}'::jsonb
where not exists (select 1 from config_sistema where clave = 'proveedores_mostrador');

-- La función original queda como _base (solo se renombra la primera vez).
do $$
begin
  if not exists (select 1 from pg_proc where proname = 'agente_importar_factura_base') then
    alter function agente_importar_factura(text, jsonb) rename to agente_importar_factura_base;
  end if;
end $$;

create or replace function agente_importar_factura(p_llave text, p_doc jsonb)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $function$
declare
  v_emisor text := upper(coalesce(p_doc->>'emisor',''));
  v_folio text := coalesce(p_doc->>'folio','');
  v_tipo text := coalesce(p_doc->>'tipo','');
  v_fecha date := coalesce(nullif(p_doc->>'fecha','')::date, (now() at time zone 'America/Mexico_City')::date);
  v_cfg jsonb; v_prov bigint; v_dias int; v_serie text; v_fext text; v_pid bigint; v_regla jsonb;
  it jsonb; v_cod text; v_costo numeric; v_prod bigint; v_ref numeric; v_m numeric; v_precio numeric;
  v_sub numeric := 0; v_nuevos jsonb := '[]'::jsonb; v_res jsonb; v_doc jsonb := p_doc;
begin
  if not agente_llave_ok(p_llave) then raise exception 'llave invalida'; end if;
  select valor into v_cfg from config_sistema where clave = 'proveedores_mostrador';
  if v_tipo = 'I' and v_folio <> '' and v_cfg is not null then
    select id into v_prov from proveedores
     where (v_emisor like '%PLOMER%UNIVERSAL%' and nombre ilike '%plomer%universal%')
       and v_cfg ? id::text
     order by id limit 1;
  end if;
  if v_prov is not null and not exists (select 1 from facturas where upper(uuid) = upper(coalesce(p_doc->>'uuid',''))) then
    v_dias := coalesce((v_cfg->>v_prov::text)::int, 0);
    v_doc := jsonb_set(p_doc, '{dias}', to_jsonb(v_dias));
    v_serie := nullif(trim(coalesce(p_doc->>'serie','CD')), '');
    v_fext := coalesce(v_serie || ' ', '') || v_folio;
    if not exists (select 1 from pedidos_compra where proveedor_id = v_prov
                    and regexp_replace(coalesce(folio_externo,''), '^.*\s', '') = v_folio) then
      select valor into v_regla from config_sistema where clave = 'regla_margen';
      if v_regla is null or jsonb_array_length(v_regla) <> 3 then v_regla := '[40,35,30]'::jsonb; end if;
      insert into pedidos_compra(proveedor_id, folio_externo, fecha, estado, plazo_dias, subtotal, iva, total, notas)
      values (v_prov, v_fext, v_fecha, 'enviado', v_dias, 0, 0, 0,
              'Compra de mostrador: pedido creado solo por el agente de la Mac desde la factura ' || v_fext || '. Falta recibirlo en tienda.')
      returning id into v_pid;
      for it in select * from jsonb_array_elements(coalesce(p_doc->'items','[]'::jsonb)) loop
        v_cod := trim(it->>'cod'); v_costo := round(coalesce((it->>'pu')::numeric, 0), 4);
        v_prod := null;
        select id into v_prod from productos where upper(codigo) = upper(v_cod) limit 1;
        if v_prod is null then
          v_ref := v_costo * 1.16 / 0.754;
          v_m := (case when v_ref <= 200 then (v_regla->>0)::numeric when v_ref <= 500 then (v_regla->>1)::numeric else (v_regla->>2)::numeric end) / 100;
          v_precio := greatest(ceil(v_costo / (1 - v_m) * 1.16 - 0.001), ceil(v_costo * 1.16 - 0.001));
          insert into productos(codigo, descripcion, categoria, costo, precio, stock, stock_min, unidad, codigo_barras, activo)
          values (v_cod, coalesce(nullif(trim(it->>'desc'),''), v_cod), 'Plomería', round(v_costo,2), v_precio, 0, 3, 'pza', '', true)
          returning id into v_prod;
          v_nuevos := v_nuevos || jsonb_build_object('cod', v_cod, 'desc', left(coalesce(it->>'desc',''),60), 'costo', round(v_costo,2), 'precio', v_precio);
        end if;
        insert into pedido_compra_items(pedido_id, producto_id, parte, cantidad, costo_unit, importe)
        values (v_pid, v_prod, '', (it->>'cant')::numeric, v_costo, round((it->>'cant')::numeric * v_costo, 2));
        v_sub := v_sub + round((it->>'cant')::numeric * v_costo, 2);
      end loop;
      update pedidos_compra set subtotal = round(v_sub,2), iva = round(v_sub*0.16,2), total = round(v_sub*1.16,2) where id = v_pid;
    end if;
  end if;

  v_res := agente_importar_factura_base(p_llave, v_doc);

  if v_prov is not null and v_res->>'estado' = 'aplicada' then
    update cuentas_pagar
       set referencia = case when v_dias = 0 then 'Contra entrega' else 'Crédito ' || v_dias || ' días' end
                        || ' · Plomería Universal de Occidente · agente Mac'
     where proveedor_id = v_prov and concepto like 'Factura ' || v_folio || ' (%' and referencia like 'PPD crédito%';
    v_res := v_res || jsonb_build_object('pedido_creado', v_pid is not null, 'nuevos', v_nuevos, 'mostrador', true);
  end if;
  return v_res;
end $function$;

grant execute on function agente_importar_factura(text, jsonb) to anon, authenticated, service_role;

select proname from pg_proc where proname like 'agente_importar_factura%' order by 1;
commit;
