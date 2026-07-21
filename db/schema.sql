-- ============================================================
-- שורש 🌱 — סכמת Supabase
-- מריצים כמו שהיא ב-SQL Editor (Run פעם אחת על פרויקט נקי).
-- שוחזר מ-docs/DATA-MODEL.md — הקובץ המקורי לא הגיע בחבילה.
--
-- עקרון הפרטיות המרכזי:
--   contact_phone של חווה לא נקרא לעולם ישירות ע"י הציבור.
--   הפיד נקרא דרך views בלי טלפון, והטלפון נחשף רק כערך
--   מוחזר מהפונקציה submit_offer() — אחרי שנשלחה הצעת עזרה.
-- ============================================================

-- ---------- טיפוסים ----------
create type public.need_type   as enum ('object', 'transport', 'time');
create type public.need_status as enum ('open', 'committed', 'delivered');

-- ---------- טבלאות ----------
create table public.farms (
  id             uuid primary key default gen_random_uuid(),
  owner_id       uuid references auth.users(id) on delete set null,
  name           text not null,
  region         text not null,            -- גולן / גליל / נגב / הר
  location_note  text,                     -- תיאור כללי, לא כתובת מדויקת
  emoji          text not null default '🌾',
  contact_phone  text not null,            -- נחשף רק דרך submit_offer()
  verified       boolean not null default false,
  created_at     timestamptz not null default now()
);

create table public.needs (
  id           uuid primary key default gen_random_uuid(),
  farm_id      uuid not null references public.farms(id) on delete cascade,
  type         public.need_type not null,
  title        text not null,
  description  text not null default '',
  status       public.need_status not null default 'open',
  created_at   timestamptz not null default now(),
  delivered_at timestamptz               -- מתמלא אוטומטית בסימון delivered
);

create table public.offers (
  id           uuid primary key default gen_random_uuid(),
  need_id      uuid not null references public.needs(id) on delete cascade,
  helper_name  text not null,
  helper_phone text not null,
  note         text,
  created_at   timestamptz not null default now()
);

create table public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

create index needs_feed_idx    on public.needs (status, created_at desc);
create index needs_farm_idx    on public.needs (farm_id);
create index offers_need_idx   on public.offers (need_id);

-- ---------- עזר: האם המשתמש הנוכחי אדמין ----------
create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- ---------- טריגרים ----------

-- חווה חדשה תמיד נוצרת לא-מאומתת, ורק אדמין רשאי לשנות את verified
create or replace function public.enforce_farm_verification()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if not public.is_admin() then
      new.verified := false;
    end if;
  elsif tg_op = 'UPDATE' then
    if new.verified is distinct from old.verified and not public.is_admin() then
      raise exception 'רק אדמין רשאי לשנות סטטוס אימות';
    end if;
  end if;
  return new;
end;
$$;

create trigger farms_verification
  before insert or update on public.farms
  for each row execute function public.enforce_farm_verification();

-- delivered_at מתמלא אוטומטית במעבר ל-delivered
create or replace function public.stamp_delivered()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'delivered' and old.status is distinct from 'delivered' then
    new.delivered_at := now();
  end if;
  return new;
end;
$$;

create trigger needs_stamp_delivered
  before update on public.needs
  for each row execute function public.stamp_delivered();

-- ---------- RLS ----------
alter table public.farms  enable row level security;
alter table public.needs  enable row level security;
alter table public.offers enable row level security;
alter table public.admins enable row level security;

-- farms: אין מדיניות select לציבור בכוונה — קריאה ציבורית רק דרך ה-views למטה
create policy farms_owner_select on public.farms
  for select using (owner_id = auth.uid() or public.is_admin());

create policy farms_insert on public.farms
  for insert to authenticated with check (owner_id = auth.uid());

create policy farms_owner_update on public.farms
  for update using (owner_id = auth.uid() or public.is_admin());

create policy farms_admin_delete on public.farms
  for delete using (public.is_admin());

-- needs: בעל החווה מנהל; אדמין רואה ומוחק הכל
create policy needs_owner_select on public.needs
  for select using (
    exists (select 1 from public.farms f
            where f.id = farm_id and (f.owner_id = auth.uid() or public.is_admin()))
  );

create policy needs_owner_write on public.needs
  for insert to authenticated with check (
    exists (select 1 from public.farms f
            where f.id = farm_id and f.owner_id = auth.uid())
  );

create policy needs_owner_update on public.needs
  for update using (
    exists (select 1 from public.farms f
            where f.id = farm_id and (f.owner_id = auth.uid() or public.is_admin()))
  );

create policy needs_admin_delete on public.needs
  for delete using (public.is_admin());

-- offers: יצירה רק דרך submit_offer() (security definer). קריאה — בעל החווה בלבד.
create policy offers_owner_select on public.offers
  for select using (
    exists (select 1 from public.needs n
            join public.farms f on f.id = n.farm_id
            where n.id = need_id and (f.owner_id = auth.uid() or public.is_admin()))
  );

-- admins: רק אדמין רואה את הרשימה. הוספה — ידנית דרך ה-Dashboard בלבד.
create policy admins_select on public.admins
  for select using (public.is_admin());

-- ---------- Views ציבוריים (security definer — עוקפים RLS, בלי טלפון) ----------

-- הפיד: צרכים פתוחים/מחויבים של חוות מאומתות בלבד
create view public.feed_needs as
  select n.id, n.type, n.title, n.description, n.status, n.created_at,
         f.name as farm_name, f.region, f.location_note, f.emoji
  from public.needs n
  join public.farms f on f.id = n.farm_id
  where f.verified and n.status in ('open', 'committed')
  order by n.created_at desc;

-- פיד ההצלחות: צרכים שנמסרו
create view public.success_feed as
  select n.id, n.type, n.title, n.delivered_at,
         f.name as farm_name, f.region, f.emoji
  from public.needs n
  join public.farms f on f.id = n.farm_id
  where f.verified and n.status = 'delivered'
  order by n.delivered_at desc;

grant select on public.feed_needs, public.success_feed to anon, authenticated;

-- ---------- הצעת עזרה (ללא הרשמה) ----------
-- מכניסה הצעה, מעבירה צורך פתוח ל-committed,
-- ומחזירה את פרטי הקשר של החווה — רק כאן הטלפון נחשף.
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
begin
  -- ולידציה בסיסית בצד השרת
  if length(trim(coalesce(p_helper_name, ''))) < 2 then
    raise exception 'חסר שם';
  end if;
  if p_helper_phone !~ '^0\d{1,2}-?\d{7}$' then
    raise exception 'מספר טלפון לא תקין';
  end if;

  select * into v_need from public.needs where id = p_need_id;
  if not found or v_need.status = 'delivered' then
    raise exception 'הצורך כבר נסגר או לא קיים';
  end if;

  select * into v_farm from public.farms where id = v_need.farm_id;
  if not v_farm.verified then
    raise exception 'החווה עדיין לא אומתה';
  end if;

  insert into public.offers (need_id, helper_name, helper_phone, note)
  values (p_need_id, trim(p_helper_name), p_helper_phone, nullif(trim(p_note), ''));

  -- open → committed אוטומטית בהצעה הראשונה
  update public.needs set status = 'committed'
  where id = p_need_id and status = 'open';

  return query select v_farm.name, v_farm.contact_phone;
end;
$$;

grant execute on function public.submit_offer(uuid, text, text, text) to anon, authenticated;
