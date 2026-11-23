-- v261: al aplicar la factura real también se sustituye la CxP estimada de un pedido de Truper ("Pedido Truper #")
do $m$ declare d text; begin
  d := pg_get_functiondef('public.agente_importar_factura(text,jsonb)'::regprocedure);
  if position('Pedido Truper #' in d) = 0 then
    d := replace(d, $q$where concepto = 'Pedido Web #'||v_best_folio and estado <> 'pagada';$q$,
                    $q$where concepto in ('Pedido Web #'||v_best_folio, 'Pedido Truper #'||v_best_folio) and estado <> 'pagada';$q$);
    execute d;
  end if;
end $m$;
