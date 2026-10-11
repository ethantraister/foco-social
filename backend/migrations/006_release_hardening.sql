-- 11 Oct 2026: tightening before release. Run once on the live project, after 005 (schema.sql already includes it).

-- 1. Other people's email addresses aren't readable. The app never shows them, and search by NetID still works
--    because search_people() reads the column on the server.
revoke select on public.profiles from authenticated;
grant select (id, name, class_year, emoji, photo_path, created_at) on public.profiles to authenticated;

create or replace function public.search_people(q text)
returns table (id uuid, name text, emoji text, photo_path text, class_year int, relation text)
language sql stable security definer set search_path = public as $$
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
    and (p.name ilike '%' || trim(q) || '%' or split_part(p.email, '@', 1) ilike trim(q) || '%')
  order by p.name
  limit 25;
$$;
revoke execute on function public.search_people(text) from public, anon;
grant execute on function public.search_people(text) to authenticated;

-- 2. A post's photo has to be in its author's own folder (the same rule profile photos follow).
--    "not valid" skips rows that already exist; every new post is checked.
alter table public.posts drop constraint if exists posts_photo_own_folder;
alter table public.posts add constraint posts_photo_own_folder
  check (photo_path is null or photo_path like author::text || '/%') not valid;

-- 3. At most 20 posts a day per person, so one account can't flood the feed.
drop policy if exists posts_create on public.posts;
create policy posts_create on public.posts for insert to authenticated
  with check (author = auth.uid() and hidden = false
              and (select count(*) from public.posts p
                   where p.author = auth.uid() and p.created_at > now() - interval '1 day') < 20);

-- 4. A host can't move a plan into a group they aren't in.
drop policy if exists plans_edit on public.plans;
create policy plans_edit on public.plans for update to authenticated
  using (host = auth.uid())
  with check (host = auth.uid() and (group_id is null or is_member(group_id, auth.uid())));

-- 5. People can list their own photos, so the app can delete them: when a post is deleted, when a profile photo
--    is replaced, and before an account is deleted (deleting through Storage needs read access to the file).
drop policy if exists "meal photos: see own" on storage.objects;
create policy "meal photos: see own" on storage.objects for select to authenticated
  using (bucket_id = 'meal-photos' and (storage.foldername(name))[1] = auth.uid()::text);
