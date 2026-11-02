// 일정표 · 안내 페이지 공통 — 여행 앱에서 정한 일정을 DB에서 바로 읽는다.
// DB 함수 public_timeline()(supabase/schema.sql)은 고른 곳만 돌려주므로 암호 없이 읽는다.
(function () {
  const API = {
    url: "https://yijkbqygdiscaunzhrvy.supabase.co",
    key: "sb_publishable_kymzTMwNQpia-oz05r63Qg_4AaR1NJo",
  };

  // 칸 종류별 아이콘 · 색
  const SLOT = {
    meal: ["🍽️", "#ff6b5a"], cafe: ["☕", "#b07848"], bbq: ["🔥", "#ff7a1a"],
    spot: ["📸", "#0ea5a4"], shop: ["🛒", "#7c5cff"],
  };

  // 예약 · 안내 페이지 — 장소 이름으로 일정 행에 붙인다(경로는 사이트 루트 기준)
  const ROOT = (function () {
    const i = location.pathname.indexOf("/geoje-trip/");
    return i >= 0 ? location.pathname.slice(0, i + "/geoje-trip/".length) : "../";
  })();
  const RESV = {
    "박정현게장백반": {
      when: "11/6(금) 14:00", people: "4명", status: "네이버 예약 · 확인중", no: "1395967040",
      tel: "010-8697-9487", img: ROOT + "img/resv/bakjh_1106.jpg",
      note: "문화예술회관 안 홈포레스트호텔 주차장 · 주차권 받기",
    },
  };
  const LINKS = {
    "어부장터X포트빌리지 통영": [ROOT + "places/festival.html", "🎉 축제 안내 ›"],
    "통영케이블카": [ROOT + "places/cablecar.html", "🚡 케이블카 안내 ›"],
    "스카이라인 루지 통영": [ROOT + "places/luge.html", "🛷 루지 안내 ›"],
    "바람의 언덕": [ROOT + "places/windhill.html", "🌬️ 바람의 언덕 안내 ›"],
  };

  // DB 함수 호출 — 실패하면 예외
  async function load() {
    const r = await fetch(API.url + "/rest/v1/rpc/public_timeline", {
      method: "POST", cache: "no-store",
      headers: { apikey: API.key, "Content-Type": "application/json" },
      body: "{}",
    });
    if (!r.ok) throw new Error("public_timeline " + r.status);
    return r.json();
  }

  // { items, slots } → 시간순 일정 행 목록(고르지 않은 칸은 뺀다)
  function rows(d) {
    const out = [];
    for (const i of d.items || []) {
      const t = i.title || "", sp = t.indexOf(" ");
      const ic = sp > 0 ? t.slice(0, sp) : "📌", rest = sp > 0 ? t.slice(sp + 1) : t;
      out.push({ day: i.day, time: (i.time || "").slice(0, 5), ic, tag: ic.includes("🚄") ? "이동" : "숙소",
        color: "#0e7c86", name: rest, sub: "", url: i.url, memo: i.memo || "" });
    }
    for (const s of d.slots || []) {
      let [ic, color] = SLOT[s.kind] || SLOT.meal;
      if ((s.title || "").includes("아침")) ic = "🍳";
      const o = s.chosen;
      if (!o && !s.fixed) continue;
      out.push(o
        ? { day: s.day, time: (s.time || "").slice(0, 5), ic, tag: s.title, color, name: o.title,
            sub: [o.area, o.menu].filter(Boolean).join(" · "), url: o.url, memo: s.memo || "" }
        : { day: s.day, time: (s.time || "").slice(0, 5), ic, tag: "저녁", color, name: s.title,
            sub: "", url: null, memo: s.memo || "" });
    }
    out.sort((a, b) => (a.day + a.time).localeCompare(b.day + b.time));
    for (const r of out) {
      r.resv = RESV[r.name] || null;
      r.link = LINKS[r.name] || null;
      r.memoLines = r.memo.split("\n").map((x) => x.trim()).filter((x) => x && !x.includes("예약 완료"));
    }
    return out;
  }

  const WD = "일월화수목금토";
  function dayLabel(day) {
    const t = new Date(day + "T00:00:00");
    return `${t.getMonth() + 1}/${t.getDate()} (${WD[t.getDay()]})`;
  }

  window.TripLive = { load, rows, dayLabel, RESV, LINKS };

  // 안내 페이지 ‘우리 일정’ — <ul data-live-day="YYYY-MM-DD" data-live-match="이름 일부"> 를 DB 내용으로 바꾼다.
  // 못 읽으면 페이지에 적어 둔 목록을 그대로 둔다
  const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  function fillDays() {
    const els = document.querySelectorAll("[data-live-day]");
    if (!els.length) return;
    load().then((d) => {
      const all = rows(d);
      els.forEach((el) => {
        const list = all.filter((r) => r.day === el.dataset.liveDay);
        if (!list.length) return;
        const m = el.dataset.liveMatch || "";
        el.innerHTML = list.map((r) => {
          const hot = m && r.name.includes(m);
          return `<li><time${hot ? ' class="now"' : ""}>${r.time}</time><span>${hot ? "<b>" : ""}${r.ic} ${esc(r.name)}${hot ? "</b>" : ""}</span></li>`;
        }).join("");
      });
    }).catch(() => {});
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", fillDays);
  else fillDays();
})();
