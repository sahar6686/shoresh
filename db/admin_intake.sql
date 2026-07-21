-- ============================================================
-- שורש — הזנת חוות ע"י אדמין ("חווה בטלפון")
--
-- למה: גיוס בשטח נעשה בשיחת טלפון. לדרוש מהמתיישב להיכנס למייל,
-- ללחוץ קישור ולמלא טופס — זה מאבד אותו. במקום זה סהראל מזין את
-- החווה ואת הצורך תוך כדי השיחה, והחווה עולה לאוויר מיד.
--
-- החווה נוצרת ללא owner_id ("לא משויכת"). כשהמתיישב ירצה לנהל
-- את עצמו, נשייך לו אותה — עדכון שדה אחד.
--
-- שים לב: זה לא עוקף את האימות הידני, זה *מממש* אותו — סהראל
-- מדבר עם האדם לפני שהחווה קיימת בכלל.
--
-- מריצים ב-SQL Editor. עמיד להרצה חוזרת.
-- ============================================================

-- אדמין רשאי להקים חווה בכל בעלות (כולל ללא בעלים).
-- המדיניות הקיימת (owner_id = auth.uid()) נשארת — המדיניות מצטרפות ב-OR.
drop policy if exists farms_admin_insert on public.farms;
create policy farms_admin_insert on public.farms
  for insert to authenticated with check (public.is_admin());

-- אדמין רשאי לפרסם צורך לכל חווה, גם לא-משויכת.
drop policy if exists needs_admin_insert on public.needs;
create policy needs_admin_insert on public.needs
  for insert to authenticated with check (public.is_admin());

-- שיוך חווה למתיישב לפי כתובת המייל שאיתה הוא נכנס.
-- אם עוד לא נכנס — נחזיר שגיאה ברורה במקום להשאיר את זה תלוי.
create or replace function public.assign_farm_owner(p_farm_id uuid, p_email text)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid;
begin
  if not public.is_admin() then
    raise exception 'רק אדמין רשאי לשייך חווה';
  end if;
  select id into v_uid from auth.users where lower(email) = lower(trim(p_email));
  if v_uid is null then
    raise exception 'המשתמש % עדיין לא נכנס למערכת — שיוך אפשרי אחרי הכניסה הראשונה', p_email;
  end if;
  update public.farms set owner_id = v_uid where id = p_farm_id;
end;
$$;

grant execute on function public.assign_farm_owner(uuid, text) to authenticated;
