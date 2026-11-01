// =====================================================================
// TLC FACTORY OPERATION DASHBOARD · Edge Function "admin-users"
// Tạo / khóa / mở khóa / đặt lại mật khẩu / sửa thông tin tài khoản.
// Chỉ tài khoản GĐNM (role = admin, đang hoạt động) gọi được.
// Khóa bí mật (secret / service_role) chỉ nằm ở máy chủ Supabase, không bao giờ ở trang web.
// Cài đặt: Supabase → Edge Functions → Deploy a new function → Via Editor
//          Tên: admin-users · dán toàn bộ file này · TẮT "Verify JWT" (hàm tự kiểm tra người gọi)
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2.49.4";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const DOMAIN = "tlc.local"; // email nội bộ ẩn: <tên đăng nhập>@tlc.local

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}
function secretKey(): string {
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    if (keys.default) return keys.default;
  } catch (_) { /* dùng khóa cũ bên dưới */ }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
}
// Mật khẩu tạm 10 ký tự, bỏ ký tự dễ nhầm (0/O, 1/l/I)
function tempPassword(): string {
  const a = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789";
  const buf = new Uint32Array(10); crypto.getRandomValues(buf);
  let p = ""; for (const n of buf) p += a[n % a.length];
  return /\d/.test(p) ? p : p.slice(0, 9) + "7";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Chỉ nhận POST" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const admin = createClient(url, secretKey(), { auth: { persistSession: false, autoRefreshToken: false } });

  // 1. Xác định người gọi từ phiên đăng nhập
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "Chưa đăng nhập" }, 401);
  const { data: who, error: werr } = await admin.auth.getUser(token);
  if (werr || !who?.user) return json({ error: "Phiên đăng nhập không hợp lệ, hãy đăng nhập lại" }, 401);
  const { data: me } = await admin.from("profiles").select("id, role, status").eq("id", who.user.id).single();
  if (!me || me.role !== "admin" || me.status !== "active") return json({ error: "Chỉ GĐNM được quản lý tài khoản" }, 403);

  let body: Record<string, any>;
  try { body = await req.json(); } catch { return json({ error: "Dữ liệu gửi lên không đúng định dạng" }, 400); }
  const log = (action: string, target: string, data: unknown) =>
    admin.from("audit_logs").insert({ actor: me.id, table_name: "accounts", row_id: target, action, new_data: data });

  try {
    switch (body.action) {
      // ---------------------------------------------------------------
      case "create": {
        const full_name = String(body.full_name ?? "").trim().replace(/\s+/g, " ");
        const position_id = Number(body.position_id);
        const role = ["admin", "head", "staff"].includes(body.role) ? body.role : "staff";
        if (full_name.split(" ").length < 2) return json({ error: "Nhập đủ họ và tên (ít nhất 2 từ)" }, 400);
        const { data: pos } = await admin.from("positions").select("id, dept_id, kind").eq("id", position_id).single();
        if (!pos) return json({ error: "Vị trí không tồn tại" }, 400);
        if (role === "head" && pos.kind !== "head") return json({ error: "Vai trò Trưởng bộ phận phải gắn với vị trí Trưởng bộ phận" }, 400);
        const { data: uname, error: uerr } = await admin.rpc("tlc_make_username", { p_full_name: full_name });
        if (uerr) return json({ error: "Không sinh được tên đăng nhập: " + uerr.message }, 400);
        const password = tempPassword();
        const { data: created, error: cerr } = await admin.auth.admin.createUser({
          email: `${uname}@${DOMAIN}`, password, email_confirm: true, user_metadata: { username: uname, full_name },
        });
        if (cerr || !created.user) return json({ error: "Không tạo được tài khoản: " + (cerr?.message ?? "") }, 400);
        const { error: perr } = await admin.from("profiles").insert({
          id: created.user.id, username: uname, full_name, dept_id: pos.dept_id, position_id: pos.id,
          manager_id: body.manager_id || null, role, status: "active", must_change_pw: true, created_by: me.id,
        });
        if (perr) { await admin.auth.admin.deleteUser(created.user.id); return json({ error: "Không lưu được hồ sơ: " + perr.message }, 400); }
        await log("ACCOUNT_CREATE", created.user.id, { username: uname, full_name, position_id: pos.id, role });
        return json({ ok: true, id: created.user.id, username: uname, password });
      }
      // ---------------------------------------------------------------
      case "reset_password": {
        const password = tempPassword();
        const { error } = await admin.auth.admin.updateUserById(body.id, { password });
        if (error) return json({ error: error.message }, 400);
        await admin.from("profiles").update({ must_change_pw: true }).eq("id", body.id);
        await log("ACCOUNT_RESET_PASSWORD", body.id, {});
        return json({ ok: true, password });
      }
      // ---------------------------------------------------------------
      case "set_status": {
        if (body.id === me.id) return json({ error: "Không tự khóa tài khoản của mình" }, 400);
        const status = body.status === "locked" ? "locked" : "active";
        const { error } = await admin.auth.admin.updateUserById(body.id, { ban_duration: status === "locked" ? "876000h" : "none" });
        if (error) return json({ error: error.message }, 400);
        await admin.from("profiles").update({ status }).eq("id", body.id);
        // Phiên đang mở bị chặn ngay vì mọi quyền dữ liệu kiểm tra profiles.status = active
        await log(status === "locked" ? "ACCOUNT_LOCK" : "ACCOUNT_UNLOCK", body.id, {});
        return json({ ok: true, status });
      }
      // ---------------------------------------------------------------
      case "update": {
        const patch: Record<string, unknown> = {};
        if (body.full_name) patch.full_name = String(body.full_name).trim();
        if (body.position_id) {
          const { data: pos } = await admin.from("positions").select("id, dept_id").eq("id", Number(body.position_id)).single();
          if (!pos) return json({ error: "Vị trí không tồn tại" }, 400);
          patch.position_id = pos.id; patch.dept_id = pos.dept_id;
        }
        if (body.role && ["admin", "head", "staff"].includes(body.role)) patch.role = body.role;
        if ("manager_id" in body) patch.manager_id = body.manager_id || null;
        if (body.id === me.id && patch.role && patch.role !== "admin") return json({ error: "Không tự hạ quyền GĐNM của mình" }, 400);
        const { error } = await admin.from("profiles").update(patch).eq("id", body.id);
        if (error) return json({ error: error.message }, 400);
        await log("ACCOUNT_UPDATE", body.id, patch);
        return json({ ok: true });
      }
      default:
        return json({ error: "Thao tác không hợp lệ" }, 400);
    }
  } catch (e) {
    return json({ error: "Lỗi máy chủ: " + (e as Error).message }, 500);
  }
});
