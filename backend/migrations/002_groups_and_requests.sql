-- 10 Oct 2026: groups don't require friendship; food requests go through the app.
-- Run once on the live project (schema.sql already includes it).

-- Any group member can add any signed-up student (except people either of you has blocked).
drop policy if exists group_members_add on public.group_members;
create policy group_members_add on public.group_members for insert to authenticated
  with check (role = 'member' and is_member(group_id, auth.uid()) and not is_blocked(auth.uid(), user_id));

-- Food requests: collected here, emailed to Dining once a day by the daily-requests Edge Function.
create table if not exists public.food_requests (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  food        text not null check (char_length(trim(food)) between 2 and 60),
  meal        text check (meal in ('breakfast', 'lunch', 'dinner', 'late-night')),
  note        text check (char_length(note) <= 280),
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);
-- One request per food per person per day.
create unique index if not exists food_requests_once_a_day
  on public.food_requests (user_id, lower(trim(food)), ((created_at at time zone 'America/New_York')::date));

alter table public.food_requests enable row level security;
drop policy if exists food_requests_read on public.food_requests;
create policy food_requests_read on public.food_requests for select to authenticated
  using (user_id = auth.uid());
drop policy if exists food_requests_add on public.food_requests;
create policy food_requests_add on public.food_requests for insert to authenticated
  with check (user_id = auth.uid() and sent_at is null
              and (select count(*) from public.food_requests r
                   where r.user_id = auth.uid() and r.created_at > now() - interval '1 day') < 10);
drop policy if exists food_requests_delete on public.food_requests;
create policy food_requests_delete on public.food_requests for delete to authenticated
  using (user_id = auth.uid() and sent_at is null);
grant select, insert, delete on public.food_requests to authenticated;
revoke all on public.food_requests from anon;

-- What everyone's asking for lately (counts only, never names).
create or replace function public.popular_requests(days int default 7)
returns table (food text, students bigint, mine boolean)
language sql stable security definer set search_path = public as $$
  select min(trim(r.food)) as food,
         count(distinct r.user_id) as students,
         bool_or(r.user_id = auth.uid()) as mine
  from food_requests r
  where r.created_at > now() - make_interval(days => days)
  group by lower(trim(r.food))
  order by students desc, max(r.created_at) desc
  limit 15;
$$;
revoke all on function public.popular_requests(int) from public, anon;
grant execute on function public.popular_requests(int) to authenticated;

-- Everything not yet emailed, grouped by food. Only the daily-requests Edge Function (service role) can call it.
create or replace function public.request_digest()
returns table (food text, students bigint, meals json, notes text[], ids uuid[])
language sql stable security definer set search_path = public as $$
  with pending as (
    select r.*, lower(trim(r.food)) as k from food_requests r where r.sent_at is null
  ), per_meal as (
    select k, json_object_agg(meal, n) as meals
    from (select k, coalesce(meal, 'any') as meal, count(*) as n from pending group by 1, 2) x
    group by k
  )
  select min(trim(p.food)),
         count(distinct p.user_id),
         (array_agg(pm.meals))[1],
         (array_remove(array_agg(nullif(trim(p.note), '') order by p.created_at), null))[1:3],
         array_agg(p.id)
  from pending p join per_meal pm using (k)
  group by p.k
  order by 2 desc, 1;
$$;
revoke all on function public.request_digest() from public, anon, authenticated;
grant execute on function public.request_digest() to service_role;
