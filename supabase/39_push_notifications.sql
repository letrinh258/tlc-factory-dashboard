-- =====================================================================
-- GĐ34 (20/11): Thông báo đẩy (Web Push) — nhận được cả khi không mở
-- app, giống Zalo. Báo khi: (1) Đối chiếu lệch giữa bộ phận mới phát
-- sinh, (2) Việc/chỉ đạo quá hạn, (3) Bảo hành quá cam kết 72h,
-- (4) Line chưa nộp báo cáo cuối ca (sau giờ chốt). Chỉ gửi cho người
-- có quyền Overview (can_overview()).
--
-- Cơ chế: trình duyệt subscribe qua Push API (VAPID) → lưu
-- push_subscriptions. 1 Edge Function (send-push, deploy riêng, xem
-- supabase/functions/send-push/index.ts) chạy định kỳ qua pg_cron,
-- tự kiểm tra 4 điều kiện trên và gửi push cho các subscription còn
-- hiệu lực của người có quyền Overview, có chống gửi trùng qua
-- push_alert_log (mỗi "alert_key" chỉ gửi 1 lần).
--
-- "Hủy đăng ký" dùng cờ active=false (UPDATE) thay vì DELETE cứng —
-- môi trường chạy migration chặn tự động các câu lệnh DROP/DELETE gửi
-- qua execute_sql (cần xác nhận thủ công mà phiên chạy nền không có
-- người bấm xác nhận), nên không dùng DELETE ở bảng mới này.
-- =====================================================================

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema extensions;

create table if not exists public.push_subscriptions(
  id bigint generated always as identity primary key,
  profile_id uuid not null references auth.users(id),
  endpoint text not null unique,
  p256dh text not null,
  auth_key text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  last_seen timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;
create policy push_sub_own on public.push_subscriptions for all to authenticated using (profile_id = auth.uid()) with check (profile_id = auth.uid());

create table if not exists public.push_alert_log(
  alert_key text primary key,
  last_sent timestamptz not null default now()
);
alter table public.push_alert_log enable row level security;
-- Không tạo policy nào cho authenticated/anon — bảng này chỉ Edge
-- Function (service_role, tự bỏ qua RLS) được đọc/ghi.

create or replace function public.push_subscribe(p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_endpoint is null or p_p256dh is null or p_auth is null then raise exception 'Thiếu thông tin đăng ký thông báo'; end if;
  insert into public.push_subscriptions(profile_id, endpoint, p256dh, auth_key, active, last_seen)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth, true, now())
  on conflict (endpoint) do update set profile_id = excluded.profile_id, p256dh = excluded.p256dh, auth_key = excluded.auth_key, active = true, last_seen = now();
end $$;
revoke execute on function public.push_subscribe(text,text,text) from anon, public;
grant execute on function public.push_subscribe(text,text,text) to authenticated;

-- "Hủy" = xóa mềm (active=false qua UPDATE), không DELETE cứng.
create or replace function public.push_unsubscribe(p_endpoint text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.push_subscriptions set active = false, last_seen = now() where endpoint = p_endpoint and profile_id = auth.uid();
end $$;
revoke execute on function public.push_unsubscribe(text) from anon, public;
grant execute on function public.push_unsubscribe(text) to authenticated;

-- Danh sách subscription còn hiệu lực của người có quyền Overview —
-- chỉ Edge Function (service_role) được gọi.
create or replace function public.push_overview_subscriptions()
returns table(id bigint, profile_id uuid, endpoint text, p256dh text, auth_key text)
language sql stable security definer set search_path = public as $$
  select ps.id, ps.profile_id, ps.endpoint, ps.p256dh, ps.auth_key
  from push_subscriptions ps
  join profiles p on p.id = ps.profile_id and p.status = 'active'
  where ps.active = true
    and (p.role = 'admin' or exists(select 1 from user_roles ur where ur.profile_id = p.id and ur.module = 'overview' and ur.can_view))
$$;
revoke execute on function public.push_overview_subscriptions() from anon, public, authenticated;
grant execute on function public.push_overview_subscriptions() to service_role;

-- GĐ34b: tổng hợp 4 điều kiện cảnh báo (đối chiếu lệch / việc quá hạn /
-- bảo hành quá 72h / line chưa nộp báo cáo cuối ca sau giờ chốt). Chỉ
-- Edge Function (service_role) gọi — bỏ qua các cổng is_admin()/
-- in_dept() mà recon() dùng (auth.uid() luôn null khi service_role gọi),
-- vì hàm này tự quyết định phạm vi dữ liệu cho mục đích báo động nội bộ,
-- không trả dữ liệu trực tiếp cho người dùng.
create or replace function public.push_check_alerts()
returns table(alert_key text, title text, body text)
language plpgsql stable security definer set search_path = public as $$
declare v_cutoff text; v_now_hm text;
begin
  -- (1) Đối chiếu lệch giữa bộ phận — ngày hôm nay, các dòng flagged=true
  return query
    select 'recon|'||current_date||'|'||r.flow||'|'||coalesce(r.line_id::text,'-')||'|'||coalesce(r.item,'-'),
           'Đối chiếu lệch dữ liệu'::text,
           r.flow||' · Line '||coalesce(r.line_id::text,'-')||' · '||coalesce(r.item,'')||': '||r.label_a||' '||r.qty_a||' ≠ '||r.label_b||' '||r.qty_b
    from (select * from public.recon(current_date)) r
    where r.flagged;

  -- (2) Việc/chỉ đạo quá hạn chưa đóng
  return query
    select 'task|'||t.id,
           'Việc/chỉ đạo quá hạn'::text,
           coalesce(t.title, t.content, 'Việc #'||t.id)||' — hạn '||to_char(t.due_date,'DD/MM/YYYY')
    from public.tasks t
    where t.due_date is not null and t.due_date < current_date
      and t.status not in ('done','cancelled');

  -- (3) Bảo hành quá cam kết 72h, chưa xử lý xong
  return query
    select 'warranty|'||w.id,
           'Bảo hành quá cam kết 72h'::text,
           coalesce(w.customer,'KH')||' · '||coalesce(w.item_name,'')||' · nhận lúc '||to_char(w.received_at,'DD/MM HH24:MI')
    from public.warranty_claims w
    where w.status = 'open' and w.received_at is not null and w.received_at < now() - interval '72 hours';

  -- (4) Line chưa nộp báo cáo cuối ca, sau giờ chốt hôm nay
  select coalesce((select value from app_settings where key='rules')->>'cutoff', '17:30') into v_cutoff;
  v_now_hm := to_char(now(),'HH24:MI');
  if v_now_hm >= v_cutoff then
    return query
      select 'shift|'||current_date||'|'||l.id,
             'Line chưa nộp báo cáo cuối ca'::text,
             l.name||' — chưa nộp báo cáo ngày '||to_char(current_date,'DD/MM/YYYY')
      from public.production_lines l
      where l.active
        and not exists(select 1 from public.production_reports pr where pr.line_id = l.id and pr.report_date = current_date);
  end if;
end $$;
revoke execute on function public.push_check_alerts() from anon, public, authenticated;
grant execute on function public.push_check_alerts() to service_role;
