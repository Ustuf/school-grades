-- Политики RLS на таблицах: кто какие строки и колонки может читать напрямую через API.
-- Запускать ПОСЛЕ auth_roles.sql (нужны таблицы profiles и teaching и функция my_student_ids).
-- Выполнить: Supabase -> SQL Editor -> вставить -> Run. Можно запускать повторно.
--
-- Родитель: своего ребёнка, его класс, предметы, оценки, даты, учителей предметов.
-- Ученик:   себя, свой класс, предметы, оценки, даты, учителей.
-- Учитель:  учеников своих классов, класс, свой предмет, оценки и даты по нему.
--           Менять может только значение оценки (grades.value) по своему предмету и классу.
-- Без входа (anon): ничего.
--
-- Адрес, телефон, дата рождения учеников и телефоны учителей и родителей закрыты
-- правами на колонки: через API читаются только перечисленные ниже поля.
-- Запрос "select=*" к students, classes, teachers, parents вернёт ошибку доступа,
-- нужно перечислять колонки (select=id,full_name,class_id).

-- 1. Помощники для политик. Работают от имени владельца (мимо RLS), чтобы политики
--    не зацикливались друг на друге, и смотрят только на текущего пользователя.
create or replace function public.rls_teacher_id()
returns bigint language sql stable security definer set search_path = public as $$
  select p.teacher_id::bigint from public.profiles p
  where p.user_id = auth.uid() and p.role = 'teacher'
$$;

create or replace function public.rls_parent_id()
returns bigint language sql stable security definer set search_path = public as $$
  select p.parent_id::bigint from public.profiles p
  where p.user_id = auth.uid() and p.role = 'parent'
$$;

-- ученик: он сам; родитель: его дети
create or replace function public.my_student_ids()
returns setof bigint language sql stable security definer set search_path = public as $$
  select p.student_id::bigint from public.profiles p
  where p.user_id = auth.uid() and p.role = 'student'
  union
  select sp.student_id::bigint
  from public.profiles p
  join public.student_parents sp on sp.parent_id = p.parent_id
  where p.user_id = auth.uid() and p.role = 'parent'
$$;

-- классы, где учится «мой» ученик (для ученика и родителя)
create or replace function public.rls_child_class_ids()
returns setof bigint language sql stable security definer set search_path = public as $$
  select s.class_id::bigint from public.students s
  where s.id in (select public.my_student_ids()) and s.class_id is not null
$$;

-- классы, где учитель ведёт предмет
create or replace function public.rls_teacher_class_ids()
returns setof bigint language sql stable security definer set search_path = public as $$
  select th.class_id::bigint from public.teaching th
  where th.teacher_id = public.rls_teacher_id()
$$;

-- предметы: у ученика/родителя — предметы класса и те, по которым есть оценки; у учителя — свои
create or replace function public.rls_subject_ids()
returns setof bigint language sql stable security definer set search_path = public as $$
  select th.subject_id::bigint from public.teaching th
  where th.teacher_id = public.rls_teacher_id()
     or th.class_id in (select public.rls_child_class_ids())
  union
  select g.subject_id::bigint from public.grades g
  where g.student_id in (select public.my_student_ids())
$$;

-- учителя: у ученика/родителя — те, кто ведёт предметы в классе или ставил оценки; у учителя — он сам
create or replace function public.rls_teacher_ids()
returns setof bigint language sql stable security definer set search_path = public as $$
  select th.teacher_id::bigint from public.teaching th
  where th.class_id in (select public.rls_child_class_ids())
  union
  select g.teacher_id::bigint from public.grades g
  where g.student_id in (select public.my_student_ids()) and g.teacher_id is not null
  union
  select public.rls_teacher_id() where public.rls_teacher_id() is not null
$$;

-- учитель ведёт этот предмет в классе этого ученика?
create or replace function public.rls_teaches(p_student bigint, p_subject bigint)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.students s
    join public.teaching th on th.class_id = s.class_id
    where s.id = p_student
      and th.subject_id = p_subject
      and th.teacher_id = public.rls_teacher_id()
  )
$$;

revoke all on function
  public.rls_teacher_id(), public.rls_parent_id(), public.my_student_ids(),
  public.rls_child_class_ids(), public.rls_teacher_class_ids(),
  public.rls_subject_ids(), public.rls_teacher_ids(), public.rls_teaches(bigint, bigint)
from public, anon;
grant execute on function
  public.rls_teacher_id(), public.rls_parent_id(), public.my_student_ids(),
  public.rls_child_class_ids(), public.rls_teacher_class_ids(),
  public.rls_subject_ids(), public.rls_teacher_ids(), public.rls_teaches(bigint, bigint)
to authenticated;

-- 2. Права на таблицы и колонки: сначала забираем всё, потом выдаём минимум
revoke all on public.students, public.classes, public.subjects, public.teachers,
              public.parents, public.student_parents, public.grades,
              public.teaching, public.profiles
from anon, authenticated;

grant select (id, full_name, class_id)        on public.students       to authenticated;
grant select (id, name, grade_level)          on public.classes        to authenticated;
grant select                                  on public.subjects       to authenticated;
grant select (id, full_name)                  on public.teachers       to authenticated;
grant select (id, full_name)                  on public.parents        to authenticated;
grant select                                  on public.student_parents to authenticated;
grant select                                  on public.grades         to authenticated;
grant update (value)                          on public.grades         to authenticated;
grant select                                  on public.teaching       to authenticated;
grant select                                  on public.profiles       to authenticated;

-- 3. Включаем RLS
alter table public.students        enable row level security;
alter table public.classes         enable row level security;
alter table public.subjects        enable row level security;
alter table public.teachers        enable row level security;
alter table public.parents         enable row level security;
alter table public.student_parents enable row level security;
alter table public.grades          enable row level security;
alter table public.teaching        enable row level security;
alter table public.profiles        enable row level security;

-- 4. Политики
drop policy if exists students_read on public.students;
create policy students_read on public.students for select to authenticated
  using (
    id in (select public.my_student_ids())                      -- ученик сам / дети родителя
    or class_id in (select public.rls_teacher_class_ids())      -- учитель: ученики его классов
  );

drop policy if exists classes_read on public.classes;
create policy classes_read on public.classes for select to authenticated
  using (
    id in (select public.rls_child_class_ids())
    or id in (select public.rls_teacher_class_ids())
  );

drop policy if exists subjects_read on public.subjects;
create policy subjects_read on public.subjects for select to authenticated
  using (id in (select public.rls_subject_ids()));

drop policy if exists teachers_read on public.teachers;
create policy teachers_read on public.teachers for select to authenticated
  using (id in (select public.rls_teacher_ids()));

drop policy if exists grades_read on public.grades;
create policy grades_read on public.grades for select to authenticated
  using (
    student_id in (select public.my_student_ids())              -- ученик / родитель
    or public.rls_teaches(student_id, subject_id)               -- учитель своего предмета
  );

drop policy if exists grades_teacher_update on public.grades;
create policy grades_teacher_update on public.grades for update to authenticated
  using      (public.rls_teaches(student_id, subject_id))
  with check (public.rls_teaches(student_id, subject_id));

drop policy if exists teaching_read on public.teaching;
create policy teaching_read on public.teaching for select to authenticated
  using (
    teacher_id = public.rls_teacher_id()
    or class_id in (select public.rls_child_class_ids())
  );

drop policy if exists student_parents_read on public.student_parents;
create policy student_parents_read on public.student_parents for select to authenticated
  using (parent_id = public.rls_parent_id());

drop policy if exists parents_read on public.parents;
create policy parents_read on public.parents for select to authenticated
  using (id = public.rls_parent_id());

drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using (user_id = (select auth.uid()));

-- notifications (очередь для Telegram) политик не имеет: сайту закрыта, почтальон
-- работает секретным ключом и RLS обходит.

notify pgrst, 'reload schema';
