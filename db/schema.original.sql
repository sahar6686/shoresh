-- שורש 🌱 — סכמת Supabase
-- הרצה: Supabase Dashboard → SQL Editor → הדבק → Run
-- ניתן להריץ שוב בבטחה (idempotent)

-- ============ טיפוסים ============
do $$ begin
  create type need_type as enum ('object','transport','time');
exception when duplicate_object then null; end $$;

do $$ begin
  create type need_status as enum ('open','committed','delivered');
exception when duplicate_object then null; end $$;

-- ============ טבלאות ============
create table if not exists public.farms (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references auth.users(id) on delete cascade,
  name          text not null check (char_length(name) between 2 and 80),
  region        text not null check (region in ('גולן','גליל','נגב','הר')),
  location_note text check (char_length(location_note) <= 120),
  emoji         text default '🌾',
  contact_phone text not null,
  verified      boolean not null default false,
  created_at    timestamptz not null default now()
);

create table if not exists public.needs (
  id           uuid primary key default gen_random_uuid(),
  farm_id      uuid not null references public.farms(id) on delete cascade,
  type         need_type not null,
  title        text not null check (char_length(title) between 3 and 120),
  description  text check (char_length(description) <= 800),
  status       need_status not null default 'open',
  created_at   timestamptz not null default now(),
  delivered_at timestamptz
);

create table if not exists public.offers (
  id           uuid primary key default gen_random_uuid(),
  need_id      uuid not null references public.needs(id) on delete cascade,
  helper_name  text not null check (char_length(helper_name) between 2 and 60),
  helper_phone text not null check (char_length(helper_phone) between 9 and 20),
  note         text check (char_length(note) <= 300),
  created_at   timestamptz not null default now()
);

create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

create index if not exists idx_needs_farm    on public.needs(farm_id);
create index if not exists idx_needs_status  on public.needs(status);
create index if not exists idx_offers_need   on public.offers(need_id);
create index if not exists idx_farms_owner   on public.farms(owner_id);

-- ============ פונקציות עזר ============
create or replace function public.is_admin()
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

create or replace function public.owns_farm(f uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.farms where id = f and owner_id = auth.uid());
$$;

-- כשנוצרת הצעה ראשונה: open -> committed
create or replace function public.bump_status()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.needs set status = 'committed'
   where id = new.need_id and status = 'open';
  return new;
end $$;

drop trigger if exists trg_bump_status on public.offers;
create trigger trg_bump_status after insert on public.offers
  for each row execute function public.bump_status();

-- חותמת זמן בסגירה
create or replace function public.stamp_delivered()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.status = 'delivered' and old.status is distinct from 'delivered' then
    new.delivered_at := now();
  elsif new.status <> 'delivered' then
    new.delivered_at := null;
  end if;
  return new;
end $$;

drop trigger if exists trg_stamp_delivered on public.needs;
create trigger trg_stamp_delivered before update on public.needs
  for each row execute function public.stamp_delivered();

-- ============ RLS ============
alter table public.farms  enable row level security;
alter table public.needs  enable row level security;
alter table public.offers enable row level security;
alter table public.admins enable row level security;

-- farms
drop policy if exists farms_read_public on public.farms;
create policy farms_read_public on public.farms
  for select using (verified = true or owner_id = auth.uid() or public.is_admin());

drop policy if exists farms_insert_own on public.farms;
create policy farms_insert_own on public.farms
  for insert with check (owner_id = auth.uid() and verified = false);

drop policy if exists farms_update_own on public.farms;
create policy farms_update_own on public.farms
  for update using (owner_id = auth.uid() or public.is_admin())
  with check (owner_id = auth.uid() or public.is_admin());

-- needs
drop policy if exists needs_read_public on public.needs;
create policy needs_read_public on public.needs
  for select using (
    exists (select 1 from public.farms f
             where f.id = needs.farm_id
               and (f.verified = true or f.owner_id = auth.uid() or public.is_admin()))
  );

drop policy if exists needs_write_owner on public.needs;
create policy needs_write_owner on public.needs
  for insert with check (public.owns_farm(farm_id));

drop policy if exists needs_update_owner on public.needs;
create policy needs_update_owner on public.needs
  for update using (public.owns_farm(farm_id) or public.is_admin())
  with check (public.owns_farm(farm_id) or public.is_admin());

drop policy if exists needs_delete_owner on public.needs;
create policy needs_delete_owner on public.needs
  for delete using (public.owns_farm(farm_id) or public.is_admin());

-- offers: כל אחד יכול להציע עזרה (גם בלי הרשמה), רק בעל החווה רואה
drop policy if exists offers_insert_anyone on public.offers;
create policy offers_insert_anyone on public.offers
  for insert with check (
    exists (select 1 from public.needs n
              join public.farms f on f.id = n.farm_id
             where n.id = need_id and f.verified = true and n.status <> 'delivered')
  );

drop policy if exists offers_read_owner on public.offers;
create policy offers_read_owner on public.offers
  for select using (
    exists (select 1 from public.needs n
             where n.id = offers.need_id and public.owns_farm(n.farm_id))
    or public.is_admin()
  );

-- admins: קריאה עצמית בלבד. הוספת אדמין ידנית דרך ה-Dashboard.
drop policy if exists admins_read_self on public.admins;
create policy admins_read_self on public.admins
  for select using (user_id = auth.uid());

-- ============ פיד הצלחות (ללא פרטים אישיים) ============
create or replace view public.success_feed
with (security_invoker = true) as
  select n.id, n.title, n.type, n.delivered_at,
         f.name as farm_name, f.region, f.emoji
    from public.needs n
    join public.farms f on f.id = n.farm_id
   where n.status = 'delivered' and f.verified = true
   order by n.delivered_at desc;

grant select on public.success_feed to anon, authenticated;

-- ============ אחרי ההרצה ============
-- 1. Authentication → Providers → הפעל Email (Magic Link)
-- 2. הירשם דרך האתר, ואז שים כאן את ה-user id שלך:
--    insert into public.admins(user_id) values ('<YOUR-USER-UUID>');
--    (מוצאים אותו ב: Authentication → Users)
