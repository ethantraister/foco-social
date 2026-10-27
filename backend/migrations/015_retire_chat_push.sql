-- 27 Oct 2026: chats left the app in build 1.1 (5), and every tester is now on build 10. A message written straight
-- to the database still notified the people it was for, who have no way to read it (and nothing limited how many).
-- That stops here. The chat tables stay, and are deleted with each account as before.
-- Food requests are off in the app too, so their counts can't be called. Safe to run twice.
-- Run once on the live project (schema.sql already includes it).

drop trigger if exists messages_push on public.messages;
revoke execute on function public.popular_requests(int) from authenticated;
