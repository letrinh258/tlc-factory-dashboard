-- =====================================================================
-- GĐ31 (17/11): Sửa lỗi "Đối chiếu tự động" báo "Khớp" dù số liệu lệch.
--
-- Hàm recon() (xem 04_gd5b.sql) đang dùng điều kiện AND giữa 2 ngưỡng
-- cấu hình cho luồng "NG SX ↔ QAC":
--   abs(diff) > ngDiffQty  AND  abs(diff) > ngDiffPct%
-- Với cấu hình thực tế (ngDiffQty=10, ngDiffPct=5%), một lệch như
-- SX báo 6 / QAC báo 0 có abs(diff)=6 < 10 (ngưỡng số lượng không đạt)
-- nên điều kiện AND = false → không báo "Lệch" dù rõ ràng SX và QAC
-- không khớp nhau 1 sản phẩm nào.
--
-- Theo yêu cầu của anh Trình (GĐ vận hành): bỏ hẳn 2 ngưỡng %/số lượng
-- cho luồng NG SX ↔ QAC — chỉ cần Bên A ≠ Bên B là báo "Lệch – cần
-- giải trình", giống hệt cách đang áp dụng cho luồng "SX → Kho TP".
-- Ngưỡng dtDiffMin (lệch giờ dừng máy CĐ ↔ SX) giữ nguyên vì không có
-- yêu cầu đổi.
-- =====================================================================

create or replace function public.recon(d date)
 returns table(flow text, line_id smallint, item text, label_a text, qty_a numeric, label_b text, qty_b numeric, diff numeric, flagged boolean)
 language sql stable security definer set search_path to 'public'
as $function$
  with r as (select coalesce((select value from app_settings where key = 'rules'), '{}'::jsonb) v),
  sx as (select line_id, product_code, sum(good_qty) good, sum(ng_op) op, sum(ng_sup) sup, sum(downtime_min) dt
         from production_reports where report_date = d group by 1, 2),
  tp as (select line_id, item_code product_code, sum(qty) q from wh_entries where report_date = d and kind = 'receipt_sx' group by 1, 2),
  qc as (select q.line_id, q.product_code, sum(df.qty) filter (where t.source = 'op') op, sum(df.qty) filter (where t.source = 'sup') sup
         from quality_reports q join quality_defects df on df.report_id = q.id join defect_types t on t.id = df.defect_type_id
         where q.report_date = d and q.stage = 'PQC' group by 1, 2),
  mt as (select line_id, sum(downtime_min) dt from maintenance_reports where report_date = d and kind = 'breakdown' and line_id is not null group by 1),
  rows as (
    select 'SX → Kho TP'::text flow, coalesce(sx.line_id, tp.line_id) line_id, coalesce(sx.product_code, tp.product_code) item,
           'SX báo đạt'::text la, coalesce(sx.good,0)::numeric a, 'Kho TP nhận'::text lb, coalesce(tp.q,0)::numeric b, 'qty'::text k
      from sx full join tp on tp.line_id = sx.line_id and tp.product_code = sx.product_code
      where coalesce(sx.good,0) > 0 or coalesce(tp.q,0) > 0
    union all
    select 'NG thao tác: SX ↔ QAC', coalesce(sx.line_id, qc.line_id), coalesce(sx.product_code, qc.product_code), 'SX báo', coalesce(sx.op,0), 'QAC PQC', coalesce(qc.op,0), 'qty'
      from sx full join qc on qc.line_id = sx.line_id and qc.product_code = sx.product_code where coalesce(sx.op,0) + coalesce(qc.op,0) > 0
    union all
    select 'NG NCC: SX ↔ QAC', coalesce(sx.line_id, qc.line_id), coalesce(sx.product_code, qc.product_code), 'SX báo', coalesce(sx.sup,0), 'QAC PQC', coalesce(qc.sup,0), 'qty'
      from sx full join qc on qc.line_id = sx.line_id and qc.product_code = sx.product_code where coalesce(sx.sup,0) + coalesce(qc.sup,0) > 0
    union all
    select 'Dừng máy: SX ↔ Cơ điện', coalesce(s.line_id, mt.line_id), null, 'SX báo (phút)', coalesce(s.dt,0), 'Cơ điện (phút)', coalesce(mt.dt,0), 'dt'
      from (select line_id, sum(dt) dt from sx group by 1) s full join mt on mt.line_id = s.line_id where coalesce(s.dt,0) + coalesce(mt.dt,0) > 0
  )
  select flow, line_id::smallint, item, la, a, lb, b, b - a,
    case k when 'qty' then a <> b
           else abs(b - a) > coalesce((r.v->>'dtDiffMin')::numeric, 15) end
  from rows, r
  where public.is_admin() or public.in_dept(public.dept_id_of('SX')) or public.in_dept(public.dept_id_of('QAC'))
     or public.in_dept(public.dept_id_of('KHO')) or public.in_dept(public.dept_id_of('CD')) or public.in_dept(public.dept_id_of('KHSX'))
  order by flow, line_id, item
$function$;
