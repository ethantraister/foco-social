-- 11 Oct 2026: each group has one owner (its creator to start). Only the owner can rename or delete the group,
-- remove members, or hand ownership to another member. Anyone in the group can still add people.
-- Run once on the live project (schema.sql already includes it).

-- The owner can rename the group but can't change who owns it with a plain update; transfer_group() does that.
drop policy if exists groups_edit on public.groups;
create policy groups_edit on public.groups for update to authenticated
  using (created_by = auth.uid()) with check (created_by = auth.uid());

-- Members can leave; the owner can remove anyone else. The owner can't leave without transferring or deleting first.
drop policy if exists group_members_leave on public.group_members;
create policy group_members_leave on public.group_members for delete to authenticated
  using (
    (user_id = auth.uid() and not exists (select 1 from groups g where g.id = group_id and g.created_by = auth.uid()))
    or (user_id <> auth.uid() and exists (select 1 from groups g where g.id = group_id and g.created_by = auth.uid()))
  );

create or replace function public.transfer_group(g uuid, new_owner uuid) returns void
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
revoke all on function public.transfer_group(uuid, uuid) from public, anon;
grant execute on function public.transfer_group(uuid, uuid) to authenticated;

-- If the owner deletes their account, the longest-standing member takes over; an empty group is deleted.
create or replace function public.reassign_group_owner() returns trigger
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
drop trigger if exists group_owner_left on public.group_members;
create trigger group_owner_left after delete on public.group_members
  for each row execute function public.reassign_group_owner();
