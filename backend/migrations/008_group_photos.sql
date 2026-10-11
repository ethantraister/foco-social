-- 11 Oct 2026: group photos. A group can have a photo (camera or camera roll) instead of an emoji;
-- without one the app shows the group's initials. Only the owner can change it (groups_edit already says so).
-- Run once on the live project, BEFORE installing a build from 11 Oct evening or later (the app asks for photo_path).
-- schema.sql already includes it.

alter table public.groups add column if not exists photo_path text;

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

-- Plans posted to a group carry its photo.
create or replace function public.together(window_hours int default 36)
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

create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  -- The app deletes everything in your photo folder first, including photos you set for groups;
  -- those groups go back to showing their initials instead of a broken image.
  update groups set photo_path = null where photo_path like auth.uid()::text || '/%';
  delete from auth.users where id = auth.uid();
end $$;
