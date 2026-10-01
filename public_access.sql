-- Открывает сайту (публичному ключу): чтение оценок (ФИО, класс, предмет, оценка, дата)
-- и изменение только оценки. Адреса, телефоны и прочее остаются закрытыми.
-- Самодостаточный файл: grade_edit.sql отдельно запускать не нужно. Можно запускать повторно.
-- Выполнить: Supabase -> SQL Editor -> вставить -> Run.

drop view if exists public.grades_public;

create view public.grades_public as
select g.id,
       s.full_name   as student,
       c.name        as class_name,
       sub.name      as subject,
       g.value,
       g.given_on
from public.grades g
join public.students s   on s.id   = g.student_id
join public.subjects sub on sub.id = g.subject_id
left join public.classes c on c.id = s.class_id;

grant select on public.grades_public to anon, authenticated;

-- Изменение оценки: функция меняет ТОЛЬКО grades.value, значения 2-5
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
grant execute on function public.set_grade(bigint, int) to anon, authenticated;
