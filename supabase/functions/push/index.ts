// Foco app: sends push notifications through Apple (APNs).
// The database queues each notification in push_queue and calls this function with its id
// (see deliver_push() in backend/migrations/010_social_v2.sql). Each one is sent once: the first call
// stamps sent_at, so calling again with the same id does nothing.
//
// Secrets (Supabase → Edge Functions → Secrets):
//   APNS_KEY      the whole .p8 file from developer.apple.com → Keys (Apple Push Notifications service)
//   APNS_KEY_ID   that key's 10-character Key ID
//   APNS_TEAM_ID  8VN4WGJA8Y
// Optional: APNS_TOPIC (defaults to the app's bundle ID).

import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";

type Queued = {
  id: number;
  recipients: string[];
  title: string;
  body: string;
  route: Record<string, unknown>;
  thread: string | null;
};
type Device = { token: string; sandbox: boolean };

const topic = Deno.env.get("APNS_TOPIC") || "com.ethantraister.FoCoSocial";

function base64url(bytes: Uint8Array | string) {
  const raw = typeof bytes === "string" ? bytes : String.fromCharCode(...bytes);
  return btoa(raw).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function signToken(): Promise<string> {
  const pem = Deno.env.get("APNS_KEY") ?? "";
  const der = Uint8Array.from(
    atob(pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, "")),
    (c) => c.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const header = base64url(JSON.stringify({ alg: "ES256", kid: Deno.env.get("APNS_KEY_ID") }));
  const claims = base64url(JSON.stringify({ iss: Deno.env.get("APNS_TEAM_ID") || "8VN4WGJA8Y", iat: Math.floor(Date.now() / 1000) }));
  const signature = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${claims}`)),
  );
  return `${header}.${claims}.${base64url(signature)}`;
}

// Apple rejects a sign-in token that changes more often than every 20 minutes, and one older than an hour,
// so one token is shared (through the database) and replaced after 40 minutes.
async function providerToken(db: SupabaseClient): Promise<string> {
  const { data } = await db.from("push_auth").select("token, issued_at").eq("id", 1).maybeSingle();
  if (data && Date.now() - new Date(data.issued_at).getTime() < 40 * 60 * 1000) return data.token;
  const token = await signToken();
  await db.from("push_auth").upsert({ id: 1, token, issued_at: new Date().toISOString() });
  return token;
}

async function send(device: Device, payload: unknown, jwt: string) {
  const host = device.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const headers: Record<string, string> = {
    authorization: `bearer ${jwt}`,
    "apns-topic": topic,
    "apns-push-type": "alert",
    "apns-priority": "10",
  };
  try {
    const res = await fetch(`https://${host}/3/device/${device.token}`, { method: "POST", headers, body: JSON.stringify(payload) });
    const reason = res.ok ? "" : ((await res.json().catch(() => ({}))) as { reason?: string }).reason ?? "";
    return { token: device.token, status: res.status, reason };
  } catch (e) {
    return { token: device.token, status: 0, reason: String(e) };
  }
}

Deno.serve(async (req) => {
  const { id } = await req.json().catch(() => ({ id: null }));
  if (!Number.isInteger(id)) return new Response("expected {\"id\": <push_queue id>}", { status: 400 });

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  // Claim it first, so a repeated call can't send it twice.
  const { data: claimed, error } = await db.from("push_queue")
    .update({ sent_at: new Date().toISOString() }).eq("id", id).is("sent_at", null)
    .select("id, recipients, title, body, route, thread");
  if (error) return new Response(error.message, { status: 500 });
  const note = (claimed ?? [])[0] as Queued | undefined;
  if (!note) return Response.json({ sent: 0, reason: "already sent or not found" });

  const { data: devices } = await db.from("devices").select("token, sandbox").in("user_id", note.recipients);
  if (!devices?.length) return Response.json({ sent: 0, reason: "no phones registered" });

  const payload = {
    aps: {
      alert: { title: note.title, body: note.body },
      sound: "default",
      ...(note.thread ? { "thread-id": note.thread } : {}),
    },
    route: note.route,
  };
  const jwt = await providerToken(db);
  const results = await Promise.all((devices as Device[]).map((d) => send(d, payload, jwt)));

  // Phones that deleted the app (or tokens that were never valid) are forgotten.
  const dead = results.filter((r) => r.status === 410 || (r.status === 400 && r.reason === "BadDeviceToken")).map((r) => r.token);
  if (dead.length) await db.from("devices").delete().in("token", dead);

  const failed = results.filter((r) => r.status !== 200);
  return Response.json({ sent: results.length - failed.length, failed: failed.map((r) => ({ status: r.status, reason: r.reason })) });
});
