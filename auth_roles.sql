-- Вход по почте и паролю с ролями: родитель, учитель, ученик + регистрация ученика.
-- Выполнить один раз целиком: Supabase -> SQL Editor -> вставить -> Run.
-- Файл можно запускать повторно. Тестовые пользователи создаются отдельно: test_users.sql.
--
-- Ничего напрямую в таблицы сайт не пишет и не читает: все данные идут через функции,
-- которые сами смотрят, кто вошёл, и отдают только положенное.

-- 1. Кто есть кто: связь пользователя входа с учеником / родителем / учителем
create table if not exists public.profiles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  role       text not null check (role in ('student', 'parent', 'teacher')),
  student_id bigint references public.students(id) on delete cascade,
  parent_id  bigint references public.parents(id)  on delete cascade,
  teacher_id bigint references public.teachers(id) on delete cascade,
  check (
    (role = 'student' and student_id is not null) or
    (role = 'parent'  and parent_id  is not null) or
    (role = 'teacher' and teacher_id is not null)
  )
);
alter table public.profiles enable row level security;

-- 2. Кто какой предмет ведёт в каком классе (заполняется по уже выставленным оценкам;
--    новые назначения можно добавлять в таблицу teaching руками)
create table if not exists public.teaching (
  teacher_id bigint not null references public.teachers(id) on delete cascade,
  subject_id bigint not null references public.subjects(id) on delete cascade,
  class_id   bigint not null references public.classes(id)  on delete cascade,
  primary key (teacher_id, subject_id, class_id)
);
alter table public.teaching enable row level security;

insert into public.teaching (teacher_id, subject_id, class_id)
select distinct g.teacher_id, g.subject_id, s.class_id
from public.grades g
join public.students s on s.id = g.student_id
where g.teacher_id is not null and g.subject_id is not null and s.class_id is not null
on conflict do nothing;

-- 3. Вспомогательная: ученики, которых видит текущий пользователь
--    (ученик — себя, родитель — своих детей)
create or replace function public.my_student_ids()
returns setof bigint
language sql stable security definer set search_path = public as $$
  select p.student_id::bigint
  from public.profiles p
  where p.user_id = auth.uid() and p.role = 'student'
  union
  select sp.student_id::bigint
  from public.profiles p
  join public.student_parents sp on sp.parent_id = p.parent_id
  where p.user_id = auth.uid() and p.role = 'parent'
$$;

-- 4. Кто я (роль и имя)
create or replace function public.my_profile()
returns table (role text, full_name text)
language sql stable security definer set search_path = public as $$
  select p.role::text,
         coalesce(s.full_name, pa.full_name, t.full_name)::text
  from public.profiles p
  left join public.students s  on s.id  = p.student_id
  left join public.parents  pa on pa.id = p.parent_id
  left join public.teachers t  on t.id  = p.teacher_id
  where p.user_id = auth.uid()
$$;

-- 5. Оценки, которые я вправе видеть
--    Учитель: все ученики классов, где он ведёт предмет (+ оценки по этому предмету)
--    Ученик: свои оценки. Родитель: оценки своих детей.
create or replace function public.my_grades()
returns table (
  grade_id   bigint,
  student_id bigint,
  student    text,
  class_name text,
  subject    text,
  teacher    text,
  value      int,
  given_on   date,
  can_edit   boolean
)
language sql stable security definer set search_path = public as $$
  with me as (
    select p.role, p.teacher_id from public.profiles p where p.user_id = auth.uid()
  )
  select g.id::bigint, s.id::bigint, s.full_name::text, c.name::text, sub.name::text,
         t.full_name::text, g.value::int, g.given_on::date, true
  from me
  join public.teaching th on me.role = 'teacher' and th.teacher_id = me.teacher_id
  join public.students s  on s.class_id = th.class_id
  join public.classes c   on c.id = th.class_id
  join public.subjects sub on sub.id = th.subject_id
  left join public.grades g on g.student_id = s.id and g.subject_id = th.subject_id
  left join public.teachers t on t.id = g.teacher_id
  union all
  select g.id::bigint, s.id::bigint, s.full_name::text, c.name::text, sub.name::text,
         t.full_name::text, g.value::int, g.given_on::date, false
  from me
  join public.students s on me.role in ('student', 'parent')
                        and s.id in (select public.my_student_ids())
  left join public.classes c on c.id = s.class_id
  join public.grades g    on g.student_id = s.id
  join public.subjects sub on sub.id = g.subject_id
  left join public.teachers t on t.id = g.teacher_id
$$;

-- 6. Предметы и учителя, которые ведут их в классе ученика (для ученика и родителя)
create or replace function public.my_subjects()
returns table (student_id bigint, student text, class_name text, subject text, teachers text)
language sql stable security definer set search_path = public as $$
  select s.id::bigint, s.full_name::text, c.name::text, sub.name::text,
         string_agg(distinct t.full_name::text, ', ' order by t.full_name::text)
  from public.students s
  join public.classes c    on c.id = s.class_id
  join public.teaching th  on th.class_id = s.class_id
  join public.subjects sub on sub.id = th.subject_id
  join public.teachers t   on t.id = th.teacher_id
  where s.id in (select public.my_student_ids())
  group by s.id, s.full_name, c.name, sub.name
$$;

-- 7. Изменение оценки: только учитель и только по своему предмету в своём классе
create or replace function public.set_grade(p_id bigint, p_value int)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_teacher bigint;
begin
  if p_value is null or p_value not between 2 and 5 then
    raise exception 'Оценка должна быть от 2 до 5';
  end if;

  select p.teacher_id into v_teacher
  from public.profiles p
  where p.user_id = auth.uid() and p.role = 'teacher';

  if v_teacher is null then
    raise exception 'Менять оценки могут только учителя';
  end if;

  update public.grades g
  set value = p_value
  where g.id = p_id
    and exists (
      select 1
      from public.students s
      join public.teaching th on th.class_id = s.class_id
      where s.id = g.student_id
        and th.subject_id = g.subject_id
        and th.teacher_id = v_teacher
    );

  if not found then
    raise exception 'Оценка не найдена или относится не к вашему предмету и классу';
  end if;
end;
$$;

-- 8. Список классов для формы регистрации (доступен до входа)
create or replace function public.list_classes()
returns table (id bigint, name text)
language sql stable security definer set search_path = public as $$
  select c.id::bigint, c.name::text from public.classes c order by c.name
$$;

-- 9. Регистрация ученика: при создании пользователя с ФИО и классом в метаданных
--    создаём запись ученика и профиль. Роль из метаданных НЕ читается: самому себе
--    стать учителем или родителем через регистрацию нельзя.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_name  text := nullif(trim(new.raw_user_meta_data->>'full_name'), '');
  v_class bigint;
  v_sid   bigint;
  v_cols  text := 'full_name, class_id';
  v_vals  text := '$1, $2';
  r       record;
  v_val   text;
begin
  begin
    v_class := (new.raw_user_meta_data->>'class_id')::bigint;
  exception when others then
    v_class := null;
  end;

  -- пользователь создан администратором (без данных регистрации): профиль задаётся вручную
  if v_name is null or v_class is null
     or not exists (select 1 from public.classes c where c.id = v_class) then
    return new;
  end if;

  -- обязательные колонки students, о которых форма не знает, заполняем нейтрально
  for r in
    select column_name, data_type
    from information_schema.columns
    where table_schema = 'public' and table_name = 'students'
      and is_nullable = 'NO' and column_default is null and is_identity = 'NO'
      and column_name not in ('full_name', 'class_id')
  loop
    v_val := case
      when r.column_name = 'id'
        then '(select coalesce(max(id), 0) + 1 from public.students)'
      when r.column_name = 'personnel_number' and r.data_type in ('smallint', 'integer', 'bigint', 'numeric')
        then '(select coalesce(max(personnel_number), 0) + 1 from public.students)'
      when r.column_name = 'personnel_number'
        then quote_literal('REG-' || substr(replace(new.id::text, '-', ''), 1, 10))
      when r.data_type in ('smallint', 'integer', 'bigint', 'numeric') then '0'
      when r.data_type = 'date' then 'current_date'
      when r.data_type like 'timestamp%' then 'now()'
      when r.data_type = 'boolean' then 'false'
      else quote_literal('')
    end;
    v_cols := v_cols || ', ' || quote_ident(r.column_name);
    v_vals := v_vals || ', ' || v_val;
  end loop;

  execute format('insert into public.students (%s) values (%s) returning id', v_cols, v_vals)
    into v_sid using v_name, v_class;

  insert into public.profiles (user_id, role, student_id) values (new.id, 'student', v_sid);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 10. Права: без входа (anon) доступен только список классов для регистрации
revoke all on function public.my_student_ids() from public, anon, authenticated;
revoke all on function public.my_profile(), public.my_grades(), public.my_subjects(),
                       public.set_grade(bigint, int) from public, anon;
grant execute on function public.my_profile(), public.my_grades(), public.my_subjects(),
                          public.set_grade(bigint, int) to authenticated;
revoke all on function public.list_classes() from public;
grant execute on function public.list_classes() to anon, authenticated;

-- Старое открытое представление больше не нужно: оценки теперь только после входа
drop view if exists public.grades_public;

notify pgrst, 'reload schema';
