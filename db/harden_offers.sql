-- ============================================================
-- שורש — הקשחת submit_offer נגד קציר טלפונים
--
-- הבעיה שנמצאה בביקורת: המפתח הציבורי גלוי בקוד המקור (מתוכנן),
-- מזהי הצרכים מתפרסמים ב-feed_needs, ו-submit_offer מוענקת ל-anon
-- ומחזירה את טלפון החווה. לכן סקריפט יכול לקרוא את הפיד ולקרוא
-- לפונקציה פעם אחת לכל צורך עם שם ומספר מומצאים — ולאסוף את
-- הטלפונים של כל החוות המאומתות.
--
-- המגבלות שהיו קיימות הן כולן *לכל צורך* (3 ב-10 דקות, בלי כפילות
-- טלפון) — ולכן לא עוצרות תוקף שפונה לצורך אחר בכל קריאה.
--
-- מה שנוסף כאן: שתי תקרות *חוצות-צרכים* —
--   1. לפי טלפון העוזר: עד 5 הצעות ב-24 שעות בכל המערכת.
--   2. לפי כתובת IP: עד 10 הצעות ב-24 שעות.
--
-- הערה כנה: זה מייקר את ההתקפה, לא מבטל אותה. תוקף שמחליף גם
-- מספר וגם IP בכל פנייה עדיין יכול לאסוף. חשיפת הטלפון לעוזר
-- לא-רשום היא החלטת מוצר נעולה (DECISIONS.md — "קשר ישיר"),
-- ולכן אי אפשר לסגור את זה לגמרי בלי לשבור את הלולאה.
-- אם יתגלה ניצול בפועל — הצעד הבא הוא CAPTCHA על הטופס.
--
-- פרטיות: נשמרת כתובת IP לצורך מניעת שימוש לרעה בלבד. היא לא
-- נחשפת לאיש (RLS: אדמין בלבד), ורצוי לנקות רשומות ישנות.
-- ============================================================

alter table public.offers    add column if not exists ip text;
alter table public.donations add column if not exists ip text;

create index if not exists offers_phone_time_idx  on public.offers (helper_phone, created_at desc);
create index if not exists offers_ip_time_idx     on public.offers (ip, created_at desc);
create index if not exists donations_ip_time_idx  on public.donations (ip, created_at desc);

create or replace function public.submit_offer(
  p_need_id      uuid,
  p_helper_name  text,
  p_helper_phone text,
  p_note         text default null
)
returns table (farm_name text, contact_phone text)
language plpgsql security definer set search_path = public
as $$
declare
  v_farm public.farms%rowtype;
  v_need public.needs%rowtype;
  v_ip   text;
begin
  if length(trim(coalesce(p_helper_name, ''))) < 2 then
    raise exception 'חסר שם';
  end if;
  if p_helper_phone !~ '^0\d{1,2}-?\d{7}$' then
    raise exception 'מספר טלפון לא תקין';
  end if;
  if public.is_blocked(p_helper_phone) then
    raise exception 'השליחה נכשלה';
  end if;

  -- כתובת ה-IP כפי שהיא מגיעה מ-PostgREST (הכותרת הראשונה בשרשרת)
  v_ip := split_part(
            coalesce(current_setting('request.headers', true)::json->>'x-forwarded-for', ''),
            ',', 1);
  v_ip := nullif(trim(v_ip), '');

  -- תקרה חוצת-צרכים לפי טלפון
  if (select count(*) from public.offers o
      where public.norm_phone(o.helper_phone) = public.norm_phone(p_helper_phone)
        and o.created_at > now() - interval '24 hours') >= 5 then
    raise exception 'שלחת הרבה הצעות היום. נסה שוב מחר, או צור קשר איתנו.';
  end if;

  -- תקרה חוצת-צרכים לפי IP
  if v_ip is not null and (select count(*) from public.offers o
      where o.ip = v_ip
        and o.created_at > now() - interval '24 hours') >= 10 then
    raise exception 'יש עומס פניות כרגע — נסה שוב מאוחר יותר.';
  end if;

  -- כפילות: אותו טלפון לאותו צורך
  if exists (select 1 from public.offers o
             where o.need_id = p_need_id
               and public.norm_phone(o.helper_phone) = public.norm_phone(p_helper_phone)) then
    raise exception 'כבר נשלחה הצעה עם הטלפון הזה לצורך הזה';
  end if;

  -- הצפה: עד 3 הצעות לצורך ב-10 דקות
  if (select count(*) from public.offers o
      where o.need_id = p_need_id
        and o.created_at > now() - interval '10 minutes') >= 3 then
    raise exception 'יש עומס פניות כרגע — נסה שוב בעוד כמה דקות';
  end if;

  select * into v_need from public.needs where id = p_need_id;
  if not found or v_need.status = 'delivered' then
    raise exception 'הצורך כבר נסגר או לא קיים';
  end if;

  select * into v_farm from public.farms where id = v_need.farm_id;
  if not v_farm.verified then
    raise exception 'החווה עדיין לא אומתה';
  end if;

  insert into public.offers (need_id, helper_name, helper_phone, note, ip)
  values (p_need_id, trim(p_helper_name), p_helper_phone, nullif(trim(p_note), ''), v_ip);

  update public.needs set status = 'committed'
  where id = p_need_id and status = 'open';

  return query select v_farm.name, v_farm.contact_phone;
end;
$$;

-- אותה תקרה לפי IP גם על פרסום תרומות, שגם הוא פתוח לאנונימיים
create or replace function public.submit_donation(
  p_type public.need_type, p_title text, p_description text,
  p_region text, p_giver_name text, p_giver_phone text
) returns void
language plpgsql security definer set search_path = public
as $$
declare v_ip text;
begin
  if length(trim(coalesce(p_title,''))) < 3 then raise exception 'חסרה כותרת'; end if;
  if length(trim(coalesce(p_giver_name,''))) < 2 then raise exception 'חסר שם'; end if;
  if p_giver_phone !~ '^0\d{1,2}-?\d{7}$' then raise exception 'מספר טלפון לא תקין'; end if;
  if public.is_blocked(p_giver_phone) then raise exception 'השליחה נכשלה'; end if;

  v_ip := nullif(trim(split_part(
            coalesce(current_setting('request.headers', true)::json->>'x-forwarded-for',''), ',', 1)), '');

  if (select count(*) from public.donations d
      where public.norm_phone(d.giver_phone) = public.norm_phone(p_giver_phone)
        and not d.approved) >= 2 then
    raise exception 'יש כבר תרומות ממתינות לאישור מהמספר הזה';
  end if;

  -- תקרת הצפה של תור האישורים: עד 5 תרומות מאותו IP ביממה
  if v_ip is not null and (select count(*) from public.donations d
      where d.ip = v_ip and d.created_at > now() - interval '24 hours') >= 5 then
    raise exception 'יש עומס פניות כרגע — נסה שוב מאוחר יותר.';
  end if;

  insert into public.donations (type, title, description, region, giver_name, giver_phone, ip)
  values (p_type, trim(p_title), trim(coalesce(p_description,'')), p_region,
          trim(p_giver_name), p_giver_phone, v_ip);
end;
$$;
