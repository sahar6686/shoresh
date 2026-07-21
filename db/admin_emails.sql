-- ============================================================
-- שורש — הרשאת ניהול לפי כתובת מייל (רשימת היתר)
--
-- למה: אי אפשר לסמן מישהו כאדמין לפני שהוא נכנס בפעם הראשונה
-- (public.admins מצביע על auth.users). הרשימה כאן פותרת את זה —
-- רושמים כתובת מראש, וברגע שהיא מאומתת ההרשאה ניתנת אוטומטית.
--
-- בטיחות: ההענקה קורית רק אחרי email_confirmed_at, כלומר רק אחרי
-- שמישהו באמת לחץ על הקישור שנשלח לתיבה הזו. הקלדת כתובת של
-- מישהו אחר לא נותנת כלום — אין סשן בלי לחיצה על הקישור.
--
-- מריצים ב-SQL Editor. עמיד להרצה חוזרת.
-- ============================================================

create table if not exists public.admin_emails (
  email      text primary key,
  note       text,
  created_at timestamptz not null default now()
);

alter table public.admin_emails enable row level security;

drop policy if exists admin_emails_admin_all on public.admin_emails;
create policy admin_emails_admin_all on public.admin_emails
  for all using (public.is_admin()) with check (public.is_admin());

insert into public.admin_emails (email, note) values
  ('saharhazzani@gmail.com', 'סהר — ראשי'),
  ('sahar@tbp.design',       'סהר — חשבון החווה')
on conflict (email) do nothing;

create or replace function public.auto_grant_admin()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.email_confirmed_at is not null
     and exists (select 1 from public.admin_emails e
                 where lower(e.email) = lower(new.email)) then
    insert into public.admins(user_id) values (new.id)
    on conflict (user_id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_auto_grant_admin on auth.users;
create trigger trg_auto_grant_admin
  after insert or update of email_confirmed_at on auth.users
  for each row execute function public.auto_grant_admin();

-- מי שכבר קיים ונמצא ברשימה — להעניק עכשיו
insert into public.admins (user_id)
select u.id from auth.users u
join public.admin_emails e on lower(e.email) = lower(u.email)
on conflict (user_id) do nothing;

select u.email,
       (select count(*) from public.admins a where a.user_id = u.id) as is_admin
from auth.users u
order by u.created_at;
