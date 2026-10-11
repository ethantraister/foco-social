-- 11 Oct 2026: profile photos. A person can use a photo (camera roll or camera) instead of an emoji.
-- Photos go in the existing meal-photos bucket under the person's own folder, which its upload policy already allows.
-- Run once on the live project (schema.sql already includes it).

alter table public.profiles add column if not exists photo_path text
  check (photo_path is null or photo_path like id::text || '/%');

-- These return tables, and the columns changed, so they're dropped and recreated.
drop function if exists public.my_people();
drop function if exists public.search_people(text);
drop function if exists public.feed(text, date, text, int);

create or replace function public.my_people()
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

create or replace function public.search_people(q text)
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
  where p.id <> auth.uid()
    and not is_blocked(auth.uid(), p.id)
    and char_length(trim(q)) >= 2
    and (p.name ilike '%' || trim(q) || '%' or split_part(p.email, '@', 1) ilike trim(q) || '%')
  order by p.name
  limit 25;
$$;

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
        'group', (select json_build_object('id', g.id, 'name', g.name, 'emoji', g.emoji) from groups g where g.id = pl.group_id),
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

create or replace function public.feed(kind_filter text default null, day date default null, sort text default 'new', lim int default 60)
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

revoke execute on function public.my_people(), public.search_people(text), public.together(int), public.feed(text, date, text, int) from public, anon;
grant execute on function public.my_people(), public.search_people(text), public.together(int), public.feed(text, date, text, int) to authenticated;
