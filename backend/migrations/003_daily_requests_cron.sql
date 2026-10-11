-- 10 Oct 2026: run the daily-requests Edge Function every morning.
-- Replace CRON_SECRET_VALUE with the function's CRON_SECRET, and ANON_KEY_VALUE with the project's anon (public) key, before running.
-- The anon key only gets past Supabase's JWT check on the function; the secret is what authorizes sending.
create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.unschedule('daily-food-requests') where exists (select 1 from cron.job where jobname = 'daily-food-requests');
select cron.schedule(
  'daily-food-requests',
  '0 11,12 * * *',  -- UTC; the function only sends at 7 AM America/New_York
  $$ select net.http_post(
       url := 'https://nfvzzxnqnogmhmiluszg.supabase.co/functions/v1/daily-requests',
       headers := jsonb_build_object('Content-Type', 'application/json',
                                  'Authorization', 'Bearer ANON_KEY_VALUE',
                                  'x-cron-secret', 'CRON_SECRET_VALUE'),
       body := '{}'::jsonb
     ) $$
);
