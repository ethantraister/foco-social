-- 19 Oct 2026: notifications say FOCO, the way students write it. Only the wording changes.
-- Run once on the live project (schema.sql already includes it).

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
                       case when new.eta is null then 'At FOCO now' else 'At FOCO around ' || clock(new.eta) end,
                       '{"tab": "together"}', null, 'join');
  end if;

  select array_agg(f) into whom from friends_of(new.user_id) f
  where f is distinct from new.joining and not is_blocked(f, new.user_id)
    and (new.audience = 'friends' or is_close(new.user_id, f))
    and wants(f, case when new.eta is null then 'arrivals' else 'going' end, new.user_id);

  -- At most one "going" and one "at FOCO" notification per person every 20 minutes, however often they tap.
  if new.eta is not null and new.notify
     and not exists (select 1 from push_queue q where q.sender = new.user_id and q.kind = 'going' and q.created_at > now() - interval '20 minutes') then
    perform queue_push(whom, who || ' is going to FOCO', 'Around ' || clock(new.eta) || coalesce(' · ' || new.spot, ''),
                       '{"tab": "together"}', null, 'going');
  elsif new.eta is null
     and not exists (select 1 from push_queue q where q.sender = new.user_id and q.kind = 'arrival' and q.created_at > now() - interval '20 minutes') then
    perform queue_push(whom, who || ' is at FOCO', coalesce(new.spot, 'Just got there'), '{"tab": "together"}', null, 'arrival');
  end if;
  return new;
end $$;
