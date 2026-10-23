-- 거제 여행 페이지용 표 — Supabase 대시보드 > SQL Editor 에서 한 번 실행한다.
-- 실행 전에 아래 'CHANGE_ME' 를 같이 가는 사람끼리 쓸 여행 암호로 바꾼다.
-- (이 파일은 퍼블릭 저장소에 있으므로, 바꾼 암호를 커밋하지 않는다)

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

-- 여행 암호 검사 — 페이지가 x-trip-key 헤더로 보낸 값과 비교한다
create or replace function public.trip_key_ok() returns boolean
language sql stable as $$
  select coalesce(current_setting('request.headers', true)::json ->> 'x-trip-key', '') = 'CHANGE_ME'
$$;
grant execute on function public.trip_key_ok() to anon;

-- RLS — 암호가 맞을 때만 읽기 · 쓰기
alter table public.trip_items enable row level security;

drop policy if exists trip_items_pass on public.trip_items;
create policy trip_items_pass on public.trip_items
  for all to anon
  using (public.trip_key_ok())
  with check (public.trip_key_ok());

grant select, insert, update, delete on public.trip_items to anon;

-- 암호를 바꿀 때는 위 함수만 새 암호로 다시 실행한다(create or replace).
