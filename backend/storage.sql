-- FoCo Social — photo storage (Supabase only; run after schema.sql).
-- Photos are public to read (so image URLs work in the feed) but each person
-- can only write inside their own folder: meal-photos/<their user id>/...

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('meal-photos', 'meal-photos', true, 5242880, array['image/jpeg'])
on conflict (id) do nothing;

create policy "meal photos: upload to own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'meal-photos' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "meal photos: delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'meal-photos' and (storage.foldername(name))[1] = auth.uid()::text);

-- Listing your own folder lets the app delete your photos (deleting through Storage needs read access to the file):
-- when a post is deleted, when a profile photo is replaced, and before an account is deleted.
create policy "meal photos: see own" on storage.objects for select to authenticated
  using (bucket_id = 'meal-photos' and (storage.foldername(name))[1] = auth.uid()::text);
