-- v265 (25-nov-2026): candado EN LA BASE para salidas de caja de la tienda (rol vendedor).
-- Antes el candado solo estaba en pantalla y solo para tipo 'gasto'; la tienda registraba gastos como 'retiro'
-- y se lo brincaba. Ahora, para el rol vendedor, toda salida (gasto o retiro) solo pasa si es:
--   · depósito / movimiento de dinero (retiro a bóveda o banco)
--   · BASURA hasta $20
--   · SUELDO ASEO hasta $400, uno por semana (lunes a domingo)
--   · NÓMINA o BONO de un empleado activo de nomina_empleados (autorizados por Andrés, 25-nov-2026)
--   · los movimientos automáticos del sistema: pago a proveedor, fondeo AK Pago
-- Todo lo demás se pide en "Necesito algo". Además, solo admin edita o borra movimientos de caja.
-- Admin, contador y los agentes (sin sesión) no tienen este candado. Idempotente.
begin;

create or replace function caja_candado_salidas() returns trigger language plpgsql security definer set search_path = public as $$
declare v_rol text := mi_rol(); v_lunes date; v_c text := coalesce(new.concepto,'');
begin
  if auth.uid() is null or v_rol is distinct from 'vendedor' then return new; end if;
  if new.tipo = 'entrada' then return new; end if;
  if v_c ~* '^(Pago a |Fondeo monedero AK Pago)' then return new; end if;
  if new.tipo = 'retiro' and v_c ~* 'Dep[oó]sito / movimiento de dinero' then return new; end if;
  if v_c ~* '^BASURA' then
    if new.monto <= 20 then return new; end if;
    raise exception 'Basura: máximo $20. Si es más, pide autorización en "Necesito algo".';
  end if;
  if v_c ~* '^SUELDO ASEO' then
    if new.monto > 400 then raise exception 'Sueldo de aseo: máximo $400 por semana. Si es más, pide autorización.'; end if;
    v_lunes := coalesce(new.fecha, current_date) - ((extract(isodow from coalesce(new.fecha, current_date))::int) - 1);
    if exists (select 1 from caja_movs m where m.tipo in ('gasto','retiro') and m.concepto ~* 'aseo' and m.concepto !~* 'art[ií]culos'
                and m.fecha >= v_lunes and m.fecha < v_lunes + 7) then
      raise exception 'El sueldo de aseo de esta semana ya se registró. Otro pago necesita autorización de Andrés.';
    end if;
    return new;
  end if;
  if v_c ~* '^(N[OÓ]MINA|BONO)' then
    if exists (select 1 from nomina_empleados e where e.activo and length(e.nombre) >= 4 and v_c ilike '%' || left(e.nombre, 5) || '%') then return new; end if;
    raise exception 'Nómina o bono: escribe el nombre del empleado (Carlos o Marcos).';
  end if;
  raise exception 'Esa salida de dinero necesita autorización de Andrés: pídela en "Necesito algo". Sin autorización solo basura (≤$20), sueldo de aseo (≤$400/semana), nómina/bonos y depósitos.';
end $$;

drop trigger if exists trg_caja_candado_salidas on caja_movs;
create trigger trg_caja_candado_salidas before insert on caja_movs for each row execute function caja_candado_salidas();

-- solo admin edita o borra movimientos de caja
drop policy if exists cm_upd on caja_movs;
create policy cm_upd on caja_movs for update to authenticated using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
drop policy if exists cm_del on caja_movs;
create policy cm_del on caja_movs for delete to authenticated using (mi_rol() = 'admin');

commit;
