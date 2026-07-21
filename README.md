# shoresh-build 🌱

תיקיית בנייה ל-Claude Code. **המטרה: להעלות משהו אמיתי לאוויר.**

## התחלה מהירה

```
פתח את התיקייה ב-Claude Code והקלד:

"קרא את CLAUDE.md ואז את docs/BUILD-PLAN.md. נתחיל משלב 0."
```

## מבנה

```
shoresh-build/
├── CLAUDE.md              ← הוראות הבנייה. נקודת הכניסה.
├── docs/
│   ├── BUILD-PLAN.md      ← התוכנית בשלבים
│   ├── DATA-MODEL.md      ← ישויות, שדות, הרשאות
│   ├── ACCEPTANCE.md      ← איך יודעים שסיימנו
│   ├── DECISIONS.md       ← החלטות סגורות — לא לפתוח מחדש
│   ├── PARKED.md          ← רעיונות שנפסלו — לא להציע
│   ├── BRIEF.md           ← הקשר, מספרים, רגולציה
│   └── IDEAS.md           ← ריק. לרעיונות שיעלו תוך כדי.
├── db/schema.sql          ← סכמת Supabase — מריצים כמו שהיא
├── design/
│   ├── mockup.html        ← ⭐ הרפרנס החזותי. פתח בדפדפן.
│   ├── TOKENS.md          ← צבעים, פונטים, מידות
│   └── hazani-logo/icon.png
├── public/config.json     ← חסויות + קרדיט (נטען מהשרת)
└── reference/             ← אפיון, פנייה לעמותה, תקציב
```

## מה צריך לפני שמתחילים

| # | מה | איפה |
|---|---|---|
| 1 | פרויקט Supabase | [supabase.com](https://supabase.com) — חינם |
| 2 | Project URL + anon key | Settings → API |
| 3 | חשבון Netlify | [netlify.com](https://netlify.com) — חינם |

## סדר הרצה

1. **Supabase:** SQL Editor → הדבק את `db/schema.sql` → Run
2. **Auth:** הפעל Email / Magic Link
3. **env:** צור `public/env.js` עם ה-URL וה-anon key
4. **בנה:** שלב 1 מ-`BUILD-PLAN.md`
5. **העלה:** גרור את תיקיית הפלט ל-[Netlify Drop](https://app.netlify.com/drop)

## מה ריאלי היום

- ✅ **שלבים 0–1** (2–4 שעות) → אתר חי שמושך צרכים אמיתיים מהשרת
- ✅ אולי גם **שלב 2** (הצעת עזרה)
- ⏳ **שלב 3** (הרשמת מתיישבים) — ריאלי מחר

**אל תחכה לשלב 3 כדי לשלוח לאנשים.** אתר קריאה-בלבד עם 5 חוות אמיתיות כבר מייצר משוב אמיתי.

---

## הערות קליטה (2026-07-21)

החבילה הגיעה עם שמות קבצים מוחלפים — הכל סודר מחדש לפי התוכן. חסרים מהמקור (לא הגיעו כלל):

- `db/schema.sql` המקורי → **נכתב מחדש** מ-`docs/DATA-MODEL.md`, כולל RLS ופונקציית `submit_offer` שחושפת טלפון רק אחרי הצעה.
- `shoresh-pitch.html` (דף הפנייה לעמותה) — לא הגיע. נמצא רק בשיחת המקור.
- `whatsapp-message.md` (הודעת ההפצה) — לא הגיע.

`public/` הוא התיקייה שמעלים ל-Netlify (כולל `env.js` שנוצר מקומית מ-`env.js.example`).

## פריסה — GitHub Pages

הריפו מחובר ל-GitHub Pages: כל push ל-`main` מפרסם את תיקיית `public/` אוטומטית ל:
**https://sahar6686.github.io/shoresh/**

- `public/env.js` נכנס ל-git בכוונה (מפתח anon הוא ציבורי). service_role — לעולם לא.
- אחרי חיבור Supabase יש להוסיף את כתובת האתר ב-Supabase → Authentication → URL Configuration (Site URL + Redirect URLs), אחרת קישורי הכניסה במייל לא יחזרו לאתר.
- Netlify Drop נשאר אפשרות גיבוי — גוררים את `public/`.
