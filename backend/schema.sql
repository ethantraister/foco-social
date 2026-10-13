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

create function public.friends_of(u uuid) returns setof uuid
language sql stable security definer set search_path = public as $$
  select case when requester = u then addressee else requester end
  from friendships where status = 'accepted' and u in (requester, addressee);
$$;

-- Close friends: going soon / at FoCo can be shared with only them, and they can be the only ones you hear about.
create table public.close_friends (
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  friend_id   uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, friend_id),
  check (user_id <> friend_id)
);

-- For the server only: did `owner` mark `other` as a close friend?
create function public.is_close(owner uuid, other uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from close_friends where user_id = owner and friend_id = other);
$$;

-- For policies: did `owner` mark you as a close friend? (Never tells you about anyone else.)
create function public.marked_me_close(owner uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from close_friends where user_id = owner and friend_id = auth.uid());
$$;

-- Unfriending clears close-friend marks both ways.
create function public.forget_close_friends() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from close_friends
  where (user_id = old.requester and friend_id = old.addressee) or (user_id = old.addressee and friend_id = old.requester);
  return old;
end $$;
create trigger friendships_forget_close after delete on public.friendships
  for each row execute function public.forget_close_friends();

-- Small helpers for notification text: first names and Hanover times ("6:30 PM", "Tue 6:30 PM").
create function public.first_name(full_name text) returns text
language sql immutable as $$ select split_part(trim(full_name), ' ', 1) $$;

create function public.clock(t timestamptz) returns text
language sql stable as $$ select to_char(t at time zone 'America/New_York', 'FMHH12:MI AM') $$;

create function public.day_clock(t timestamptz) returns text
language sql stable as $$ select to_char(t at time zone 'America/New_York', 'Dy FMHH12:MI AM') $$;

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
  -- Being added is an invite until you accept it.
  status      text not null default 'joined' constraint group_members_status_check check (status in ('invited', 'joined')),
  -- Who sent the invite. Not a foreign key, so group_members has one link to profiles and embeds stay unambiguous.
  invited_by  uuid,
  primary key (group_id, user_id)
);

-- Members are people who joined; an invite doesn't count until it's accepted.
create function public.is_member(g uuid, u uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from group_members where group_id = g and user_id = u and status = 'joined');
$$;

-- In the group or invited to it: enough to see the group's name and who's in it.
create function public.in_group(g uuid, u uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from group_members where group_id = g and user_id = u);
$$;

-- Adding someone else is always an invite. (The owner's own row, made with the group, is joined.)
create function public.group_member_defaults() returns trigger
language plpgsql set search_path = public as $$
begin
  if auth.uid() is not null and new.user_id <> auth.uid() then
    new.status := 'invited';
    new.invited_by := auth.uid();
    new.role := 'member';
  end if;
  return new;
end $$;
create trigger group_members_defaults before insert on public.group_members
  for each row execute function public.group_member_defaults();

-- An accepted invite only changes its status (and when you joined).
create function public.keep_group_member() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.group_id is distinct from old.group_id or new.user_id is distinct from old.user_id then
    raise exception 'A group membership can''t move to another group or person';
  end if;
  new.invited_by := old.invited_by;   -- who sent the invite can't be rewritten
  if old.status = 'invited' and new.status = 'joined' then new.joined_at := now(); end if;
  return new;
end $$;
create trigger group_members_keep before update on public.group_members
  for each row execute function public.keep_group_member();

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

-- If the owner deletes their account, the longest-standing member who joined takes over; with nobody left, the group goes.
create function public.reassign_group_owner() returns trigger
language plpgsql security definer set search_path = public as $$
declare heir uuid;
begin
  if old.role <> 'owner' or not exists (select 1 from groups where id = old.group_id) then
    return old;
  end if;
  select user_id into heir from group_members where group_id = old.group_id and status = 'joined' order by joined_at limit 1;
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
  -- The host invited them, so taking back their answer goes back to "invited" rather than removing them.
  was_invited boolean not null default false,
  primary key (plan_id, user_id)
);

create function public.plan_member_defaults() returns trigger
language plpgsql set search_path = public as $$
begin
  new.was_invited := new.status = 'invited';
  return new;
end $$;
create trigger plan_members_defaults before insert on public.plan_members
  for each row execute function public.plan_member_defaults();

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
  eta           timestamptz,  -- set when you're heading over ("at FoCo in 30 min"); null once you're there
  audience      text not null default 'friends' constraint checkins_audience_check check (audience in ('friends', 'close')),
  -- Set by "Me too" / "On my way": the friend you're joining, who gets told.
  joining       uuid references public.profiles (id) on delete set null,
  -- "Going soon" out loud: friends get a notification. Quiet is the default.
  notify        boolean not null default false
);

-- ───────────────────────── chat ─────────────────────────

create table public.messages (
  id          uuid primary key default gen_random_uuid(),
  sender      uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  group_id    uuid references public.groups (id) on delete cascade,
  plan_id     uuid references public.plans (id) on delete cascade,
  recipient   uuid references public.profiles (id) on delete cascade,
  body        text not null check (char_length(trim(body)) between 1 and 1000),
  created_at  timestamptz not null default now(),
  check (num_nonnulls(group_id, plan_id, recipient) = 1),
  check (recipient is distinct from sender)
);
create index messages_group on public.messages (group_id, created_at desc) where group_id is not null;
create index messages_plan on public.messages (plan_id, created_at desc) where plan_id is not null;
create index messages_dm on public.messages (least(sender, recipient), greatest(sender, recipient), created_at desc) where recipient is not null;

-- A plan's chat is for the host and everyone invited, going, or maybe.
create function public.in_plan_chat(p uuid, u uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from plans pl
    where pl.id = p and not is_blocked(pl.host, u)
      and (pl.host = u or exists (select 1 from plan_members m where m.plan_id = p and m.user_id = u
                                                              and m.status in ('going', 'maybe', 'invited')))
  );
$$;

create table public.message_reports (
  message_id  uuid not null references public.messages (id) on delete cascade,
  reporter    uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  reason      text check (char_length(reason) <= 200),
  created_at  timestamptz not null default now(),
  primary key (message_id, reporter)
);

-- When you last read each chat ('group:<id>', 'plan:<id>', 'dm:<their id>'), for unread counts.
create table public.chat_reads (
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  thread      text not null check (thread ~ '^(group|plan|dm):[0-9a-f-]{36}$'),
  read_at     timestamptz not null default now(),
  primary key (user_id, thread)
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
alter table public.close_friends   enable row level security;
alter table public.messages        enable row level security;
alter table public.message_reports enable row level security;
alter table public.chat_reads      enable row level security;

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

create policy close_friends_read on public.close_friends for select to authenticated
  using (user_id = auth.uid());
create policy close_friends_add on public.close_friends for insert to authenticated
  with check (user_id = auth.uid() and are_friends(user_id, friend_id));
create policy close_friends_remove on public.close_friends for delete to authenticated
  using (user_id = auth.uid());

create policy groups_read on public.groups for select to authenticated
  using (in_group(id, auth.uid()) or created_by = auth.uid());
create policy groups_create on public.groups for insert to authenticated
  with check (created_by = auth.uid());
-- The owner can rename the group; ownership only changes through transfer_group().
create policy groups_edit on public.groups for update to authenticated
  using (created_by = auth.uid()) with check (created_by = auth.uid());
create policy groups_delete on public.groups for delete to authenticated
  using (created_by = auth.uid());

create policy group_members_read on public.group_members for select to authenticated
  using (in_group(group_id, auth.uid()));
-- Members can invite anyone who hasn't blocked them; the invite waits for them to accept.
create policy group_members_add on public.group_members for insert to authenticated
  with check (role = 'member' and status = 'invited' and invited_by = auth.uid()
              and is_member(group_id, auth.uid()) and not is_blocked(auth.uid(), user_id));
create policy group_members_accept on public.group_members for update to authenticated
  using (user_id = auth.uid() and status = 'invited')
  with check (user_id = auth.uid() and status = 'joined' and role = 'member');
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
-- Answer Going / Maybe / Can't, or (if you were invited) go back to not having answered.
create policy plan_members_respond on public.plan_members for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and (status in ('going', 'maybe', 'declined') or (status = 'invited' and was_invited)));
create policy plan_members_remove on public.plan_members for delete to authenticated
  using (user_id = auth.uid() or plan_host(plan_id) = auth.uid());

create policy checkins_read on public.checkins for select to authenticated
  using (user_id = auth.uid()
         or (are_friends(user_id, auth.uid()) and not is_blocked(user_id, auth.uid())
             and (audience = 'friends' or marked_me_close(user_id))));
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

create policy messages_read on public.messages for select to authenticated
  using (not is_blocked(sender, auth.uid()) and (
    (group_id is not null and is_member(group_id, auth.uid()))
    or (plan_id is not null and in_plan_chat(plan_id, auth.uid()))
    or (recipient is not null and auth.uid() in (sender, recipient))
  ));
-- Messages between friends only; at most 200 an hour per person.
create policy messages_send on public.messages for insert to authenticated
  with check (sender = auth.uid() and (
      (group_id is not null and is_member(group_id, auth.uid()))
      or (plan_id is not null and in_plan_chat(plan_id, auth.uid()))
      or (recipient is not null and are_friends(sender, recipient) and not is_blocked(sender, recipient)))
    and (select count(*) from public.messages m where m.sender = auth.uid() and m.created_at > now() - interval '1 hour') < 200);
create policy messages_unsend on public.messages for delete to authenticated
  using (sender = auth.uid());

create policy message_reports_add on public.message_reports for insert to authenticated with check (reporter = auth.uid());
create policy message_reports_read on public.message_reports for select to authenticated using (reporter = auth.uid());

create policy chat_reads_own on public.chat_reads for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

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
  new.was_invited := old.was_invited;
  return new;
end $$;
drop trigger if exists plan_members_keep_owner on public.plan_members;
create trigger plan_members_keep_owner before update on public.plan_members
  for each row execute function public.keep_plan_member();

-- ───────────────────────── push notifications ─────────────────────────

-- Each phone's push token. Only the server reads these; the app registers through register_device().
create table public.devices (
  token       text primary key,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  sandbox     boolean not null default false,
  updated_at  timestamptz not null default now()
);
alter table public.devices enable row level security;

create function public.register_device(device_token text, use_sandbox boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if device_token !~ '^[0-9a-f]{32,200}$' then raise exception 'That isn''t a device token'; end if;
  insert into devices (token, user_id, sandbox, updated_at) values (device_token, auth.uid(), use_sandbox, now())
  on conflict (token) do update set user_id = excluded.user_id, sandbox = excluded.sandbox, updated_at = now();
end $$;

create function public.unregister_device(device_token text) returns void
language sql security definer set search_path = public as $$
  delete from devices where token = device_token and user_id = auth.uid();
$$;

-- What each person wants to hear about. No row means the defaults.
create table public.notify_settings (
  user_id     uuid primary key default auth.uid() references public.profiles (id) on delete cascade,
  going       text not null default 'all' check (going in ('off', 'close', 'all')),       -- friends going soon (out loud)
  arrivals    text not null default 'close' check (arrivals in ('off', 'close', 'all')),  -- friends getting to FoCo
  joins       boolean not null default true,  -- someone joins you, or says they're coming to your plan
  plans       boolean not null default true,  -- meal invites, and changes to plans you're in
  groups      boolean not null default true,  -- group invites and team meals
  messages    boolean not null default true,
  updated_at  timestamptz not null default now()
);
alter table public.notify_settings enable row level security;
create policy notify_settings_own on public.notify_settings for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- For the server only: does `u` want this kind of notification about `about`?
create function public.wants(u uuid, what text, about uuid default null) returns boolean
language sql stable security definer set search_path = public as $$
  select case what
    when 'going'    then coalesce(s.going, 'all') = 'all' or (coalesce(s.going, 'all') = 'close' and is_close(u, about))
    when 'arrivals' then coalesce(s.arrivals, 'close') = 'all' or (coalesce(s.arrivals, 'close') = 'close' and is_close(u, about))
    when 'joins'    then coalesce(s.joins, true)
    when 'plans'    then coalesce(s.plans, true)
    when 'groups'   then coalesce(s.groups, true)
    when 'messages' then coalesce(s.messages, true)
    else false
  end
  from (select 1) one left join notify_settings s on s.user_id = u;
$$;

-- Notifications waiting to go out. The push Edge Function sends each one once and stamps sent_at.
create table public.push_queue (
  id          bigint generated always as identity primary key,
  sender      uuid default auth.uid(),
  kind        text not null default 'other',
  recipients  uuid[] not null,
  title       text not null,
  body        text not null,
  route       jsonb not null default '{}',  -- what tapping it opens, e.g. {"tab": "together"} or {"chat": "group:<id>"}
  thread      text,                         -- groups notifications from the same chat
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);
alter table public.push_queue enable row level security;

-- The push function's current Apple sign-in token. Apple rejects one that changes too often, so it's shared and reused.
create table public.push_auth (
  id          int primary key default 1 check (id = 1),
  token       text not null,
  issued_at   timestamptz not null
);
alter table public.push_auth enable row level security;

create function public.queue_push(recipients uuid[], title text, body text,
                                             route jsonb default '{}', thread text default null,
                                             kind text default 'other') returns void
language plpgsql security definer set search_path = public as $$
declare who uuid[];
begin
  select array_agg(distinct d.user_id) into who
  from devices d where d.user_id = any(recipients) and d.user_id is distinct from auth.uid();
  if who is null then return; end if;
  insert into push_queue (recipients, title, body, route, thread, kind)
  values (who, left(title, 120), left(body, 240), route, thread, kind);
end $$;

-- Hands each queued notification to the push Edge Function (on Supabase, with pg_net; ANON_KEY_VALUE is the project's
-- anon key, filled in when the migration runs). A notification problem never blocks what you were doing.
create function public.deliver_push() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'net' and p.proname = 'http_post') then
    perform net.http_post(
      url := 'https://nfvzzxnqnogmhmiluszg.supabase.co/functions/v1/push',
      body := jsonb_build_object('id', new.id),
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ANON_KEY_VALUE')
    );
  end if;
  return new;
exception when others then
  return new;
end $$;
create trigger push_queue_deliver after insert on public.push_queue
  for each row execute function public.deliver_push();

-- Going soon (out loud), getting to FoCo, and joining a friend.
create function public.push_checkin() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  who text;
  whom uuid[];
begin
  -- Only a new check-in or a new "going soon" notifies, not picking a room.
  if not (tg_op = 'INSERT' or new.started_at is distinct from old.started_at) or new.expires_at <= now() then
    return new;
  end if;
  select first_name(name) into who from profiles where id = new.user_id;

  if new.joining is not null and new.joining <> new.user_id and are_friends(new.joining, new.user_id)
     and not is_blocked(new.joining, new.user_id) and wants(new.joining, 'joins') then
    perform queue_push(array[new.joining], who || ' is joining you',
                       case when new.eta is null then 'At FoCo now' else 'At FoCo around ' || clock(new.eta) end,
                       '{"tab": "together"}', null, 'join');
  end if;

  select array_agg(f) into whom from friends_of(new.user_id) f
  where f is distinct from new.joining and not is_blocked(f, new.user_id)
    and (new.audience = 'friends' or is_close(new.user_id, f))
    and wants(f, case when new.eta is null then 'arrivals' else 'going' end, new.user_id);

  -- At most one "going" and one "at FoCo" notification per person every 20 minutes, however often they tap.
  if new.eta is not null and new.notify
     and not exists (select 1 from push_queue q where q.sender = new.user_id and q.kind = 'going' and q.created_at > now() - interval '20 minutes') then
    perform queue_push(whom, who || ' is going to FoCo', 'Around ' || clock(new.eta) || coalesce(' · ' || new.spot, ''),
                       '{"tab": "together"}', null, 'going');
  elsif new.eta is null
     and not exists (select 1 from push_queue q where q.sender = new.user_id and q.kind = 'arrival' and q.created_at > now() - interval '20 minutes') then
    perform queue_push(whom, who || ' is at FoCo', coalesce(new.spot, 'Just got there'), '{"tab": "together"}', null, 'arrival');
  end if;
  return new;
end $$;
create trigger checkins_push after insert or update on public.checkins
  for each row execute function public.push_checkin();

-- Invites, people saying they're coming, and team meals.
create function public.push_plan_member() returns trigger
language plpgsql security definer set search_path = public as $$
declare pl plans;
begin
  select * into pl from plans where id = new.plan_id;
  if pl.id is null or pl.cancelled or pl.starts_at < now() - interval '30 minutes' then return new; end if;
  if tg_op = 'INSERT' and new.status = 'invited' and wants(new.user_id, 'plans') then
    perform queue_push(array[new.user_id],
                       (select first_name(name) from profiles where id = pl.host) || ' invited you to ' || replace(pl.meal, '-', ' '),
                       day_clock(pl.starts_at) || coalesce(' · ' || pl.note, ''),
                       jsonb_build_object('plan', pl.id));
  elsif new.status = 'going' and new.user_id <> pl.host
        and (tg_op = 'INSERT' or old.status is distinct from 'going') and wants(pl.host, 'joins') then
    perform queue_push(array[pl.host],
                       (select first_name(name) from profiles where id = new.user_id) || ' is coming to ' || replace(pl.meal, '-', ' '),
                       day_clock(pl.starts_at),
                       jsonb_build_object('plan', pl.id));
  end if;
  return new;
end $$;
create trigger plan_members_push after insert or update on public.plan_members
  for each row execute function public.push_plan_member();

create function public.push_plan() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  host_name text;
  whom uuid[];
begin
  select first_name(name) into host_name from profiles where id = new.host;
  if tg_op = 'INSERT' then
    if new.group_id is not null then
      select array_agg(m.user_id) into whom from group_members m
      where m.group_id = new.group_id and m.status = 'joined' and m.user_id <> new.host
        and not is_blocked(m.user_id, new.host) and wants(m.user_id, 'groups');
      perform queue_push(whom, (select name from groups where id = new.group_id) || ' · ' || replace(new.meal, '-', ' '),
                         host_name || ' planned ' || replace(new.meal, '-', ' ') || ', ' || day_clock(new.starts_at),
                         jsonb_build_object('plan', new.id));
    end if;
    return new;
  end if;

  select array_agg(m.user_id) into whom from plan_members m
  where m.plan_id = new.id and m.user_id <> new.host and m.status in ('going', 'maybe', 'invited') and wants(m.user_id, 'plans');
  if new.cancelled and not old.cancelled then
    perform queue_push(whom, host_name || ' cancelled ' || replace(new.meal, '-', ' '), day_clock(new.starts_at), '{"tab": "together"}');
  elsif not new.cancelled and (new.starts_at is distinct from old.starts_at or new.meal is distinct from old.meal) then
    perform queue_push(whom, host_name || ' changed ' || replace(old.meal, '-', ' '),
                       'Now ' || replace(new.meal, '-', ' ') || ', ' || day_clock(new.starts_at),
                       jsonb_build_object('plan', new.id));
  end if;
  return new;
end $$;
create trigger plans_push after insert or update on public.plans
  for each row execute function public.push_plan();

create function public.push_group_invite() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'invited' and wants(new.user_id, 'groups') then
    perform queue_push(array[new.user_id],
                       coalesce((select first_name(name) from profiles where id = new.invited_by), 'Someone')
                         || ' invited you to ' || (select name from groups where id = new.group_id),
                       'Join to see the group''s meal plans and chat.',
                       '{"tab": "together"}');
  end if;
  return new;
end $$;
create trigger group_members_push after insert on public.group_members
  for each row execute function public.push_group_invite();

create function public.push_message() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  who text;
  whom uuid[];
  title text;
  chat_key text;
begin
  select name into who from profiles where id = new.sender;
  if new.group_id is not null then
    chat_key := 'group:' || new.group_id;
    select name into title from groups where id = new.group_id;
    select array_agg(m.user_id) into whom from group_members m
    where m.group_id = new.group_id and m.status = 'joined';
  elsif new.plan_id is not null then
    chat_key := 'plan:' || new.plan_id;
    select initcap(replace(pl.meal, '-', ' ')) || ' · ' || day_clock(pl.starts_at) into title from plans pl where pl.id = new.plan_id;
    select array_agg(u) into whom from (
      select host as u from plans where id = new.plan_id
      union select m.user_id from plan_members m where m.plan_id = new.plan_id and m.status in ('going', 'maybe', 'invited')
    ) x;
  else
    chat_key := 'dm:' || new.sender;  -- the recipient's key for this chat is the sender's id
    title := who;
    whom := array[new.recipient];
  end if;
  select array_agg(u) into whom from unnest(whom) u
  where u <> new.sender and not is_blocked(u, new.sender) and wants(u, 'messages');
  perform queue_push(whom, title,
                     case when new.recipient is null then first_name(who) || ': ' else '' end || new.body,
                     jsonb_build_object('chat', chat_key), chat_key, 'message');
  return new;
end $$;
create trigger messages_push after insert on public.messages
  for each row execute function public.push_message();

-- ───────────────────────── read models for the app ─────────────────────────
-- These run as the caller (security invoker), so every row still passes the policies above.

create function public.my_people()
returns table (id uuid, name text, emoji text, photo_path text, class_year int, relation text, close boolean)
language sql stable set search_path = public as $$
  select p.id, p.name, p.emoji, p.photo_path, p.class_year,
         case when f.status = 'accepted' then 'friend'
              when f.addressee = auth.uid() then 'incoming'
              else 'outgoing' end,
         exists (select 1 from close_friends c where c.user_id = auth.uid() and c.friend_id = p.id)
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
        'spot', c.spot, 'open_to_join', c.open_to_join, 'eta', c.eta, 'audience', c.audience, 'joining', c.joining,
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
            'status', m.status, 'was_invited', m.was_invited) order by m.updated_at)
          from plan_members m join profiles u on u.id = m.user_id
          where m.plan_id = pl.id), '[]'::json)
      ) order by pl.starts_at)
      from plans pl
      where pl.starts_at > now() - interval '90 minutes'
        and pl.starts_at < now() + make_interval(hours => window_hours)
        and not pl.cancelled), '[]'::json)
  );
$$;

-- One chat's messages, newest first. `newer_than` fetches only what's new; `older_than` pages back.
create function public.chat_messages(kind text, target uuid, newer_than timestamptz default null,
                                                older_than timestamptz default null, lim int default 80)
returns table (id uuid, body text, created_at timestamptz, sender json)
language sql stable set search_path = public as $$
  select m.id, m.body, m.created_at,
         json_build_object('id', p.id, 'name', p.name, 'emoji', p.emoji, 'photo_path', p.photo_path, 'class_year', p.class_year)
  from messages m join profiles p on p.id = m.sender
  where ((kind = 'group' and m.group_id = target)
      or (kind = 'plan' and m.plan_id = target)
      or (kind = 'dm' and m.recipient is not null
          and ((m.sender = auth.uid() and m.recipient = target) or (m.sender = target and m.recipient = auth.uid()))))
    and (newer_than is null or m.created_at > newer_than)
    and (older_than is null or m.created_at < older_than)
  order by m.created_at desc
  limit least(lim, 200);
$$;

-- Every chat you're in, newest activity first, with its last message and how many you haven't read.
create function public.my_chats() returns json
language sql stable set search_path = public as $$
  with threads as (
    select 'group'::text as kind, g.id from groups g where is_member(g.id, auth.uid())
    union all
    select 'plan', pl.id from plans pl
    where not pl.cancelled and pl.starts_at > now() - interval '12 hours' and in_plan_chat(pl.id, auth.uid())
    union
    select 'dm', x.other from (
      select case when m.sender = auth.uid() then m.recipient else m.sender end as other
      from messages m where m.recipient is not null and auth.uid() in (m.sender, m.recipient)
    ) x
    where not is_blocked(auth.uid(), x.other)
  ), inbox as (
    select t.kind, t.id, lm.body, lm.created_at, lm.sender,
           coalesce((select r.read_at from chat_reads r where r.user_id = auth.uid() and r.thread = t.kind || ':' || t.id), '-infinity') as read_at
    from threads t
    left join lateral (
      select m.body, m.created_at, m.sender from messages m
      where (t.kind = 'group' and m.group_id = t.id)
         or (t.kind = 'plan' and m.plan_id = t.id)
         or (t.kind = 'dm' and m.recipient is not null
             and ((m.sender = auth.uid() and m.recipient = t.id) or (m.sender = t.id and m.recipient = auth.uid())))
      order by m.created_at desc limit 1
    ) lm on true
  )
  select coalesce(json_agg(json_build_object(
    'kind', i.kind,
    'id', i.id,
    'person', case when i.kind = 'dm' then (select json_build_object('id', p.id, 'name', p.name, 'emoji', p.emoji, 'photo_path', p.photo_path, 'class_year', p.class_year) from profiles p where p.id = i.id) end,
    'group', case when i.kind = 'group' then (select json_build_object('id', g.id, 'name', g.name, 'emoji', g.emoji, 'photo_path', g.photo_path) from groups g where g.id = i.id) end,
    'plan', case when i.kind = 'plan' then (
      select json_build_object('id', pl.id, 'meal', pl.meal, 'starts_at', pl.starts_at,
        'host', (select json_build_object('id', h.id, 'name', h.name, 'emoji', h.emoji, 'photo_path', h.photo_path) from profiles h where h.id = pl.host),
        'group', (select json_build_object('id', g.id, 'name', g.name, 'emoji', g.emoji, 'photo_path', g.photo_path) from groups g where g.id = pl.group_id))
      from plans pl where pl.id = i.id) end,
    'last_body', i.body,
    'last_at', i.created_at,
    'last_sender', case when i.sender is null then null else (select json_build_object('id', p.id, 'name', p.name, 'emoji', p.emoji) from profiles p where p.id = i.sender) end,
    'unread', (select count(*) from messages m
               where m.sender <> auth.uid() and m.created_at > i.read_at
                 and ((i.kind = 'group' and m.group_id = i.id) or (i.kind = 'plan' and m.plan_id = i.id)
                      or (i.kind = 'dm' and m.recipient = auth.uid() and m.sender = i.id)))
  ) order by i.created_at desc nulls last), '[]'::json)
  from inbox i;
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

-- Phones' push tokens and the notification queue are for the server only.
revoke all on public.devices, public.push_queue, public.push_auth from authenticated;
-- Messages and reports can't be edited, and close friends are added or removed, never changed.
revoke update on public.close_friends, public.messages, public.message_reports from authenticated;
revoke delete on public.message_reports, public.notify_settings from authenticated;
-- Server only: these would let anyone send notifications or learn who marked whom as a close friend.
revoke execute on function public.friends_of(uuid), public.is_close(uuid, uuid), public.wants(uuid, text, uuid),
  public.queue_push(uuid[], text, text, jsonb, text, text) from authenticated;
