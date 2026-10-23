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

-- ─────────────────────────────────────────────────────────────
-- 암호 — 설정 표에 두고 관리자 화면에서 바꾼다.
--   trip_pass          : 여행 암호(같이 가는 사람에게 알려 주는 값이라 원문)
--   admin_pass_sha256  : 관리자 암호의 SHA-256 — 원문은 남기지 않는다
-- 표는 RLS 정책이 없어 anon 이 직접 읽지 못하고, 아래 security definer 함수만 본다.
-- 처음 한 번만 자리표시 값으로 넣고(on conflict do nothing), 이후 바꾼 값은 다시 실행해도 유지된다.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.trip_settings (
  key         text primary key,
  value       text not null,
  updated_at  timestamptz not null default now()
);
alter table public.trip_settings enable row level security;
revoke all on public.trip_settings from anon, authenticated;

insert into public.trip_settings (key, value) values
  ('trip_pass', 'CHANGE_ME'),
  ('admin_pass_sha256', encode(sha256(convert_to('CHANGE_ME_ADMIN', 'UTF8')), 'hex'))
on conflict (key) do nothing;

-- 여행 암호 · 관리자 암호 검사
create or replace function public.trip_key_ok() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from trip_settings
                 where key = 'trip_pass' and value = coalesce(public.req_header('x-trip-key'), ''))
$$;

create or replace function public.admin_ok() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from trip_settings
                 where key = 'admin_pass_sha256'
                   and value = encode(sha256(convert_to(coalesce(public.req_header('x-admin-key'), ''), 'UTF8')), 'hex'))
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
-- 끼니 · 카페 슬롯 — 슬롯마다 후보(trip_options)를 두고 하나를 고른다(chosen_id)
-- ─────────────────────────────────────────────────────────────
create table if not exists public.trip_slots (
  id          bigint generated always as identity primary key,
  day         date not null,
  time        time,
  kind        text not null check (kind in ('meal', 'cafe', 'bbq', 'spot')),
  title       text not null,                 -- 점심 · 카페 · 저녁 바베큐 …
  fixed       boolean not null default false, -- 고정 슬롯(후보 없이 정해짐)
  memo        text,
  chosen_id   bigint,
  created_at  timestamptz not null default now()
);

create table if not exists public.trip_options (
  id          bigint generated always as identity primary key,
  slot_id     bigint not null references public.trip_slots (id) on delete cascade,
  kind        text not null default 'option',
  title       text not null,
  area        text,                          -- 장승포 · 외포항 …
  menu        text,                          -- 대표 메뉴 한 줄
  memo        text,
  url         text,
  badge       text,                          -- 블루리본 · 주신 곳 · 제철 …
  sort        integer not null default 0,
  created_at  timestamptz not null default now()
);

alter table public.trip_slots   enable row level security;
alter table public.trip_options enable row level security;
drop policy if exists trip_slots_pass    on public.trip_slots;
drop policy if exists trip_slots_admin   on public.trip_slots;
drop policy if exists trip_options_pass  on public.trip_options;
drop policy if exists trip_options_admin on public.trip_options;
create policy trip_slots_pass    on public.trip_slots   for all to anon using (public.trip_key_ok()) with check (public.trip_key_ok());
create policy trip_slots_admin   on public.trip_slots   for select to anon using (public.admin_ok());
create policy trip_options_pass  on public.trip_options for all to anon using (public.trip_key_ok()) with check (public.trip_key_ok());
create policy trip_options_admin on public.trip_options for select to anon using (public.admin_ok());
grant select, insert, update, delete on public.trip_slots, public.trip_options to anon;

-- ─────────────────────────────────────────────────────────────
-- 장소 DB — 주신 곳 · 웹 검색 · 앱에서 추가한 후보를 모두 모은다(관리자 화면 «장소»)
--   map_url 은 반드시 있다. source_url 은 찾은 출처(블로그 · 기사 · 유튜브 …)
-- ─────────────────────────────────────────────────────────────
create table if not exists public.trip_places (
  id          bigint generated always as identity primary key,
  name        text not null unique,
  category    text not null check (category in ('맛집', '카페', '구경')),
  area        text,
  menu        text,
  memo        text,
  badge       text,
  source      text not null default '웹 검색',      -- 주신 곳 · 웹 검색 · 앱에서 추가 · 관리자 추가
  source_url  text,
  map_url     text not null,
  created_at  timestamptz not null default now()
);

alter table public.trip_places enable row level security;
drop policy if exists trip_places_admin on public.trip_places;
create policy trip_places_admin on public.trip_places for all to anon using (public.admin_ok()) with check (public.admin_ok());
grant select, insert, update, delete on public.trip_places to anon;

-- 앱에서 슬롯 후보를 추가하면 장소 DB 에도 넣는다(이미 있으면 그대로)
create or replace function public.trip_places_from_option() returns trigger
language plpgsql security definer set search_path = public as $$
declare k text;
begin
  select kind into k from trip_slots where id = new.slot_id;
  insert into trip_places (name, category, area, menu, memo, badge, source, source_url, map_url)
  values (new.title,
          case k when 'cafe' then '카페' when 'spot' then '구경' else '맛집' end,
          new.area, new.menu, new.memo, new.badge, '앱에서 추가', new.url,
          'https://map.naver.com/p/search/' || replace('거제 ' || new.title, ' ', '%20'))
  on conflict (name) do nothing;
  return new;
end $$;

drop trigger if exists trip_options_to_places on public.trip_options;
create trigger trip_options_to_places after insert on public.trip_options
  for each row execute function public.trip_places_from_option();

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

-- 슬롯 고르기 · 후보 추가/삭제도 같은 수정 내역에 남긴다
drop trigger if exists trip_slots_audit on public.trip_slots;
create trigger trip_slots_audit after insert or update or delete on public.trip_slots
  for each row execute function public.trip_audit_fn();
drop trigger if exists trip_options_audit on public.trip_options;
create trigger trip_options_audit after insert or update or delete on public.trip_options
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

-- ─────────────────────────────────────────────────────────────
-- 관리자 — 암호 보기 · 바꾸기 (관리자 암호가 맞을 때만)
-- ─────────────────────────────────────────────────────────────
create or replace function public.admin_settings() returns json
language sql stable security definer set search_path = public as $$
  select case when public.admin_ok() then json_build_object(
    'trip_pass',     (select value      from trip_settings where key = 'trip_pass'),
    'trip_updated',  (select updated_at from trip_settings where key = 'trip_pass'),
    'admin_updated', (select updated_at from trip_settings where key = 'admin_pass_sha256')) end
$$;

create or replace function public.admin_set_pass(kind text, new_pass text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public.admin_ok() then raise exception '관리자 암호가 맞지 않아요'; end if;
  new_pass := btrim(coalesce(new_pass, ''));
  if length(new_pass) < 4 then raise exception '암호는 4글자 이상이어야 해요'; end if;

  if kind = 'trip' then
    update trip_settings set value = new_pass, updated_at = now() where key = 'trip_pass';
  elsif kind = 'admin' then
    update trip_settings set value = encode(sha256(convert_to(new_pass, 'UTF8')), 'hex'), updated_at = now()
     where key = 'admin_pass_sha256';
  else
    raise exception '알 수 없는 암호 종류: %', kind;
  end if;

  -- 수정 내역에 남긴다(값은 남기지 않는다)
  insert into trip_audit (action, kind, title, name)
  values ('update', 'setting', case kind when 'trip' then '여행 암호 변경' else '관리자 암호 변경' end, '관리자');
  return 'ok';
end $$;

grant execute on function public.admin_settings(), public.admin_set_pass(text, text) to anon;

notify pgrst, 'reload schema';
