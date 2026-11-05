# outage-app

Telegram Mini App «📅 Графік» для бота відключень світла (сімейні домашні додатки).

- `index.html` — вся сторінка (без збірки). Публікується через GitHub Pages з гілки `main`: https://hlushkova-9e.github.io/outage-app/ (будинкова версія: `?house=1`).
- `apple-touch-icon.png` — іконка 180×180 для «На початковий екран» в iOS (назва «Графік 9Є»).
- `edge/outage-app/index.ts` — Supabase Edge Function v5 (Verify JWT вимкнено; дозволені адреси hlushkova-9e.github.io і abohdanovskyi.github.io; передає зсув тижня `week`): передає initData у SQL-функцію `outage_app_data`.
- `sql/32-supabase-outage-app.sql` — таблиця періодів екстрених, перевірка підпису Telegram, дані для сторінки, кнопка в боті.
- `sql/33`–`sql/35` — будинковий бот, «зелені» години, публічна версія `?house=1`.
- `sql/36-supabase-outage-newurl.sql` — нова адреса сторінки (app_url і кнопка «🌐 У браузері»).
- `sql/37-supabase-outage-weeks.sql` — перемикач тижнів ◀ ▶ (зсув −8…+1; дані від 01.11.2026, розетки від 03.11.2026).

У репозиторії публічний лише код: адрес, ключів і даних тут немає. Дані сторінка бере з Supabase після перевірки підпису Telegram і бачить лише власні підписки.
Робота ведеться в гілці `dev`; у `main` зливаємо лише після слова «публікую».
