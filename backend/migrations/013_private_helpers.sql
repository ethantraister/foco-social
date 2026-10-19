-- 19 Oct 2026: the small yes/no helpers behind the privacy rules move out of the public API.
-- Before this, any signed-in student could call them directly (/rest/v1/rpc/are_friends and so on) with anyone's id,
-- and learn who is friends with whom, who blocked whom, and whether someone marked them a close friend.
-- The rules themselves don't change: they keep using the same functions, which now live in a schema the API
-- doesn't publish. Also: trigger functions can't be called through the API, the three text helpers get a fixed
-- search_path, and the daily food-requests email job is switched off (the app no longer takes requests).
-- Run once on the live project (schema.sql already includes it).

create schema if not exists private;
-- Signed-in calls still run these inside the privacy rules and the app's read functions, so they need to find them.
grant usage on schema private to authenticated, service_role;

-- (Skips any already moved, so running this twice is harmless.)
do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('are_friends', 'is_blocked', 'is_member', 'in_group', 'can_see_plan', 'plan_host',
                        'marked_me_close', 'in_plan_chat')
  loop
    execute format('alter function %s set schema private', f);
  end loop;
end $$;

-- Functions that call those by name look in private too.
do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure from pg_proc p
    where p.pronamespace in ('public'::regnamespace, 'private'::regnamespace)
      and 'search_path=public' = any (p.proconfig)
  loop
    execute format('alter function %s set search_path = public, private', f);
  end loop;
end $$;

-- Trigger functions only ever run as triggers; nobody needs to call them.
do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prorettype = 'trigger'::regtype
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end $$;

alter function public.first_name(text) set search_path = public;
alter function public.clock(timestamptz) set search_path = public;
alter function public.day_clock(timestamptz) set search_path = public;

-- Food requests were taken out of the app, so the twice-a-day email job has nothing to do.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'daily-food-requests';
  end if;
end $$;
