-- ============================================================
-- שורש v1.1 — צד ההיצע ("יש לי מה לתת") + מיגון נגד טרולים
-- החלטות: אישור ידני לכל תרומה (1א) · טלפון הנותן נחשף רק
-- לבעל חווה מאומתת שמשריין (2א) · מתג בפיד (3א) · מיגון (1)
-- הסקריפט עמיד להרצה חוזרת (idempotent).
-- ============================================================

-- ---------- טיפוס ----------
do $$ begin
  create type public.donation_status as enum ('available','claimed','delivered');
exception when duplicate_object then null; end $$;

-- ---------- טבלת תרומות ----------
create table if not exists public.donations (
  id           uuid primary key default gen_random_uuid(),
  type         public.need_type not null,
  title        text not null,
  description  text not null default '',
  region       text not null,
  giver_name   text not null,
  giver_phone  text not null,          -- נחשף רק דרך claim_donation()
  approved     boolean not null default false,  -- אישור ידני של אדמין
  status       public.donation_status not null default 'available',
  claimed_by   uuid references public.farms(id) on delete set null,
  created_at   timestamptz not null default now(),
  delivered_at timestamptz
);

create index if not exists donations_feed_idx
  on public.donations (approved, status, created_at desc);

alter table public.donations enable row level security;

drop policy if exists donations_admin_all on public.donations;
create policy donations_admin_all on public.donations
  for all using (public.is_admin()) with check (public.is_admin());

-- ---------- מיגון: טלפונים חסומים ----------
create table if not exists public.blocked_phones (
  phone      text primary key,
  note       text,
  created_at timestamptz not null default now()
);

alter table public.blocked_phones enable row level security;

drop policy if exists blocked_admin_all on public.blocked_phones;
create policy blocked_admin_all on public.blocked_phones
  for all using (public.is_admin()) with check (public.is_admin());

create or replace function public.norm_phone(p text)
returns text language sql immutable
as $$ select replace(coalesce(p,''), '-', '') $$;

create or replace function public.is_blocked(p text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.blocked_phones b
                 where public.norm_phone(b.phone) = public.norm_phone(p));
$$;

-- ---------- Views ----------
create or replace view public.feed_donations as
  select d.id, d.type, d.title, d.description, d.region, d.status, d.created_at,
         f.name as claimed_by_name
  from public.donations d
  left join public.farms f on f.id = d.claimed_by
  where d.approved and d.status in ('available','claimed')
  order by d.created_at desc;

create or replace view public.success_donations as
  select d.id, d.type, d.title, d.delivered_at, f.name as farm_name, f.region
  from public.donations d
  join public.farms f on f.id = d.claimed_by
  where d.status = 'delivered'
  order by d.delivered_at desc;

grant select on public.feed_donations, public.success_donations to anon, authenticated;

-- ---------- הצעת עזרה (החלפה: + חסימה, כפילות, הצפה) ----------
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
  if length(trim(coalesce(p_helper_name, ''))) < 2 then
    raise exception 'חסר שם';
  end if;
  if p_helper_phone !~ '^0\d{1,2}-?\d{7}$' then
    raise exception 'מספר טלפון לא תקין';
  end if;
  -- טלפון חסום — שגיאה גנרית, בלי לרמוז על חסימה
  if public.is_blocked(p_helper_phone) then
    raise exception 'השליחה נכשלה';
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

  insert into public.offers (need_id, helper_name, helper_phone, note)
  values (p_need_id, trim(p_helper_name), p_helper_phone, nullif(trim(p_note), ''));

  update public.needs set status = 'committed'
  where id = p_need_id and status = 'open';

  return query select v_farm.name, v_farm.contact_phone;
end;
$$;

-- ---------- פרסום תרומה ----------
create or replace function public.submit_donation(
  p_type public.need_type, p_title text, p_description text,
  p_region text, p_giver_name text, p_giver_phone text
) returns void
language plpgsql security definer set search_path = public
as $$
begin
  if length(trim(coalesce(p_title,''))) < 3 then raise exception 'חסרה כותרת'; end if;
  if length(trim(coalesce(p_giver_name,''))) < 2 then raise exception 'חסר שם'; end if;
  if p_giver_phone !~ '^0\d{1,2}-?\d{7}$' then raise exception 'מספר טלפון לא תקין'; end if;
  if public.is_blocked(p_giver_phone) then raise exception 'השליחה נכשלה'; end if;
  -- הצפת תור האישורים: עד 2 תרומות ממתינות לאותו טלפון
  if (select count(*) from public.donations d
      where public.norm_phone(d.giver_phone) = public.norm_phone(p_giver_phone)
        and not d.approved) >= 2 then
    raise exception 'יש כבר תרומות ממתינות לאישור מהמספר הזה';
  end if;
  insert into public.donations (type, title, description, region, giver_name, giver_phone)
  values (p_type, trim(p_title), trim(coalesce(p_description,'')), p_region,
          trim(p_giver_name), p_giver_phone);
end;
$$;
grant execute on function public.submit_donation(public.need_type, text, text, text, text, text) to anon, authenticated;

-- ---------- שיריון תרומה — רק בעל חווה מאומתת ----------
create or replace function public.claim_donation(p_donation_id uuid)
returns table (giver_name text, giver_phone text)
language plpgsql security definer set search_path = public
as $$
declare
  v_farm public.farms%rowtype;
  v_d    public.donations%rowtype;
begin
  select * into v_farm from public.farms
   where owner_id = auth.uid() and verified limit 1;
  if not found then raise exception 'רק חווה מאומתת יכולה לשריין'; end if;

  select * into v_d from public.donations where id = p_donation_id and approved;
  if not found or v_d.status = 'delivered' then raise exception 'התרומה לא זמינה'; end if;

  update public.donations set status = 'claimed', claimed_by = v_farm.id
   where id = p_donation_id and status = 'available';

  select * into v_d from public.donations where id = p_donation_id;
  if v_d.claimed_by is distinct from v_farm.id then
    raise exception 'התרומה כבר שוריינה על ידי חווה אחרת';
  end if;

  return query select v_d.giver_name, v_d.giver_phone;
end;
$$;
grant execute on function public.claim_donation(uuid) to authenticated;

-- ---------- סימון "נמסר" — רק החווה המשויכת ----------
create or replace function public.donation_delivered(p_donation_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.donations d set status = 'delivered', delivered_at = now()
  where d.id = p_donation_id and d.status = 'claimed'
    and exists (select 1 from public.farms f
                where f.id = d.claimed_by and f.owner_id = auth.uid());
  if not found then raise exception 'לא נמצא שיוך מתאים'; end if;
end;
$$;
grant execute on function public.donation_delivered(uuid) to authenticated;
