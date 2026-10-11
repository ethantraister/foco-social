-- 10 Oct 2026: "Heading to FoCo soon". Run once on the live project (schema.sql already includes it).
alter table public.checkins add column if not exists eta timestamptz;

create or replace function public.together(window_hours int default 36)
returns json
language sql stable set search_path = public as $$
  select json_build_object(
    'checkins', coalesce((
      select json_agg(json_build_object(
        'user', json_build_object('id', p.id, 'name', p.name, 'emoji', p.emoji, 'class_year', p.class_year),
        'spot', c.spot, 'open_to_join', c.open_to_join, 'eta', c.eta,
        'started_at', c.started_at, 'expires_at', c.expires_at) order by c.started_at desc)
      from checkins c join profiles p on p.id = c.user_id
      where c.expires_at > now()), '[]'::json),
    'plans', coalesce((
      select json_agg(json_build_object(
        'id', pl.id, 'meal', pl.meal, 'starts_at', pl.starts_at, 'note', pl.note,
        'audience', pl.audience, 'cancelled', pl.cancelled,
        'group', (select json_build_object('id', g.id, 'name', g.name, 'emoji', g.emoji) from groups g where g.id = pl.group_id),
        'host', (select json_build_object('id', h.id, 'name', h.name, 'emoji', h.emoji, 'class_year', h.class_year) from profiles h where h.id = pl.host),
        'members', coalesce((
          select json_agg(json_build_object(
            'user', json_build_object('id', u.id, 'name', u.name, 'emoji', u.emoji, 'class_year', u.class_year),
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
