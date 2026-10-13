-- 13 Oct 2026: FoCo Social build 2.
--   • Close friends: going soon / at FoCo can be shared with close friends only.
--   • "Me too" / "On my way" remember who you're joining, so they can be told.
--   • Group invites: being added to a group is an invite you accept or decline.
--   • Take back an RSVP: an invite you answered can go back to unanswered.
--   • Chat: group chats, a chat for each meal plan, and messages between friends.
--   • Push notifications, with per-person settings.
-- Run once on the live project (schema.sql already includes it). Replace ANON_KEY_VALUE with the project's
-- anon (public) key first, as in 003. Build 1 keeps working: adding someone to a group just becomes an invite.

-- ───────────────────────── small helpers ─────────────────────────

create or replace function public.first_name(full_name text) returns text
language sql immutable as $$ select split_part(trim(full_name), ' ', 1) $$;

-- "6:30 PM", Hanover time.
create or replace function public.clock(t timestamptz) returns text
language sql stable as $$ select to_char(t at time zone 'America/New_York', 'FMHH12:MI AM') $$;

-- "Tue 6:30 PM"
create or replace function public.day_clock(t timestamptz) returns text
language sql stable as $$ select to_char(t at time zone 'America/New_York', 'Dy FMHH12:MI AM') $$;

create or replace function public.friends_of(u uuid) returns setof uuid
language sql stable security definer set search_path = public as $$
  select case when requester = u then addressee else requester end
  from friendships where status = 'accepted' and u in (requester, addressee);
$$;

-- ───────────────────────── close friends ─────────────────────────

create table if not exists public.close_friends (
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  friend_id   uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, friend_id),
  check (user_id <> friend_id)
);
alter table public.close_friends enable row level security;

drop policy if exists close_friends_read on public.close_friends;
create policy close_friends_read on public.close_friends for select to authenticated
  using (user_id = auth.uid());
drop policy if exists close_friends_add on public.close_friends;
create policy close_friends_add on public.close_friends for insert to authenticated
  with check (user_id = auth.uid() and are_friends(user_id, friend_id));
drop policy if exists close_friends_remove on public.close_friends;
create policy close_friends_remove on public.close_friends for delete to authenticated
  using (user_id = auth.uid());

-- For the server only: did `owner` mark `other` as a close friend?
create or replace function public.is_close(owner uuid, other uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from close_friends where user_id = owner and friend_id = other);
$$;

-- For policies: did `owner` mark you as a close friend? (Never tells you about anyone else.)
create or replace function public.marked_me_close(owner uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from close_friends where user_id = owner and friend_id = auth.uid());
$$;

-- Unfriending clears close-friend marks both ways.
create or replace function public.forget_close_friends() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from close_friends
  where (user_id = old.requester and friend_id = old.addressee) or (user_id = old.addressee and friend_id = old.requester);
  return old;
end $$;
drop trigger if exists friendships_forget_close on public.friendships;
create trigger friendships_forget_close after delete on public.friendships
  for each row execute function public.forget_close_friends();

-- ───────────────────────── check-ins: audience, joining, notify ─────────────────────────

alter table public.checkins add column if not exists audience text not null default 'friends';
alter table public.checkins drop constraint if exists checkins_audience_check;
alter table public.checkins add constraint checkins_audience_check check (audience in ('friends', 'close'));
-- Set by "Me too" / "On my way": the friend you're joining, who gets told.
alter table public.checkins add column if not exists joining uuid references public.profiles (id) on delete set null;
-- "Going soon" out loud: friends get a notification. Quiet is the default.
alter table public.checkins add column if not exists notify boolean not null default false;

drop policy if exists checkins_read on public.checkins;
create policy checkins_read on public.checkins for select to authenticated
  using (user_id = auth.uid()
         or (are_friends(user_id, auth.uid()) and not is_blocked(user_id, auth.uid())
             and (audience = 'friends' or marked_me_close(user_id))));

-- ───────────────────────── group invites ─────────────────────────

alter table public.group_members add column if not exists status text not null default 'joined';
alter table public.group_members drop constraint if exists group_members_status_check;
alter table public.group_members add constraint group_members_status_check check (status in ('invited', 'joined'));
-- Not a foreign key on purpose: a second link from group_members to profiles would make build 1's
-- group_members(..., profiles(...)) query ambiguous, and its groups would disappear.
alter table public.group_members add column if not exists invited_by uuid;

-- Members are people who joined; an invite doesn't count until it's accepted.
create or replace function public.is_member(g uuid, u uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from group_members where group_id = g and user_id = u and status = 'joined');
$$;

-- In the group or invited to it: enough to see the group's name and who's in it.
create or replace function public.in_group(g uuid, u uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from group_members where group_id = g and user_id = u);
$$;

-- Adding someone else is always an invite. (The owner's own row, made with the group, is joined.)
create or replace function public.group_member_defaults() returns trigger
language plpgsql set search_path = public as $$
begin
  if auth.uid() is not null and new.user_id <> auth.uid() then
    new.status := 'invited';
    new.invited_by := auth.uid();
    new.role := 'member';
  end if;
  return new;
end $$;
drop trigger if exists group_members_defaults on public.group_members;
create trigger group_members_defaults before insert on public.group_members
  for each row execute function public.group_member_defaults();

-- An accepted invite only changes its status (and when you joined).
create or replace function public.keep_group_member() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.group_id is distinct from old.group_id or new.user_id is distinct from old.user_id then
    raise exception 'A group membership can''t move to another group or person';
  end if;
  new.invited_by := old.invited_by;   -- who sent the invite can't be rewritten
  if old.status = 'invited' and new.status = 'joined' then new.joined_at := now(); end if;
  return new;
end $$;
drop trigger if exists group_members_keep on public.group_members;
create trigger group_members_keep before update on public.group_members
  for each row execute function public.keep_group_member();

drop policy if exists groups_read on public.groups;
create policy groups_read on public.groups for select to authenticated
  using (in_group(id, auth.uid()) or created_by = auth.uid());

drop policy if exists group_members_read on public.group_members;
create policy group_members_read on public.group_members for select to authenticated
  using (in_group(group_id, auth.uid()));

drop policy if exists group_members_add on public.group_members;
create policy group_members_add on public.group_members for insert to authenticated
  with check (role = 'member' and status = 'invited' and invited_by = auth.uid()
              and is_member(group_id, auth.uid()) and not is_blocked(auth.uid(), user_id));

drop policy if exists group_members_accept on public.group_members;
create policy group_members_accept on public.group_members for update to authenticated
  using (user_id = auth.uid() and status = 'invited')
  with check (user_id = auth.uid() and status = 'joined' and role = 'member');

-- The longest-standing member who actually joined takes over; with nobody left, the group goes.
create or replace function public.reassign_group_owner() returns trigger
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

-- ───────────────────────── plans: take back an RSVP ─────────────────────────

alter table public.plan_members add column if not exists was_invited boolean not null default false;
update public.plan_members set was_invited = true where status = 'invited' and not was_invited;

create or replace function public.plan_member_defaults() returns trigger
language plpgsql set search_path = public as $$
begin
  new.was_invited := new.status = 'invited';
  return new;
end $$;
drop trigger if exists plan_members_defaults on public.plan_members;
create trigger plan_members_defaults before insert on public.plan_members
  for each row execute function public.plan_member_defaults();

create or replace function public.keep_plan_member() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.plan_id is distinct from old.plan_id or new.user_id is distinct from old.user_id then
    raise exception 'A plan reply can''t move to another plan or person';
  end if;
  new.was_invited := old.was_invited;
  return new;
end $$;

-- Answer Going / Maybe / Can't, or (if you were invited) go back to not having answered.
drop policy if exists plan_members_respond on public.plan_members;
create policy plan_members_respond on public.plan_members for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and (status in ('going', 'maybe', 'declined') or (status = 'invited' and was_invited)));

-- ───────────────────────── chat ─────────────────────────

create table if not exists public.messages (
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
create index if not exists messages_group on public.messages (group_id, created_at desc) where group_id is not null;
create index if not exists messages_plan on public.messages (plan_id, created_at desc) where plan_id is not null;
create index if not exists messages_dm on public.messages (least(sender, recipient), greatest(sender, recipient), created_at desc) where recipient is not null;

-- A plan's chat is for the host and everyone invited, going, or maybe.
create or replace function public.in_plan_chat(p uuid, u uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from plans pl
    where pl.id = p and not is_blocked(pl.host, u)
      and (pl.host = u or exists (select 1 from plan_members m where m.plan_id = p and m.user_id = u
                                                              and m.status in ('going', 'maybe', 'invited')))
  );
$$;

create table if not exists public.message_reports (
  message_id  uuid not null references public.messages (id) on delete cascade,
  reporter    uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  reason      text check (char_length(reason) <= 200),
  created_at  timestamptz not null default now(),
  primary key (message_id, reporter)
);

-- When you last read each chat ('group:<id>', 'plan:<id>', 'dm:<their id>'), for unread counts.
create table if not exists public.chat_reads (
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  thread      text not null check (thread ~ '^(group|plan|dm):[0-9a-f-]{36}$'),
  read_at     timestamptz not null default now(),
  primary key (user_id, thread)
);

alter table public.messages        enable row level security;
alter table public.message_reports enable row level security;
alter table public.chat_reads      enable row level security;

drop policy if exists messages_read on public.messages;
create policy messages_read on public.messages for select to authenticated
  using (not is_blocked(sender, auth.uid()) and (
    (group_id is not null and is_member(group_id, auth.uid()))
    or (plan_id is not null and in_plan_chat(plan_id, auth.uid()))
    or (recipient is not null and auth.uid() in (sender, recipient))
  ));
-- Messages between friends only; at most 200 an hour per person.
drop policy if exists messages_send on public.messages;
create policy messages_send on public.messages for insert to authenticated
  with check (sender = auth.uid() and (
      (group_id is not null and is_member(group_id, auth.uid()))
      or (plan_id is not null and in_plan_chat(plan_id, auth.uid()))
      or (recipient is not null and are_friends(sender, recipient) and not is_blocked(sender, recipient)))
    and (select count(*) from public.messages m where m.sender = auth.uid() and m.created_at > now() - interval '1 hour') < 200);
drop policy if exists messages_unsend on public.messages;
create policy messages_unsend on public.messages for delete to authenticated
  using (sender = auth.uid());

drop policy if exists message_reports_add on public.message_reports;
create policy message_reports_add on public.message_reports for insert to authenticated with check (reporter = auth.uid());
drop policy if exists message_reports_read on public.message_reports;
create policy message_reports_read on public.message_reports for select to authenticated using (reporter = auth.uid());

drop policy if exists chat_reads_own on public.chat_reads;
create policy chat_reads_own on public.chat_reads for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- One chat's messages, newest first. `newer_than` fetches only what's new; `older_than` pages back.
create or replace function public.chat_messages(kind text, target uuid, newer_than timestamptz default null,
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
create or replace function public.my_chats() returns json
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

-- ───────────────────────── push notifications ─────────────────────────

-- Each phone's push token. Only the server reads these; the app registers through register_device().
create table if not exists public.devices (
  token       text primary key,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  sandbox     boolean not null default false,
  updated_at  timestamptz not null default now()
);
alter table public.devices enable row level security;

create or replace function public.register_device(device_token text, use_sandbox boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if device_token !~ '^[0-9a-f]{32,200}$' then raise exception 'That isn''t a device token'; end if;
  insert into devices (token, user_id, sandbox, updated_at) values (device_token, auth.uid(), use_sandbox, now())
  on conflict (token) do update set user_id = excluded.user_id, sandbox = excluded.sandbox, updated_at = now();
end $$;

create or replace function public.unregister_device(device_token text) returns void
language sql security definer set search_path = public as $$
  delete from devices where token = device_token and user_id = auth.uid();
$$;

-- What each person wants to hear about. No row means the defaults.
create table if not exists public.notify_settings (
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
drop policy if exists notify_settings_own on public.notify_settings;
create policy notify_settings_own on public.notify_settings for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- For the server only: does `u` want this kind of notification about `about`?
create or replace function public.wants(u uuid, what text, about uuid default null) returns boolean
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
create table if not exists public.push_queue (
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
create table if not exists public.push_auth (
  id          int primary key default 1 check (id = 1),
  token       text not null,
  issued_at   timestamptz not null
);
alter table public.push_auth enable row level security;

create or replace function public.queue_push(recipients uuid[], title text, body text,
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

-- Hands each queued notification to the push Edge Function. A notification problem never blocks what you were doing.
create or replace function public.deliver_push() returns trigger
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
drop trigger if exists push_queue_deliver on public.push_queue;
create trigger push_queue_deliver after insert on public.push_queue
  for each row execute function public.deliver_push();

-- Going soon (out loud), getting to FoCo, and joining a friend.
create or replace function public.push_checkin() returns trigger
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
drop trigger if exists checkins_push on public.checkins;
create trigger checkins_push after insert or update on public.checkins
  for each row execute function public.push_checkin();

-- Invites, people saying they're coming, and team meals.
create or replace function public.push_plan_member() returns trigger
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
drop trigger if exists plan_members_push on public.plan_members;
create trigger plan_members_push after insert or update on public.plan_members
  for each row execute function public.push_plan_member();

create or replace function public.push_plan() returns trigger
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
drop trigger if exists plans_push on public.plans;
create trigger plans_push after insert or update on public.plans
  for each row execute function public.push_plan();

create or replace function public.push_group_invite() returns trigger
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
drop trigger if exists group_members_push on public.group_members;
create trigger group_members_push after insert on public.group_members
  for each row execute function public.push_group_invite();

create or replace function public.push_message() returns trigger
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
drop trigger if exists messages_push on public.messages;
create trigger messages_push after insert on public.messages
  for each row execute function public.push_message();

-- ───────────────────────── read models ─────────────────────────

drop function if exists public.my_people();
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

create or replace function public.together(window_hours int default 36)
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

-- ───────────────────────── permissions ─────────────────────────

revoke all on public.close_friends, public.messages, public.message_reports, public.chat_reads,
              public.devices, public.notify_settings, public.push_queue, public.push_auth from anon, authenticated;
grant select, insert, delete on public.close_friends to authenticated;
grant select, insert, delete on public.messages to authenticated;
grant select, insert on public.message_reports to authenticated;
grant select, insert, update, delete on public.chat_reads to authenticated;
grant select, insert, update on public.notify_settings to authenticated;
grant select, insert, update, delete on public.devices, public.push_queue, public.push_auth to service_role;

revoke execute on function public.first_name(text), public.clock(timestamptz), public.day_clock(timestamptz),
  public.friends_of(uuid), public.is_close(uuid, uuid), public.marked_me_close(uuid), public.forget_close_friends(),
  public.is_member(uuid, uuid), public.in_group(uuid, uuid), public.group_member_defaults(), public.keep_group_member(),
  public.reassign_group_owner(), public.plan_member_defaults(), public.keep_plan_member(), public.in_plan_chat(uuid, uuid),
  public.chat_messages(text, uuid, timestamptz, timestamptz, int), public.my_chats(),
  public.register_device(text, boolean), public.unregister_device(text), public.wants(uuid, text, uuid),
  public.queue_push(uuid[], text, text, jsonb, text, text), public.deliver_push(), public.push_checkin(),
  public.push_plan_member(), public.push_plan(), public.push_group_invite(), public.push_message(),
  public.my_people(), public.together(int)
  from public, anon;
-- Policies call these as the signed-in user; the app calls the rest.
grant execute on function public.first_name(text), public.clock(timestamptz), public.day_clock(timestamptz),
  public.marked_me_close(uuid), public.is_member(uuid, uuid), public.in_group(uuid, uuid), public.in_plan_chat(uuid, uuid),
  public.chat_messages(text, uuid, timestamptz, timestamptz, int), public.my_chats(),
  public.register_device(text, boolean), public.unregister_device(text),
  public.my_people(), public.together(int)
  to authenticated;
-- Server only: these would let anyone send notifications or learn who marked whom as a close friend.
revoke execute on function public.friends_of(uuid), public.is_close(uuid, uuid), public.wants(uuid, text, uuid),
  public.queue_push(uuid[], text, text, jsonb, text, text) from authenticated;
