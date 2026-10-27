-- Demo data for the LOCAL test server only. Never run on Supabase.
-- Eight made-up students who befriend whoever signs up, accept invites, and
-- keep a few plans, check-ins and posts going relative to "now".

insert into auth.users (id, email) values
  ('00000000-0000-4000-a000-000000000001', 'demo.maya@dartmouth.edu'),
  ('00000000-0000-4000-a000-000000000002', 'demo.jordan@dartmouth.edu'),
  ('00000000-0000-4000-a000-000000000003', 'demo.priya@dartmouth.edu'),
  ('00000000-0000-4000-a000-000000000004', 'demo.sam@dartmouth.edu'),
  ('00000000-0000-4000-a000-000000000005', 'demo.alex@dartmouth.edu'),
  ('00000000-0000-4000-a000-000000000006', 'demo.theo@dartmouth.edu'),
  ('00000000-0000-4000-a000-000000000007', 'demo.nia@dartmouth.edu'),
  ('00000000-0000-4000-a000-000000000008', 'demo.leo@dartmouth.edu');

insert into public.profiles (id, email, name, class_year, emoji) values
  ('00000000-0000-4000-a000-000000000001', 'demo.maya@dartmouth.edu',   'Maya R.',   2029, '🌮'),
  ('00000000-0000-4000-a000-000000000002', 'demo.jordan@dartmouth.edu', 'Jordan K.', 2030, '🤽'),
  ('00000000-0000-4000-a000-000000000003', 'demo.priya@dartmouth.edu',  'Priya S.',  2030, '🚀'),
  ('00000000-0000-4000-a000-000000000004', 'demo.sam@dartmouth.edu',    'Sam O.',    2028, '🍕'),
  ('00000000-0000-4000-a000-000000000005', 'demo.alex@dartmouth.edu',   'Alex T.',   2030, '🥗'),
  ('00000000-0000-4000-a000-000000000006', 'demo.theo@dartmouth.edu',   'Theo W.',   2029, '🍜'),
  ('00000000-0000-4000-a000-000000000007', 'demo.nia@dartmouth.edu',    'Nia B.',    2030, '🧇'),
  ('00000000-0000-4000-a000-000000000008', 'demo.leo@dartmouth.edu',    'Leo M.',    2027, '🥩');

insert into public.friendships (requester, addressee, status)
select a.id, b.id, 'accepted'
from public.profiles a, public.profiles b
where a.email like 'demo.%' and b.email like 'demo.%' and a.id < b.id;

insert into public.groups (id, name, emoji, created_by) values
  ('00000000-0000-4000-b000-000000000001', 'Water Polo', '🤽', '00000000-0000-4000-a000-000000000002'),
  ('00000000-0000-4000-b000-000000000002', 'Rocket Team', '🚀', '00000000-0000-4000-a000-000000000003');
insert into public.group_members (group_id, user_id) values
  ('00000000-0000-4000-b000-000000000001', '00000000-0000-4000-a000-000000000004'),
  ('00000000-0000-4000-b000-000000000001', '00000000-0000-4000-a000-000000000006'),
  ('00000000-0000-4000-b000-000000000002', '00000000-0000-4000-a000-000000000005');

create function public.is_demo(u uuid) returns boolean language sql stable as $$
  select u::text like '00000000-0000-4000-a000-%';
$$;

-- When a real person signs up: five demo friends, one incoming request, one group and an invite to another,
-- and a message from Maya.
create function public.demo_welcome() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if is_demo(new.id) then return new; end if;
  insert into friendships (requester, addressee, status)
  select d.id, new.id, 'accepted' from profiles d
  where d.email in ('demo.maya@dartmouth.edu', 'demo.jordan@dartmouth.edu', 'demo.priya@dartmouth.edu',
                    'demo.sam@dartmouth.edu', 'demo.alex@dartmouth.edu');
  insert into friendships (requester, addressee, status)
  values ('00000000-0000-4000-a000-000000000008', new.id, 'pending');
  insert into group_members (group_id, user_id) values ('00000000-0000-4000-b000-000000000001', new.id);
  insert into group_members (group_id, user_id, status, invited_by)
  values ('00000000-0000-4000-b000-000000000002', new.id, 'invited', '00000000-0000-4000-a000-000000000003');
  insert into messages (sender, recipient, body, created_at)
  values ('00000000-0000-4000-a000-000000000001', new.id, 'hey! want to get dinner at Foco later?', now() - interval '20 minutes');
  insert into plan_members (plan_id, user_id, status)
  select id, new.id, 'invited' from plans where id = '00000000-0000-4000-c000-000000000002';
  return new;
end $$;
create trigger profiles_demo_welcome after insert on public.profiles
  for each row execute function public.demo_welcome();

-- Demo people say yes to friend requests and invites.
create function public.demo_accept_friend() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if is_demo(new.addressee) and new.status = 'pending' then
    update friendships set status = 'accepted' where requester = new.requester and addressee = new.addressee;
  end if;
  return new;
end $$;
create trigger friendships_demo_accept after insert on public.friendships
  for each row execute function public.demo_accept_friend();

create function public.demo_accept_invite() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if is_demo(new.user_id) and new.status = 'invited' then
    update plan_members set status = 'going', updated_at = now()
    where plan_id = new.plan_id and user_id = new.user_id;
  end if;
  return new;
end $$;
create trigger plan_members_demo_accept after insert on public.plan_members
  for each row execute function public.demo_accept_invite();

create function public.demo_accept_group_invite() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if is_demo(new.user_id) and new.status = 'invited' then
    update group_members set status = 'joined' where group_id = new.group_id and user_id = new.user_id;
  end if;
  return new;
end $$;
create trigger group_members_demo_accept after insert on public.group_members
  for each row execute function public.demo_accept_group_invite();

-- Rebuilds today's demo activity around the current time. Called when the dev server starts.
create function public.dev_refresh_demo() returns void
language plpgsql security definer set search_path = public as $$
declare
  today date := (now() at time zone 'America/New_York')::date;
  local_now timestamp := now() at time zone 'America/New_York';
  next_lunch timestamptz;
  next_dinner timestamptz;
  late timestamptz;
begin
  delete from plans where host::text like '00000000-0000-4000-a000-%';
  delete from checkins where is_demo(user_id);
  delete from posts where is_demo(author);
  delete from messages where is_demo(sender) and group_id is not null;

  next_lunch := ((case when local_now::time < '12:30' then today else today + 1 end) + time '12:30') at time zone 'America/New_York';
  next_dinner := ((case when local_now::time < '18:15' then today else today + 1 end) + time '18:15') at time zone 'America/New_York';
  late := ((case when local_now::time < '22:00' and local_now::time > '02:00' then today else today + 1 end) + time '22:00') at time zone 'America/New_York';

  insert into plans (id, host, meal, starts_at, note, audience) values
    ('00000000-0000-4000-c000-000000000001', '00000000-0000-4000-a000-000000000001', 'lunch', next_lunch, 'Grabbing a window table, come through', 'friends'),
    ('00000000-0000-4000-c000-000000000002', '00000000-0000-4000-a000-000000000003', 'dinner', next_dinner + interval '15 minutes', 'Window tables on the light side', 'invited');
  insert into plans (id, host, meal, starts_at, note, audience, group_id) values
    ('00000000-0000-4000-c000-000000000003', '00000000-0000-4000-a000-000000000002', 'dinner', next_dinner, 'Team dinner after practice — whole team', 'group', '00000000-0000-4000-b000-000000000001'),
    ('00000000-0000-4000-c000-000000000004', '00000000-0000-4000-a000-000000000005', 'late-night', late, 'Quesadilla run', 'friends', null);

  insert into plan_members (plan_id, user_id, status) values
    ('00000000-0000-4000-c000-000000000001', '00000000-0000-4000-a000-000000000004', 'going'),
    ('00000000-0000-4000-c000-000000000001', '00000000-0000-4000-a000-000000000007', 'maybe'),
    ('00000000-0000-4000-c000-000000000003', '00000000-0000-4000-a000-000000000004', 'going'),
    ('00000000-0000-4000-c000-000000000003', '00000000-0000-4000-a000-000000000006', 'going'),
    ('00000000-0000-4000-c000-000000000002', '00000000-0000-4000-a000-000000000005', 'going');
  insert into plan_members (plan_id, user_id, status)
  select '00000000-0000-4000-c000-000000000002', p.id, 'invited' from profiles p where not is_demo(p.id);

  insert into messages (sender, group_id, body, created_at) values
    ('00000000-0000-4000-a000-000000000002', '00000000-0000-4000-b000-000000000001', 'Team dinner tonight after practice, everyone in?', now() - interval '2 hours'),
    ('00000000-0000-4000-a000-000000000004', '00000000-0000-4000-b000-000000000001', 'in', now() - interval '110 minutes'),
    ('00000000-0000-4000-a000-000000000006', '00000000-0000-4000-b000-000000000001', 'Saving the big table on dark side', now() - interval '15 minutes');
  insert into messages (sender, plan_id, body, created_at) values
    ('00000000-0000-4000-a000-000000000005', '00000000-0000-4000-c000-000000000002', 'I''ll grab a table upstairs', now() - interval '30 minutes');

  insert into checkins (user_id, spot, open_to_join, started_at, expires_at) values
    ('00000000-0000-4000-a000-000000000004', 'Dark side', true, now() - interval '10 minutes', now() + interval '50 minutes'),
    ('00000000-0000-4000-a000-000000000002', 'Light side', true, now() - interval '25 minutes', now() + interval '35 minutes');
  insert into checkins (user_id, eta, started_at, expires_at) values
    ('00000000-0000-4000-a000-000000000003', now() + interval '25 minutes', now() - interval '5 minutes', now() + interval '45 minutes');

  insert into posts (id, author, kind, body, photo_path, meal, dish, served_on, created_at) values
    ('00000000-0000-4000-d000-000000000001', '00000000-0000-4000-a000-000000000006', 'photo', 'Pepper steak + brown rice from A9. Underrated.', '00000000-0000-4000-a000-000000000006/steak.jpg', 'dinner', 'Pepper Steak', today, now() - interval '40 minutes'),
    ('00000000-0000-4000-d000-000000000002', '00000000-0000-4000-a000-000000000001', 'photo', 'Built a stir fry bowl, extra sesame garlic', '00000000-0000-4000-a000-000000000001/stirfry.jpg', 'lunch', 'Stir Fry', today, now() - interval '3 hours'),
    ('00000000-0000-4000-d000-000000000003', '00000000-0000-4000-a000-000000000007', 'photo', 'Waffle + soft serve. No notes.', '00000000-0000-4000-a000-000000000007/waffle.jpg', 'breakfast', 'Waffles', today, now() - interval '7 hours'),
    ('00000000-0000-4000-d000-000000000004', '00000000-0000-4000-a000-000000000005', 'photo', 'Salad bar done right: farro, salmon, sesame ginger', '00000000-0000-4000-a000-000000000005/salad.jpg', 'lunch', 'Salad Bar', today, now() - interval '2 hours'),
    ('00000000-0000-4000-d000-000000000005', '00000000-0000-4000-a000-000000000003', 'idea', 'Cutting hack: griddled chicken strips from the Grill on top of a Farmstand salad. Easy 40g protein.', null, null, null, today, now() - interval '5 hours'),
    ('00000000-0000-4000-d000-000000000006', '00000000-0000-4000-a000-000000000004', 'idea', 'Ask Hearth for a pizza with the pesto cream sauce from the pasta station. They''ll do it.', null, null, null, today, now() - interval '1 day'),
    ('00000000-0000-4000-d000-000000000007', '00000000-0000-4000-a000-000000000008', 'complaint', 'Late-night quesadilla line was 25 minutes on Thursday. A second grill would fix it.', null, 'late-night', 'Quesadilla', today, now() - interval '9 hours'),
    ('00000000-0000-4000-d000-000000000008', '00000000-0000-4000-a000-000000000002', 'complaint', 'Out of chocolate milk by 12:45 again.', null, 'lunch', null, today, now() - interval '4 hours');

  insert into post_votes (post_id, user_id)
  select '00000000-0000-4000-d000-000000000001'::uuid, id from profiles where is_demo(id) and id::text < '00000000-0000-4000-a000-000000000007'
  union all
  select '00000000-0000-4000-d000-000000000002'::uuid, id from profiles where is_demo(id) and id::text < '00000000-0000-4000-a000-000000000004'
  union all
  select '00000000-0000-4000-d000-000000000004'::uuid, id from profiles where is_demo(id) and id::text < '00000000-0000-4000-a000-000000000003'
  union all
  select '00000000-0000-4000-d000-000000000005'::uuid, id from profiles where is_demo(id) and id::text < '00000000-0000-4000-a000-000000000006'
  union all
  select '00000000-0000-4000-d000-000000000007'::uuid, id from profiles where is_demo(id) and id::text < '00000000-0000-4000-a000-000000000005'
  on conflict do nothing;
end $$;

revoke execute on function public.dev_refresh_demo() from public, anon, authenticated;
