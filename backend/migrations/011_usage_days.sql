-- 19 Oct 2026: count which features people use each day, to learn what students actually use before cutting
-- or adding anything. One row per person, day, and feature: no times, places, or content. Rows are deleted
-- with the account. Each person can add (and see) only their own rows. Read everyone's in the SQL Editor:
--   select * from usage_by_day;                      -- people per feature per day
--   select * from usage_weekly_retention;            -- of each week's new people, how many came back later
-- Run once on the live project (schema.sql already includes it). The app works the same before it's run.

create table if not exists public.usage_days (
  user_id  uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  day      date not null default (now() at time zone 'America/New_York')::date,
  feature  text not null check (feature in ('open', 'menu', 'together', 'going_soon', 'join', 'checkin', 'auto_checkin',
                                            'plan', 'rsvp', 'alert', 'friend', 'group', 'text_plan')),
  primary key (user_id, day, feature)
);
alter table public.usage_days enable row level security;
drop policy if exists usage_days_add_own on public.usage_days;
create policy usage_days_add_own on public.usage_days for insert to authenticated
  with check (user_id = auth.uid() and day = (now() at time zone 'America/New_York')::date);
-- Your own rows only. (Adding "already counted today" without an error needs to see the row it would add.)
drop policy if exists usage_days_see_own on public.usage_days;
create policy usage_days_see_own on public.usage_days for select to authenticated using (user_id = auth.uid());
revoke all on public.usage_days from anon, authenticated;
grant select, insert on public.usage_days to authenticated;

create or replace view public.usage_by_day as
  select day, feature, count(*) as people
  from public.usage_days
  group by day, feature
  order by day desc, people desc;

-- Week 0 is the week someone first opened the app; week 1 the week after, and so on.
create or replace view public.usage_weekly_retention as
  with firsts as (
    select user_id, date_trunc('week', min(day))::date as cohort from public.usage_days group by user_id
  ), weeks as (
    select distinct u.user_id, f.cohort, (date_trunc('week', u.day)::date - f.cohort) / 7 as week
    from public.usage_days u join firsts f using (user_id)
  )
  select cohort, week, count(*) as people,
         round(100.0 * count(*) / max(count(*)) over (partition by cohort), 1) as percent_of_cohort
  from weeks
  group by cohort, week
  order by cohort, week;

revoke all on public.usage_by_day, public.usage_weekly_retention from anon, authenticated;
