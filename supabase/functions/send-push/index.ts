// GĐ34 (20/11): Edge Function gửi Web Push — chạy định kỳ qua pg_cron.
// Mỗi lần chạy: gọi push_check_alerts() (4 điều kiện: đối chiếu lệch,
// việc/chỉ đạo quá hạn, bảo hành >72h, line chưa nộp báo cáo cuối ca),
// bỏ qua alert_key đã có trong push_alert_log (chống gửi trùng), gửi
// push cho các subscription còn hiệu lực của người có quyền Overview
// (push_overview_subscriptions()), rồi ghi log. Subscription hết hiệu
// lực (410/404 từ push service) tự động được đánh dấu active=false.
//
// Xác thực: không dùng JWT Supabase (pg_cron không có JWT người dùng) —
// verify_jwt=false khi deploy, hàm tự kiểm tra header x-cron-secret so
// với secret CRON_SECRET.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET");
const VAPID_PUBLIC_KEY = Deno.env.get("VAPID_PUBLIC_KEY")!;
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY")!;
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") || "mailto:tlc-dashboard@example.com";

webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

Deno.serve(async (req: Request) => {
  if (!CRON_SECRET || req.headers.get("x-cron-secret") !== CRON_SECRET) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: { "Content-Type": "application/json" } });
  }

  const sb = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const { data: alerts, error: alertErr } = await sb.rpc("push_check_alerts");
  if (alertErr) {
    return new Response(JSON.stringify({ error: alertErr.message }), { status: 500, headers: { "Content-Type": "application/json" } });
  }
  if (!alerts || alerts.length === 0) {
    return new Response(JSON.stringify({ sent: 0, newAlerts: 0 }), { headers: { "Content-Type": "application/json" } });
  }

  // Chỉ giữ alert_key CHƯA có trong push_alert_log (chống gửi trùng)
  const keys = alerts.map((a: { alert_key: string }) => a.alert_key);
  const { data: already } = await sb.from("push_alert_log").select("alert_key").in("alert_key", keys);
  const sentSet = new Set((already || []).map((r: { alert_key: string }) => r.alert_key));
  const fresh = alerts.filter((a: { alert_key: string }) => !sentSet.has(a.alert_key));

  if (fresh.length === 0) {
    return new Response(JSON.stringify({ sent: 0, newAlerts: 0 }), { headers: { "Content-Type": "application/json" } });
  }

  const { data: subs, error: subErr } = await sb.rpc("push_overview_subscriptions");
  if (subErr) {
    return new Response(JSON.stringify({ error: subErr.message }), { status: 500, headers: { "Content-Type": "application/json" } });
  }

  let sent = 0;
  const deadEndpoints: string[] = [];

  for (const alert of fresh) {
    const payload = JSON.stringify({ title: alert.title, body: alert.body, tag: alert.alert_key, url: "./" });
    for (const s of subs || []) {
      try {
        await webpush.sendNotification(
          { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth_key } },
          payload,
        );
        sent++;
      } catch (err) {
        const status = err && typeof err === "object" && "statusCode" in err ? (err as { statusCode: number }).statusCode : null;
        if (status === 404 || status === 410) deadEndpoints.push(s.endpoint);
        // các lỗi khác (mạng, tạm thời) bỏ qua, không đánh dấu hết hiệu lực
      }
    }
    // Ghi log NGAY sau khi đã thử gửi cho alert này, để nếu Edge Function
    // bị gọi lại (retry), không gửi trùng — dù một vài subscription lỗi.
    await sb.from("push_alert_log").upsert({ alert_key: alert.alert_key }, { onConflict: "alert_key", ignoreDuplicates: true });
  }

  if (deadEndpoints.length) {
    await sb.from("push_subscriptions").update({ active: false }).in("endpoint", deadEndpoints);
  }

  return new Response(JSON.stringify({ sent, newAlerts: fresh.length, deadEndpoints: deadEndpoints.length }), {
    headers: { "Content-Type": "application/json" },
  });
});
