-- FoCo Social — database schema for Supabase (Postgres 15+).
-- Run once in the Supabase SQL editor, then run storage.sql.
-- Every table has row-level security: the app talks to the database directly,
-- so these policies are the only thing standing between users and each other's data.

-- ───────────────────────── profiles ─────────────────────────

create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  email       text not null unique check (lower(email) like '%@dartmouth.edu'),
  name        text not null check (char_length(trim(name)) between 1 and 40),
  class_year  int check (class_year between 2020 and 2040),
  emoji       text not null default '🍽️' check (char_length(emoji) <= 8),
  -- Profile photo in the meal-photos bucket, inside the person's own folder; when null the app shows initials.
  photo_path  text check (photo_path is null or photo_path like id::text || '/%'),
  created_at  timestamptz not null default now()
);

-- ───────────────────────── social graph ─────────────────────────

create table public.friendships (
  requester   uuid not null references public.profiles (id) on delete cascade,
  addressee   uuid not null references public.profiles (id) on delete cascade,
  status      text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at  timestamptz not null default now(),
  primary key (requester, addressee),
  check (requester <> addressee)
);
create unique index friendships_one_per_pair
  on public.friendships (least(requester, addressee), greatest(requester, addressee));

create table public.blocks (
  blocker     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  blocked     uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (blocker, blocked)
);

create function public.are_friends(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from friendships
    where status = 'accepted'
      and ((requester = a and addressee = b) or (requester = b and addressee = a))
  );
$$;

create function public.is_blocked(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from blocks
    where (blocker = a and blocked = b) or (blocker = b and blocked = a)
  );
$$;

-- ───────────────────────── groups (teams, clubs, floors) ─────────────────────────

create table public.groups (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(trim(name)) between 1 and 40),
  emoji       text not null default '👥' check (char_length(emoji) <= 8),
  -- Photo in the meal-photos bucket, in the folder of whoever set it; when null the app shows initials.
  photo_path  text,
  created_by  uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now()
);

create table public.group_members (
  group_id    uuid not null references public.groups (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  role        text not null default 'member' check (role in ('owner', 'member')),
  joined_at   timestamptz not null default now(),
  primary key (group_id, user_id)
);

create function public.is_member(g uuid, u uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from group_members where group_id = g and user_id = u);
$$;

create function public.add_group_owner() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into group_members (group_id, user_id, role) values (new.id, new.created_by, 'owner');
  return new;
end $$;
create trigger groups_add_owner after insert on public.groups
  for each row execute function public.add_group_owner();

-- A group's photo has to be in the photo folder of whoever sets it (the owner), the same rule as profile and post photos.
-- Only a changed photo is checked, so a new owner can still rename a group whose photo the old owner set.
create or replace function public.check_group_photo() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.photo_path is not null
     and (tg_op = 'INSERT' or new.photo_path is distinct from old.photo_path)
     and new.photo_path not like auth.uid()::text || '/%' then
    raise exception 'A group photo has to be in your own photo folder';
  end if;
  return new;
end $$;
drop trigger if exists groups_photo_own_folder on public.groups;
create trigger groups_photo_own_folder before insert or update of photo_path on public.groups
  for each row execute function public.check_group_photo();

-- Only the owner can hand the group to another member.
create function public.transfer_group(g uuid, new_owner uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from groups where id = g and created_by = auth.uid()) then
    raise exception 'Only the group owner can transfer it';
  end if;
  if new_owner = auth.uid() or not is_member(g, new_owner) then
    raise exception 'The new owner has to be someone else in the group';
  end if;
  update group_members set role = 'member' where group_id = g and user_id = auth.uid();
  update group_members set role = 'owner'  where group_id = g and user_id = new_owner;
  update groups set created_by = new_owner where id = g;
end $$;

-- If the owner deletes their account, the longest-standing member takes over; an empty group is deleted.
create function public.reassign_group_owner() returns trigger
language plpgsql security definer set search_path = public as $$
declare heir uuid;
begin
  if old.role <> 'owner' or not exists (select 1 from groups where id = old.group_id) then
    return old;
  end if;
  select user_id into heir from group_members where group_id = old.group_id order by joined_at limit 1;
  if heir is null then
    delete from groups where id = old.group_id;
  else
    update group_members set role = 'owner' where group_id = old.group_id and user_id = heir;
    update groups set created_by = heir where id = old.group_id;
  end if;
  return old;
end $$;
create trigger group_owner_left after delete on public.group_members
  for each row execute function public.reassign_group_owner();

-- ───────────────────────── meal plans ("let's get lunch at 1") ─────────────────────────

create table public.plans (
  id          uuid primary key default gen_random_uuid(),
  host        uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  meal        text not null check (meal in ('breakfast', 'lunch', 'dinner', 'late-night')),
  starts_at   timestamptz not null,
  note        text check (char_length(note) <= 140),
  audience    text not null default 'friends' check (audience in ('friends', 'invited', 'group')),
  group_id    uuid references public.groups (id) on delete cascade,
  cancelled   boolean not null default false,
  created_at  timestamptz not null default now(),
  check ((audience = 'group') = (group_id is not null))
);
create index plans_starts_at on public.plans (starts_at);

create table public.plan_members (
  plan_id     uuid not null references public.plans (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  status      text not null check (status in ('invited', 'going', 'maybe', 'declined')),
  updated_at  timestamptz not null default now(),
  primary key (plan_id, user_id)
);

create function public.can_see_plan(p uuid, u uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from plans pl
    where pl.id = p
      and not is_blocked(pl.host, u)
      and (
        pl.host = u
        or exists (select 1 from plan_members m where m.plan_id = pl.id and m.user_id = u)
        or (pl.audience = 'friends' and are_friends(pl.host, u))
        or (pl.audience = 'group' and is_member(pl.group_id, u))
      )
  );
$$;

create function public.plan_host(p uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select host from plans where id = p;
$$;

create function public.add_plan_host() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into plan_members (plan_id, user_id, status) values (new.id, new.host, 'going');
  return new;
end $$;
create trigger plans_add_host after insert on public.plans
  for each row execute function public.add_plan_host();

-- ───────────────────────── live check-ins ("I'm at FoCo now") ─────────────────────────

create table public.checkins (
  user_id       uuid primary key default auth.uid() references public.profiles (id) on delete cascade,
  spot          text check (char_length(spot) <= 40),
  open_to_join  boolean not null default true,
  started_at    timestamptz not null default now(),
  expires_at    timestamptz not null default now() + interval '60 minutes',
  eta           timestamptz  -- set when you're heading over ("at FoCo in 30 min"); null once you're there
);

-- ───────────────────────── posts: photos, ideas, complaints ─────────────────────────

create table public.posts (
  id          uuid primary key default gen_random_uuid(),
  author      uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  kind        text not null check (kind in ('photo', 'idea', 'complaint')),
  body        text not null default '' check (char_length(body) <= 500),
  photo_path  text,
  meal        text check (meal in ('breakfast', 'lunch', 'dinner', 'late-night')),
  dish        text check (char_length(dish) <= 80),
  served_on   date not null default (now() at time zone 'America/New_York')::date,
  hidden      boolean not null default false,
  created_at  timestamptz not null default now(),
  check (kind <> 'photo' or photo_path is not null),
  constraint posts_photo_own_folder check (photo_path is null or photo_path like author::text || '/%'),
  check (kind = 'photo' or char_length(trim(body)) > 0)
);
create index posts_feed on public.posts (served_on desc, created_at desc);

create table public.post_votes (
  post_id     uuid not null references public.posts (id) on delete cascade,
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table public.post_reports (
  post_id     uuid not null references public.posts (id) on delete cascade,
  reporter    uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  reason      text check (char_length(reason) <= 200),
  created_at  timestamptz not null default now(),
  primary key (post_id, reporter)
);

-- Three independent reports hide a post until a moderator looks at it.
create function public.hide_reported_post() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from post_reports where post_id = new.post_id) >= 3 then
    update posts set hidden = true where id = new.post_id;
  end if;
  return new;
end $$;
create trigger post_reports_hide after insert on public.post_reports
  for each row execute function public.hide_reported_post();

-- ───────────────────────── row-level security ─────────────────────────

alter table public.profiles      enable row level security;
alter table public.friendships   enable row level security;
alter table public.blocks        enable row level security;
alter table public.groups        enable row level security;
alter table public.group_members enable row level security;
alter table public.plans         enable row level security;
alter table public.plan_members  enable row level security;
alter table public.checkins      enable row level security;
alter table public.posts         enable row level security;
alter table public.post_votes    enable row level security;
alter table public.post_reports  enable row level security;

-- Names are visible to every signed-in Dartmouth user, so people can find friends.
create policy profiles_read on public.profiles for select to authenticated using (true);
create policy profiles_insert on public.profiles for insert to authenticated
  with check (id = auth.uid() and lower(email) = lower(auth.jwt() ->> 'email'));
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid() and lower(email) = lower(auth.jwt() ->> 'email'));

create policy friendships_read on public.friendships for select to authenticated
  using (auth.uid() in (requester, addressee));
create policy friendships_request on public.friendships for insert to authenticated
  with check (requester = auth.uid() and status = 'pending' and not is_blocked(requester, addressee));
-- Accepting changes only the status; a trigger (below the policies) stops anyone rewriting who a request is between.
create policy friendships_accept on public.friendships for update to authenticated
  using (addressee = auth.uid()) with check (addressee = auth.uid());
create policy friendships_remove on public.friendships for delete to authenticated
  using (auth.uid() in (requester, addressee));

create policy blocks_own on public.blocks for all to authenticated
  using (blocker = auth.uid()) with check (blocker = auth.uid());

create policy groups_read on public.groups for select to authenticated
  using (is_member(id, auth.uid()) or created_by = auth.uid());
create policy groups_create on public.groups for insert to authenticated
  with check (created_by = auth.uid());
-- The owner can rename the group; ownership only changes through transfer_group().
create policy groups_edit on public.groups for update to authenticated
  using (created_by = auth.uid()) with check (created_by = auth.uid());
create policy groups_delete on public.groups for delete to authenticated
  using (created_by = auth.uid());

create policy group_members_read on public.group_members for select to authenticated
  using (is_member(group_id, auth.uid()));
-- Members can add their own friends; nobody can be added by a stranger.
create policy group_members_add on public.group_members for insert to authenticated
  with check (role = 'member' and is_member(group_id, auth.uid()) and not is_blocked(auth.uid(), user_id));
-- Members can leave; the owner can remove anyone else. The owner can't leave without transferring or deleting first.
create policy group_members_leave on public.group_members for delete to authenticated
  using (
    (user_id = auth.uid() and not exists (select 1 from groups g where g.id = group_id and g.created_by = auth.uid()))
    or (user_id <> auth.uid() and exists (select 1 from groups g where g.id = group_id and g.created_by = auth.uid()))
  );

-- The host check is inline because a just-inserted plan isn't visible to can_see_plan() yet.
create policy plans_read on public.plans for select to authenticated
  using (host = auth.uid() or can_see_plan(id, auth.uid()));
create policy plans_create on public.plans for insert to authenticated
  with check (host = auth.uid() and (group_id is null or is_member(group_id, auth.uid())));
create policy plans_edit on public.plans for update to authenticated
  using (host = auth.uid())
  with check (host = auth.uid() and (group_id is null or is_member(group_id, auth.uid())));
create policy plans_delete on public.plans for delete to authenticated
  using (host = auth.uid());

create policy plan_members_read on public.plan_members for select to authenticated
  using (can_see_plan(plan_id, auth.uid()));
-- Either you respond for yourself on a plan you can see, or the host invites a friend.
create policy plan_members_add on public.plan_members for insert to authenticated
  with check (
    (user_id = auth.uid() and status in ('going', 'maybe', 'declined') and can_see_plan(plan_id, auth.uid()))
    or (status = 'invited' and plan_host(plan_id) = auth.uid() and are_friends(auth.uid(), user_id))
  );
create policy plan_members_respond on public.plan_members for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and status in ('going', 'maybe', 'declined'));
create policy plan_members_remove on public.plan_members for delete to authenticated
  using (user_id = auth.uid() or plan_host(plan_id) = auth.uid());

create policy checkins_read on public.checkins for select to authenticated
  using (user_id = auth.uid() or (are_friends(user_id, auth.uid()) and not is_blocked(user_id, auth.uid())));
create policy checkins_own on public.checkins for insert to authenticated
  with check (user_id = auth.uid() and expires_at <= now() + interval '3 hours');
create policy checkins_update on public.checkins for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and expires_at <= now() + interval '3 hours');
create policy checkins_delete on public.checkins for delete to authenticated
  using (user_id = auth.uid());

create policy posts_read on public.posts for select to authenticated
  using (author = auth.uid() or (not hidden and not is_blocked(author, auth.uid())));
-- At most 20 posts a day per person, so one account can't flood the feed.
create policy posts_create on public.posts for insert to authenticated
  with check (author = auth.uid() and hidden = false
              and (select count(*) from public.posts p
                   where p.author = auth.uid() and p.created_at > now() - interval '1 day') < 20);
create policy posts_delete on public.posts for delete to authenticated
  using (author = auth.uid());

create policy post_votes_read on public.post_votes for select to authenticated using (true);
create policy post_votes_add on public.post_votes for insert to authenticated with check (user_id = auth.uid());
create policy post_votes_remove on public.post_votes for delete to authenticated using (user_id = auth.uid());

create policy post_reports_add on public.post_reports for insert to authenticated with check (reporter = auth.uid());
create policy post_reports_read on public.post_reports for select to authenticated using (reporter = auth.uid());

-- A friend request or plan reply can't change hands; updates only change its status.
create or replace function public.keep_friendship_people() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.requester is distinct from old.requester or new.addressee is distinct from old.addressee then
    raise exception 'A friend request can''t change who it''s between';
  end if;
  return new;
end $$;
drop trigger if exists friendships_keep_people on public.friendships;
create trigger friendships_keep_people before update on public.friendships
  for each row execute function public.keep_friendship_people();

create or replace function public.keep_plan_member() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.plan_id is distinct from old.plan_id or new.user_id is distinct from old.user_id then
    raise exception 'A plan reply can''t move to another plan or person';
  end if;
  return new;
end $$;
drop trigger if exists plan_members_keep_owner on public.plan_members;
create trigger plan_members_keep_owner before update on public.plan_members
  for each row execute function public.keep_plan_member();

-- ───────────────────────── read models for the app ─────────────────────────
-- These run as the caller (security invoker), so every row still passes the policies above.

create function public.my_people()
returns table (id uuid, name text, emoji text, photo_path text, class_year int, relation text)
language sql stable set search_path = public as $$
  select p.id, p.name, p.emoji, p.photo_path, p.class_year,
         case when f.status = 'accepted' then 'friend'
              when f.addressee = auth.uid() then 'incoming'
              else 'outgoing' end
  from friendships f
  join profiles p on p.id = case when f.requester = auth.uid() then f.addressee else f.requester end
  where not is_blocked(auth.uid(), p.id)
  order by p.name;
$$;

-- Matches names only (not NetIDs).
create function public.search_people(q text)
returns table (id uuid, name text, emoji text, photo_path text, class_year int, relation text)
language sql stable set search_path = public as $$
  select p.id, p.name, p.emoji, p.photo_path, p.class_year,
         coalesce((select case when f.status = 'accepted' then 'friend'
                               when f.addressee = auth.uid() then 'incoming'
                               else 'outgoing' end
                   from friendships f
                   where (f.requester = auth.uid() and f.addressee = p.id)
                      or (f.addressee = auth.uid() and f.requester = p.id)), 'none')
  from profiles p
  where auth.uid() is not null
    and p.id <> auth.uid()
    and not is_blocked(auth.uid(), p.id)
    and char_length(trim(q)) >= 2
    and p.name ilike '%' || trim(q) || '%'
  order by p.name
  limit 25;
$$;

-- Everything the "Eat together" screen needs in one round trip.
create function public.together(window_hours int default 36)
returns json
language sql stable set search_path = public as $$
  select json_build_object(
    'checkins', coalesce((
      select json_agg(json_build_object(
        'user', json_build_object('id', p.id, 'name', p.name, 'emoji', p.emoji, 'photo_path', p.photo_path, 'class_year', p.class_year),
        'spot', c.spot, 'open_to_join', c.open_to_join, 'eta', c.eta,
        'started_at', c.started_at, 'expires_at', c.expires_at) order by c.started_at desc)
      from checkins c join profiles p on p.id = c.user_id
      where c.expires_at > now()), '[]'::json),
    'plans', coalesce((
      select json_agg(json_build_object(
        'id', pl.id, 'meal', pl.meal, 'starts_at', pl.starts_at, 'note', pl.note,
        'audience', pl.audience, 'cancelled', pl.cancelled,
        'group', (select json_build_object('id', g.id, 'name', g.name, 'emoji', g.emoji, 'photo_path', g.photo_path) from groups g where g.id = pl.group_id),
        'host', (select json_build_object('id', h.id, 'name', h.name, 'emoji', h.emoji, 'photo_path', h.photo_path, 'class_year', h.class_year) from profiles h where h.id = pl.host),
        'members', coalesce((
          select json_agg(json_build_object(
            'user', json_build_object('id', u.id, 'name', u.name, 'emoji', u.emoji, 'photo_path', u.photo_path, 'class_year', u.class_year),
            'status', m.status) order by m.updated_at)
          from plan_members m join profiles u on u.id = m.user_id
          where m.plan_id = pl.id), '[]'::json)
      ) order by pl.starts_at)
      from plans pl
      where pl.starts_at > now() - interval '90 minutes'
        and pl.starts_at < now() + make_interval(hours => window_hours)
        and not pl.cancelled), '[]'::json)
  );
$$;

create function public.feed(kind_filter text default null, day date default null, sort text default 'new', lim int default 60)
returns table (
  id uuid, author_id uuid, author_name text, author_emoji text, author_photo text,
  kind text, body text, photo_path text, meal text, dish text,
  served_on date, created_at timestamptz, votes bigint, voted boolean
)
language sql stable set search_path = public as $$
  select po.id, a.id, a.name, a.emoji, a.photo_path,
         po.kind, po.body, po.photo_path, po.meal, po.dish,
         po.served_on, po.created_at,
         (select count(*) from post_votes v where v.post_id = po.id),
         exists (select 1 from post_votes v where v.post_id = po.id and v.user_id = auth.uid())
  from posts po join profiles a on a.id = po.author
  where (kind_filter is null or po.kind = kind_filter)
    and (day is null or po.served_on = day)
  order by
    case when sort = 'top' then (select count(*) from post_votes v where v.post_id = po.id) end desc nulls last,
    po.created_at desc
  limit least(lim, 200);
$$;

-- App Store rule 5.1.1(v): people must be able to delete their account in the app.
create function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  -- The app deletes everything in your photo folder first, including photos you set for groups;
  -- those groups go back to showing their initials instead of a broken image.
  update groups set photo_path = null where photo_path like auth.uid()::text || '/%';
  delete from auth.users where id = auth.uid();
end $$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

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

-- Nothing is readable or callable without signing in.
revoke all on all tables in schema public from anon;
revoke execute on all functions in schema public from public, anon;
grant select, insert, update, delete on all tables in schema public to authenticated;
-- Other people's email addresses aren't readable; the app never needs them.
revoke select on public.profiles from authenticated;
grant select (id, name, class_year, emoji, photo_path, created_at) on public.profiles to authenticated;
grant execute on all functions in schema public to authenticated;

-- The daily email digest is for the server only.
revoke execute on function public.request_digest() from authenticated;
