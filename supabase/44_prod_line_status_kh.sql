-- =====================================================================
-- GĐ40 (20/11): Bảng tổng hợp Sản xuất (Form A) – cột "SL KH" phải lấy
-- từ LỆNH SẢN XUẤT KHSX đã lập cho line/ngày, không phụ thuộc Form A đã
-- nhập hay chưa.
--
-- Trước đây prod_line_status() tính plan_qty = sum(production_reports.
-- plan_qty) — cột này CHỈ có giá trị khi tổ trưởng đã nhập Form A (và
-- gõ tay SL kế hoạch cho từng dòng), nên các line KHSX đã lập lệnh
-- nhưng CHƯA nhập báo cáo hiện "–" ở cột SL KH, dù đã có kế hoạch.
--
-- Sửa: plan_qty = tổng qty_total của các lệnh kind='planned' trong
-- production_order_batches cho đúng line_id + order_date — đúng số kế
-- hoạch KHSX đã lên đơn, hiển thị ngay cả khi line chưa nhập báo cáo.
-- Lệnh 'overflow' (Tranh thủ ngoài KH) KHÔNG tính vào SL KH, đúng
-- nguyên tắc GĐ33. Dòng Form A nhập "ngoài lệnh" (không gắn lệnh KHSX,
-- order_batch_id null) cũng không còn cộng vào SL KH nữa — đúng vì
-- không phải kế hoạch chính thức.
-- =====================================================================

create or replace function public.prod_line_status(d date)
returns table(line_id smallint, line_name text, leaders text, n_rows integer, plan_qty bigint, good_qty bigint, ng_op bigint, ng_sup bigint, man_hours numeric, std_hours numeric, downtime_min bigint, missing_norm integer, last_edit timestamp with time zone)
language sql stable security definer set search_path = public as $function$
  select l.id, l.name,
    (select string_agg(p.full_name, ', ' order by p.full_name) from user_lines ul join profiles p on p.id = ul.profile_id and p.status = 'active' where ul.line_id = l.id),
    count(r.id)::int,
    (select sum(b.qty_total) from production_order_batches b where b.line_id = l.id and b.order_date = d and b.kind = 'planned'),
    coalesce(sum(r.good_qty),0), coalesce(sum(r.ng_op),0), coalesce(sum(r.ng_sup),0),
    coalesce(sum(r.headcount * (r.hours + r.ot_hours)),0),
    coalesce(sum(r.good_qty / nullif(coalesce(pr.norm_per_hour,
      (select (value->>'stdProd')::numeric from app_settings where key = 'rules'), 32), 0)),0),
    coalesce(sum(r.downtime_min),0), count(r.id) filter (where pr.norm_per_hour is null)::int, max(r.updated_at)
  from production_lines l
  left join production_reports r on r.line_id = l.id and r.report_date = d
  left join products pr on pr.code = r.product_code
  where l.active and (public.is_admin() or public.in_dept(public.dept_id_of('SX')) or public.in_dept(public.dept_id_of('QAC'))
        or public.in_dept(public.dept_id_of('KHSX')) or public.in_dept(public.dept_id_of('KTGT')) or public.in_dept(public.dept_id_of('CD')))
  group by l.id, l.name order by l.id
$function$;
