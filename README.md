# 거제 여행

일정 · 가볼 곳 · 준비물을 같이 고치는 한 장짜리 페이지(폰 우선, 홈 화면에 추가 가능). GitHub Pages + Supabase.

## 연결

1. Supabase 프로젝트를 만들고 `supabase/schema.sql` 의 `CHANGE_ME` 를 여행 암호로 바꿔 SQL Editor 에서 실행한다.
2. `index.html` 의 `CONFIG` 에 Project URL 과 publishable key 를 넣는다(Project Settings > API Keys). secret 키는 넣지 않는다.
3. 페이지를 열면 여행 암호를 묻는다. 암호가 맞을 때만 읽고 쓸 수 있다(RLS).

`CONFIG` 를 비워 두면 데모 모드 — 그 브라우저에만 저장된다.
