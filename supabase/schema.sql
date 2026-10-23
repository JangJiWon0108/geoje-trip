-- 거제 여행 페이지용 표 — Supabase 대시보드 > SQL Editor 에서 실행한다(여러 번 실행해도 된다).
-- 실행 전에 아래 두 자리표시를 바꾼다. 이 파일은 퍼블릭 저장소에 있으므로 바꾼 값은 커밋하지 않는다.
--   CHANGE_ME        : 같이 가는 사람끼리 쓰는 여행 암호
--   CHANGE_ME_ADMIN  : 관리자 화면(admin.html) 암호

-- ─────────────────────────────────────────────────────────────
-- 요청 헤더 도우미 — 페이지가 보낸 x-trip-* 헤더와 접속 IP 를 읽는다
-- ─────────────────────────────────────────────────────────────
create or replace function public.req_header(k text) returns text
language sql stable as $$
  select coalesce(nullif(current_setting('request.headers', true), ''), '{}')::json ->> k
$$;

-- 이름은 한글이라 base64(UTF-8) 로 실어 보낸다
create or replace function public.req_user() returns text
language plpgsql stable as $$
declare v text := public.req_header('x-trip-user');
begin
  if v is null or v = '' then return null; end if;
  return convert_from(decode(v, 'base64'), 'UTF8');
exception when others then
  return null;
end $$;

-- 여행 암호 · 관리자 암호 검사
create or replace function public.trip_key_ok() returns boolean
language sql stable as $$
  select coalesce(public.req_header('x-trip-key'), '') = 'CHANGE_ME'
$$;

create or replace function public.admin_ok() returns boolean
language sql stable as $$
  select coalesce(public.req_header('x-admin-key'), '') = 'CHANGE_ME_ADMIN'
$$;

grant execute on function public.req_header(text), public.req_user(), public.trip_key_ok(), public.admin_ok() to anon;

-- ─────────────────────────────────────────────────────────────
-- 여행 항목 — 일정 · 장소 · 준비물
-- ─────────────────────────────────────────────────────────────
create table if not exists public.trip_items (
  id          bigint generated always as identity primary key,
  kind        text not null check (kind in ('schedule', 'place', 'check', 'expense', 'member')),
  day         date,
  time        time,
  title       text not null,
  category    text,
  memo        text,
  url         text,
  amount      integer,
  person      text,
  done        boolean not null default false,
  created_at  timestamptz not null default now()
);

alter table public.trip_items enable row level security;
drop policy if exists trip_items_pass on public.trip_items;
create policy trip_items_pass on public.trip_items
  for all to anon
  using (public.trip_key_ok())
  with check (public.trip_key_ok());
grant select, insert, update, delete on public.trip_items to anon;

-- ─────────────────────────────────────────────────────────────
-- 함께 가는 사람 — 이름 · 프로필 사진(data URL). 사진은 저장소가 아니라 여기에만 둔다
-- ─────────────────────────────────────────────────────────────
create table if not exists public.trip_people (
  id          bigint generated always as identity primary key,
  name        text not null unique,
  photo       text,
  sort        integer not null default 0,
  created_at  timestamptz not null default now()
);

alter table public.trip_people enable row level security;
drop policy if exists trip_people_pass on public.trip_people;
drop policy if exists trip_people_admin on public.trip_people;
create policy trip_people_pass on public.trip_people
  for all to anon
  using (public.trip_key_ok())
  with check (public.trip_key_ok());
create policy trip_people_admin on public.trip_people for select to anon using (public.admin_ok());
grant select, insert, update, delete on public.trip_people to anon;

-- ─────────────────────────────────────────────────────────────
-- 기록용 표 — 누가 · 어느 기기 · 어느 IP 는 요청 헤더에서 기본값으로 채운다
-- ─────────────────────────────────────────────────────────────
create table if not exists public.trip_visits (          -- 접속 로그
  id          bigint generated always as identity primary key,
  name        text default public.req_user(),
  device_id   text default public.req_header('x-trip-device'),
  ip          text default public.req_header('cf-connecting-ip'),
  country     text default public.req_header('cf-ipcountry'),
  user_agent  text default public.req_header('user-agent'),
  page        text,
  created_at  timestamptz not null default now()
);

create table if not exists public.trip_audit (           -- 수정 내역(트리거가 쓴다)
  id          bigint generated always as identity primary key,
  action      text not null,                             -- insert · update · delete
  item_id     bigint,
  kind        text,
  title       text,
  before      jsonb,
  after       jsonb,
  name        text default public.req_user(),
  device_id   text default public.req_header('x-trip-device'),
  ip          text default public.req_header('cf-connecting-ip'),
  created_at  timestamptz not null default now()
);

create table if not exists public.trip_cheers (          -- 개발자 응원(한 번 누를 때마다 한 줄)
  id          bigint generated always as identity primary key,
  name        text default public.req_user(),
  device_id   text default public.req_header('x-trip-device'),
  ip          text default public.req_header('cf-connecting-ip'),
  created_at  timestamptz not null default now()
);

create table if not exists public.trip_bugs (            -- 버그 신고 · 문의
  id          bigint generated always as identity primary key,
  category    text,
  content     text not null,
  status      text not null default 'new' check (status in ('new', 'done')),
  name        text default public.req_user(),
  device_id   text default public.req_header('x-trip-device'),
  ip          text default public.req_header('cf-connecting-ip'),
  user_agent  text default public.req_header('user-agent'),
  created_at  timestamptz not null default now()
);

alter table public.trip_visits enable row level security;
alter table public.trip_audit  enable row level security;
alter table public.trip_cheers enable row level security;
alter table public.trip_bugs   enable row level security;

-- 쓰기는 여행 암호, 읽기는 관리자 암호
drop policy if exists visits_insert on public.trip_visits;
drop policy if exists visits_admin  on public.trip_visits;
create policy visits_insert on public.trip_visits for insert to anon with check (public.trip_key_ok());
create policy visits_admin  on public.trip_visits for select to anon using (public.admin_ok());

drop policy if exists audit_admin on public.trip_audit;
create policy audit_admin on public.trip_audit for select to anon using (public.admin_ok());

drop policy if exists cheers_admin on public.trip_cheers;
create policy cheers_admin on public.trip_cheers for select to anon using (public.admin_ok());

drop policy if exists bugs_insert on public.trip_bugs;
drop policy if exists bugs_admin  on public.trip_bugs;
create policy bugs_insert on public.trip_bugs for insert to anon with check (public.trip_key_ok());
create policy bugs_admin  on public.trip_bugs for all    to anon using (public.admin_ok()) with check (public.admin_ok());

grant insert, select on public.trip_visits to anon;
grant select on public.trip_audit, public.trip_cheers to anon;
grant select, insert, update, delete on public.trip_bugs to anon;

-- ─────────────────────────────────────────────────────────────
-- 수정 내역 — trip_items 가 바뀔 때마다 한 줄
-- ─────────────────────────────────────────────────────────────
create or replace function public.trip_audit_fn() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    insert into trip_audit (action, item_id, kind, title, before)
    values ('delete', old.id, old.kind, old.title, to_jsonb(old));
    return old;
  elsif tg_op = 'UPDATE' then
    insert into trip_audit (action, item_id, kind, title, before, after)
    values ('update', new.id, new.kind, new.title, to_jsonb(old), to_jsonb(new));
    return new;
  else
    insert into trip_audit (action, item_id, kind, title, after)
    values ('insert', new.id, new.kind, new.title, to_jsonb(new));
    return new;
  end if;
end $$;

drop trigger if exists trip_items_audit on public.trip_items;
create trigger trip_items_audit after insert or update or delete on public.trip_items
  for each row execute function public.trip_audit_fn();

-- ─────────────────────────────────────────────────────────────
-- 응원 — 전체 횟수는 모두가 같이 보는 하나의 숫자
-- ─────────────────────────────────────────────────────────────
create or replace function public.cheer_count() returns bigint
language sql stable security definer set search_path = public as $$
  select case when public.trip_key_ok() or public.admin_ok() then (select count(*) from trip_cheers) end
$$;

create or replace function public.cheer() returns bigint
language plpgsql security definer set search_path = public as $$
begin
  if not public.trip_key_ok() then return null; end if;
  insert into trip_cheers default values;
  return (select count(*) from trip_cheers);
end $$;

grant execute on function public.cheer_count(), public.cheer() to anon;

notify pgrst, 'reload schema';
