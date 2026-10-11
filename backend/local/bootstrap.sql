-- Local stand-in for the parts of Supabase that schema.sql relies on:
-- the auth schema, auth.uid()/auth.jwt(), and the anon/authenticated roles PostgREST switches into.
-- Never run this on a real Supabase project; Supabase provides all of it.

create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create role authenticator login password 'authenticator' noinherit;
grant anon, authenticated, service_role to authenticator;

create schema auth;
grant usage on schema auth to anon, authenticated, service_role;

create table auth.users (
  id uuid primary key,
  email text unique not null,
  created_at timestamptz not null default now()
);

create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
$$;

create function auth.uid() returns uuid language sql stable as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid;
$$;

grant usage on schema public to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema public to service_role;
alter default privileges in schema public grant select, insert, update, delete on tables to service_role;
