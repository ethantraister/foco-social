-- 11 Oct 2026: people search matches names only (no one searches by NetID).
-- It no longer reads the email column, so it goes back to running as the caller (security invoker),
-- which means every row it returns has to pass the profiles policies like any other read.
-- Run once on the live project, after 006 (schema.sql already includes it).

create or replace function public.search_people(q text)
returns table (id uuid, name text, emoji text, photo_path text, class_year int, relation text)
language sql stable security invoker set search_path = public as $$
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
revoke execute on function public.search_people(text) from public, anon;
grant execute on function public.search_people(text) to authenticated;
