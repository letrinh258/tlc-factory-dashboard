-- =====================================================================
-- TLC FACTORY OPERATION DASHBOARD · Giai đoạn 6 (01/11/2026) – Chuông thông báo
-- Đưa các cảnh báo vận hành (đang hiện trong Tổng quan) vào chuông thông báo.
-- GĐNM + người được tích "Xem Tổng quan" (can_overview): thấy TẤT CẢ cảnh báo toàn nhà máy.
-- TBP (kể cả kiêm nhiệm nhiều bộ phận): CHỈ thấy cảnh báo của (các) bộ phận mình phụ trách.
-- Nhân viên thường: không có cảnh báo vận hành (vẫn có việc/chỉ đạo của riêng mình, như cũ).
-- Chạy SAU 07_dash_quyen.sql. Chạy lại được.
-- =====================================================================

-- Đã tới hạn tổ trưởng nộp báo cáo SX hôm nay chưa (theo rules.cutoff, giờ VN)
create or replace function public.sx_cutoff_passed() returns boolean
language sql stable as $$
  select (now() at time zone 'Asia/Ho_Chi_Minh')::time
    >= coalesce((select value->>'cutoff' from app_settings where key = 'rules'), '17:30')::time
$$;

drop function if exists public.my_alerts();

create or replace function public.my_alerts() returns table(kind text, title text, detail text, ref text, mod text)
language plpgsql stable security definer set search_path = public as $$
declare
  th jsonb := coalesce((select value from app_settings where key = 'thresholds'), '{}'::jsonb);
  std numeric := coalesce((select (value->>'stdProd')::numeric from app_settings where key = 'rules'), 32);
  full_view boolean := public.can_overview();
  today date := public.tlc_today();
  my_depts smallint[];
  my_codes text[];
  d record;
  prod_tgt numeric := coalesce((th->'prod'->>'tgt')::numeric, 100); prod_y numeric := coalesce((th->'prod'->>'y')::numeric, 95);
  dop_tgt numeric := coalesce((th->'defOp'->>'tgt')::numeric, 0.5); dop_y numeric := coalesce((th->'defOp'->>'y')::numeric, 80);
  dsu_tgt numeric := coalesce((th->'defSup'->>'tgt')::numeric, 0.3); dsu_y numeric := coalesce((th->'defSup'->>'y')::numeric, 80);
  pr_good numeric; pr_ngop numeric; pr_ngsup numeric; pr_mh numeric; pr_std numeric; pr_rows int;
  ns numeric; ngop_pct numeric; ngsup_pct numeric;
  n_miss int; miss_names text; n int;
begin
  if not public.is_active_user() then return; end if;

  -- ========== 1) Việc / chỉ đạo + hỗ trợ đã quyết định (giữ như Giai đoạn 4, theo từng người) ==========
  return query
  select 'task_new', 'Việc mới được giao: ' || t.code, t.title, t.code, 'task'::text from tasks t
    where t.report_code = any(public.my_report_codes()) and t.status = 'new'
  union all
  select 'task_due', 'Sắp đến hạn (' || to_char(t.due_date,'DD/MM') || '): ' || t.code, t.title, t.code, 'task' from tasks t
    where t.report_code = any(public.my_report_codes()) and t.status not in ('done','cancelled') and t.due_date = today + 1
  union all
  select 'task_over', 'QUÁ HẠN: ' || t.code, t.title, t.code, 'task' from tasks t
    where t.report_code = any(public.my_report_codes()) and t.status not in ('done','cancelled') and t.due_date < today
  union all
  select 'decided', 'Đã có quyết định: ' || left(sr.content, 60), coalesce(sr.decision,''), sr.id::text, 'task' from support_requests sr
    where sr.report_code = any(public.my_report_codes()) and sr.status in ('Đã quyết định','Đã hỗ trợ') and sr.decided_date >= today - 1
  union all
  select 'approve_close', 'Chờ đóng việc: ' || t.code, t.title, t.code, 'task' from tasks t
    where t.status = 'pending_confirm' and (public.is_admin() or t.assigner_id = auth.uid())
  union all
  select 'approve_due', 'Xin lùi hạn ' || to_char(t.requested_due,'DD/MM') || ': ' || t.code, coalesce(t.requested_reason,''), t.code, 'task' from tasks t
    where t.requested_due is not null and (public.is_admin() or t.assigner_id = auth.uid())
  union all
  select 'decide', 'Chờ quyết định (' || sr.report_code || '): ' || left(sr.content, 60), coalesce(sr.proposal,''), sr.id::text, 'task' from support_requests sr
    where sr.status = 'Chờ phản hồi' and public.is_admin()
  union all
  select 'missing', 'Chưa báo cáo ngày ' || to_char(today - 1,'DD/MM') || ': ' || ps.report_code, ps.name, ps.report_code, 'sum' from positions ps
    where public.is_admin() and ps.report_code is not null and extract(dow from today - 1) <> 0
      and not exists(select 1 from daily_reports r where r.report_code = ps.report_code and r.report_date = today - 1);

  -- ========== 2) Cảnh báo vận hành hôm nay ==========
  if not full_view then
    select array_agg(x.id), array_agg(x.code) into my_depts, my_codes from departments x where x.code <> 'BGD' and public.is_head_of(x.id);
    if my_depts is null then return; end if; -- nhân viên thường, không phụ trách bộ phận nào → dừng ở đây
  end if;

  -- SX / KHSX: line chưa nhập báo cáo hôm nay (sau giờ chốt) + năng suất + NG thao tác/NCC
  if full_view or my_codes && array['SX','KHSX'] then
    if public.sx_cutoff_passed() then
      select count(*), string_agg(l.name, ', ') into n_miss, miss_names from production_lines l
        where l.active and not exists(select 1 from production_reports r where r.line_id = l.id and r.report_date = today);
      if n_miss > 0 then
        return query select 'line_missing', n_miss || ' line chưa nhập báo cáo SX hôm nay ' || to_char(today,'DD/MM'), miss_names, today::text, 'sx';
      end if;
    end if;
    select count(*), coalesce(sum(good_qty),0), coalesce(sum(ng_op),0), coalesce(sum(ng_sup),0),
           coalesce(sum(headcount * (hours + ot_hours)),0), coalesce(sum(good_qty / nullif(coalesce(p.norm_per_hour, std),0)),0)
      into pr_rows, pr_good, pr_ngop, pr_ngsup, pr_mh, pr_std
      from production_reports r left join products p on p.code = r.product_code where r.report_date = today;
    if pr_rows > 0 then
      ns := case when pr_mh > 0 then pr_std / pr_mh * 100 end;
      if ns is not null and ns < prod_tgt * prod_y / 100 then
        return query select 'low_prod', 'Năng suất hôm nay ' || round(ns) || '% định mức (mục tiêu ' || round(prod_tgt) || '%)',
          round(pr_std) || ' giờ chuẩn / ' || round(pr_mh) || ' giờ công', today::text, 'sx';
      end if;
      ngop_pct := case when pr_good + pr_ngop + pr_ngsup > 0 then pr_ngop / (pr_good + pr_ngop + pr_ngsup) * 100 end;
      if ngop_pct is not null and ngop_pct > dop_tgt / (dop_y / 100) then
        return query select 'ng_op', 'NG thao tác hôm nay ' || round(ngop_pct,2) || '% (mục tiêu ≤ ' || dop_tgt || '%)', '', today::text, 'sx';
      end if;
      ngsup_pct := case when pr_good + pr_ngop + pr_ngsup > 0 then pr_ngsup / (pr_good + pr_ngop + pr_ngsup) * 100 end;
      if ngsup_pct is not null and ngsup_pct > dsu_tgt / (dsu_y / 100) then
        return query select 'ng_sup', 'NG nhà cung cấp hôm nay ' || round(ngsup_pct,2) || '% (mục tiêu ≤ ' || dsu_tgt || '%)', '', today::text, 'sx';
      end if;
    end if;
  end if;

  -- SX/QAC/CĐ/Kho: điểm đối chiếu lệch hôm nay
  if full_view or my_codes && array['SX','QAC','CD','KHO'] then
    select count(*) into n from public.recon(today) x where x.flagged;
    if n > 0 then
      return query select 'recon', n || ' điểm lệch giữa các bộ phận hôm nay',
        'SX ↔ Kho TP · NG SX ↔ QAC · dừng máy SX ↔ Cơ điện – cần giải trình', today::text, 'sx';
    end if;
  end if;

  -- Cơ điện: sự cố máy chưa xử lý xong
  if full_view or 'CD' = any(my_codes) then
    select count(*) into n from maintenance_reports m where m.kind = 'breakdown' and m.end_at is null and m.report_date = today;
    if n > 0 then
      return query select 'cd_open', n || ' sự cố máy chưa xử lý xong', 'Phiếu Cơ điện chưa có giờ kết thúc', today::text, 'bt';
    end if;
  end if;

  -- Kho: vật tư thiếu hôm nay
  if full_view or 'KHO' = any(my_codes) then
    select count(distinct item_code) into n from wh_entries w where w.kind = 'shortage' and w.report_date = today;
    if n > 0 then
      return query select 'shortage', n || ' mã vật tư thiếu', 'Kho linh kiện báo hôm nay', today::text, 'kho';
    end if;
  end if;

  -- 3S / Việc·chỉ đạo quá hạn / vấn đề mức ĐỎ: GĐNM xem tổng toàn nhà máy; TBP xem riêng từng bộ phận mình phụ trách
  if full_view then
    select count(*) into n from fives_findings f where f.status <> 'closed' and f.due_date < today;
    if n > 0 then return query select 'fives_over', n || ' lỗi 3S quá hạn khắc phục (toàn nhà máy)', '', today::text, '5s'; end if;
    select count(*) into n from tasks where status not in ('done','cancelled') and due_date < today;
    if n > 0 then return query select 'task_over_all', n || ' việc / chỉ đạo quá hạn (toàn nhà máy)', '', today::text, 'task'; end if;
    select count(*) into n from issues where severity = 'red' and status not in ('resolved','closed');
    if n > 0 then return query select 'issue_red_all', n || ' vấn đề mức ĐỎ đang mở (toàn nhà máy)', 'Từ mục 2 báo cáo ngày', today::text, 'sum'; end if;
  else
    for d in select x.id, x.name from departments x where x.id = any(my_depts) loop
      select count(*) into n from fives_findings f join fives_audits a on a.id = f.audit_id
        where f.status <> 'closed' and f.due_date < today and a.target_dept_id = d.id;
      if n > 0 then return query select 'fives_over', n || ' lỗi 3S quá hạn khắc phục (phòng ' || d.name || ')', '', today::text, '5s'; end if;

      select count(*) into n from tasks where dept_id = d.id and status not in ('done','cancelled') and due_date < today;
      if n > 0 then return query select 'dept_task_over', n || ' việc / chỉ đạo của phòng ' || d.name || ' quá hạn', '', today::text, 'task'; end if;

      select count(*) into n from issues where dept_id = d.id and severity = 'red' and status not in ('resolved','closed');
      if n > 0 then return query select 'dept_issue_red', n || ' vấn đề mức ĐỎ đang mở (phòng ' || d.name || ')', 'Từ mục 2 báo cáo ngày', today::text, 'sum'; end if;
    end loop;
  end if;
end $$;

revoke execute on function public.sx_cutoff_passed(), public.my_alerts() from anon, public;
grant execute on function public.sx_cutoff_passed(), public.my_alerts() to authenticated;
