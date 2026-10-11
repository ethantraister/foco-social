// FoCo Social: once a day, email Dartmouth Dining every food request students sent in the app.
// Called by a pg_cron job (see backend/migrations/003_daily_requests_cron.sql).
//
// Secrets (Supabase → Edge Functions → Secrets):
//   CRON_SECRET          shared with the cron job so nobody else can trigger emails
//   GMAIL_USER           focosocial.app@gmail.com
//   GMAIL_APP_PASSWORD   Google app password (Ethan sets this himself)
//   DIGEST_TO            who gets the email; comma-separated. Defaults to GMAIL_USER until Dining agrees.
//
// ?preview=1 returns the email without sending it or marking anything as sent.
// The cron job fires at 11:00 and 12:00 UTC; only the run that lands at 7 AM New York time sends,
// so the email stays at 7 AM through daylight-saving changes. ?now=1 skips that check.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import nodemailer from "npm:nodemailer@6.9.15";

type Row = { food: string; students: number; meals: Record<string, number> | null; notes: string[] | null; ids: string[] };

const mealNames: Record<string, string> = { breakfast: "breakfast", lunch: "lunch", dinner: "dinner", "late-night": "late night", any: "any meal" };

function escape(s: string) {
  return s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
}

function compose(rows: Row[], day: string) {
  const total = rows.reduce((n, r) => n + r.ids.length, 0);
  const subject = `FoCo food requests from students, ${day} (${total} request${total === 1 ? "" : "s"})`;
  const intro = `Here's what students asked '53 Commons to serve, collected through the FoCo Social app since the last email. Each line counts students, not names.`;
  const footer = `Sent automatically once a day by FoCo Social, a student-made app. It isn't run by Dartmouth Dining. Reply to this email to reach the student who runs it.`;

  const lines = rows.map((r, i) => {
    const meals = Object.entries(r.meals ?? {}).sort((a, b) => b[1] - a[1]).map(([m, n]) => `${mealNames[m] ?? m} ×${n}`).join(", ");
    const notes = (r.notes ?? []).map((n) => `“${n}”`).join("; ");
    return { title: `${i + 1}. ${r.food}: ${r.students} student${r.students === 1 ? "" : "s"}`, meals, notes };
  });

  const text = [intro, "", ...lines.flatMap((l) => [l.title, `   Meals: ${l.meals}`, ...(l.notes ? [`   Notes: ${l.notes}`] : []), ""]), footer].join("\n");
  const html = `<p>${escape(intro)}</p><ol>${lines.map((l) =>
    `<li><b>${escape(l.title.replace(/^\d+\. /, ""))}</b><br><span style="color:#555">Meals: ${escape(l.meals)}</span>${l.notes ? `<br><span style="color:#555">Notes: ${escape(l.notes)}</span>` : ""}</li>`
  ).join("")}</ol><p style="color:#777;font-size:13px">${escape(footer)}</p>`;
  return { subject, text, html, total };
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("CRON_SECRET");
  if (!secret || req.headers.get("x-cron-secret") !== secret) return new Response("forbidden", { status: 403 });

  const params = new URL(req.url).searchParams;
  const nyHour = new Date().toLocaleString("en-US", { timeZone: "America/New_York", hour: "numeric", hour12: false });
  if (!params.get("now") && !params.get("preview") && nyHour !== "7") return Response.json({ sent: false, reason: `not 7 AM in Hanover (hour ${nyHour})` });

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data, error } = await db.rpc("request_digest");
  if (error) return new Response(error.message, { status: 500 });
  const rows = (data ?? []) as Row[];
  if (rows.length === 0) return Response.json({ sent: false, reason: "no new requests" });

  const day = new Date().toLocaleDateString("en-US", { timeZone: "America/New_York", weekday: "short", month: "short", day: "numeric" });
  const email = compose(rows, day);
  if (params.get("preview")) return Response.json({ preview: true, ...email });

  const user = Deno.env.get("GMAIL_USER")!;
  const transport = nodemailer.createTransport({
    host: "smtp.gmail.com",
    port: 465,
    secure: true,
    auth: { user, pass: Deno.env.get("GMAIL_APP_PASSWORD")! },
  });
  const to = Deno.env.get("DIGEST_TO") || user;
  await transport.sendMail({ from: `"FoCo Social" <${user}>`, to, subject: email.subject, text: email.text, html: email.html });

  const ids = rows.flatMap((r) => r.ids);
  const { error: markError } = await db.from("food_requests").update({ sent_at: new Date().toISOString() }).in("id", ids);
  if (markError) return new Response(`sent, but couldn't mark as sent: ${markError.message}`, { status: 500 });
  return Response.json({ sent: true, to, foods: rows.length, requests: email.total });
});
