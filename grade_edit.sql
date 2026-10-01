-- Разрешает сайту менять ТОЛЬКО оценку (grades.value), и только значениями 2-5.
-- Ученика, предмет, учителя и дату через эту функцию изменить нельзя.
-- Выполнить один раз: Supabase -> SQL Editor -> вставить -> Run.

create or replace function public.set_grade(p_id bigint, p_value int)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_value is null or p_value not between 2 and 5 then
    raise exception 'Оценка должна быть от 2 до 5';
  end if;

  update public.grades set value = p_value where id = p_id;

  if not found then
    raise exception 'Оценка не найдена';
  end if;
end;
$$;

revoke all on function public.set_grade(bigint, int) from public;
grant execute on function public.set_grade(bigint, int) to anon;
