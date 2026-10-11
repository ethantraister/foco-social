-- 11 Oct 2026: a friend request or a plan reply can't change hands.
-- Before this, whoever received a friend request could rewrite its sender to anyone and accept it,
-- making a fake friendship that showed them that person's check-ins. Replies get the same lock.
-- Updates can still change the status (accept a request, answer Going / Maybe / Can't).
-- Run once on the live project (schema.sql already includes it). Every app build works before and after.

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
