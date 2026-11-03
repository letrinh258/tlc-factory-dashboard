-- =====================================================================
-- GĐ16: 1 mã sản phẩm có thể xuất hiện trong NHIỀU lệnh sản xuất khác nhau
-- cùng line/ngày (vd: lệnh buổi sáng và lệnh bổ sung buổi chiều cùng 1 mã).
-- Theo yêu cầu của anh 03/11: "1 mã có thể xuất hiện 2 lệnh. Vì vậy hãy cho
-- nhập riêng lẻ, không yêu cầu phải gộp lệnh." — tổ trưởng được tạo 2 dòng
-- báo cáo RIÊNG cho cùng 1 mã nếu chúng thuộc 2 lệnh khác nhau, thay vì bị
-- chặn "Mã này đã có trong ngày" và phải tự cộng dồn số liệu vào 1 dòng.
--
-- Trước đây production_reports chỉ ràng buộc duy nhất theo (ngày, line, mã)
-- — không biết dòng báo cáo thuộc lệnh nào, nên 2 lệnh cùng mã bắt buộc phải
-- dùng chung 1 dòng. Thêm cột order_batch_id (lệnh nào) + đổi ràng buộc duy
-- nhất thành (ngày, line, mã, lệnh) — dòng "mã khác ngoài lệnh" (không gắn
-- lệnh nào, order_batch_id = null) vẫn chỉ được 1 dòng/mã/line/ngày như cũ
-- (coalesce(order_batch_id,-1) gộp mọi dòng null về cùng 1 nhóm).
--
-- An toàn: production_reports hiện có dữ liệu thật, nhưng order_batch_id
-- là cột MỚI nên mọi dòng cũ đều có giá trị null → coalesce(null,-1) = -1
-- cho tất cả, tức là tương đương hệt ràng buộc cũ, KHÔNG xung đột dữ liệu
-- hiện có. save_prod_row cũ (15 tham số) bị DROP rồi tạo lại với tham số
-- mới p_order_batch_id có DEFAULT null ở cuối — mã nguồn cũ (chưa deploy)
-- gọi hàm không truyền tham số này vẫn chạy đúng như trước (coi như ngoài
-- lệnh), không có "khoảng hở" vì DROP+CREATE chạy trong cùng 1 transaction.
-- =====================================================================

begin;

alter table public.production_reports add column if not exists order_batch_id bigint references public.production_order_batches(id);

alter table public.production_reports drop constraint if exists production_reports_report_date_line_id_product_code_key;
drop index if exists public.production_reports_uniq_idx;
create unique index production_reports_uniq_idx on public.production_reports(report_date, line_id, product_code, coalesce(order_batch_id, -1));

drop function if exists public.save_prod_row(date,int,text,int,int,int,int,int,int,numeric,numeric,numeric,int,text,text);

create or replace function public.save_prod_row(d date, p_line int, p_product text, p_plan int, p_good int, p_ng_op int, p_ng_sup int,
  p_defect_op int, p_defect_sup int, p_headcount numeric, p_hours numeric, p_ot numeric, p_downtime int, p_dt_reason text, p_note text,
  p_order_batch_id bigint default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare rid bigint; pl int;
begin
  if not public.can_edit_line(p_line, d) then
    raise exception 'Báo cáo Line % ngày % đã khóa (sau 23:59) hoặc bạn không phụ trách line này', p_line, to_char(d,'DD/MM'); end if;
  if not exists(select 1 from products where code = p_product and active) then raise exception 'Mã sản phẩm % không có trong danh mục', p_product; end if;
  if coalesce(p_good,0) < 0 or coalesce(p_ng_op,0) < 0 or coalesce(p_ng_sup,0) < 0 then raise exception 'Số lượng không được âm'; end if;
  if coalesce(p_good,0) + coalesce(p_ng_op,0) + coalesce(p_ng_sup,0) > 0 and coalesce(p_headcount,0) <= 0 then raise exception 'Nhập số người làm'; end if;
  if coalesce(p_hours,0) + coalesce(p_ot,0) > 16 then raise exception 'Tổng giờ hành chính + tăng ca không quá 16'; end if;
  if coalesce(p_ng_op,0) > 0 and p_defect_op is null then raise exception 'Chọn loại lỗi cho NG thao tác'; end if;
  if coalesce(p_ng_sup,0) > 0 and p_defect_sup is null then raise exception 'Chọn loại lỗi cho NG nhà cung cấp'; end if;
  if coalesce(p_downtime,0) > 0 and coalesce(trim(p_dt_reason),'') = '' then raise exception 'Chọn nguyên nhân dừng máy'; end if;
  if p_order_batch_id is not null and not exists(select 1 from production_order_batches b where b.id = p_order_batch_id and b.order_date = d and b.line_id = p_line) then
    raise exception 'Lệnh sản xuất không khớp line/ngày đang nhập'; end if;
  pl := coalesce(p_plan, (select plan_qty from production_plans where plan_date = d and line_id = p_line and product_code = p_product));
  insert into production_reports(report_date, line_id, product_code, plan_qty, good_qty, ng_op, ng_sup, defect_op, defect_sup,
     headcount, hours, ot_hours, downtime_min, downtime_reason, note, order_batch_id, created_by, last_edit_by)
  values (d, p_line, p_product, pl, coalesce(p_good,0), coalesce(p_ng_op,0), coalesce(p_ng_sup,0), p_defect_op, p_defect_sup,
     coalesce(p_headcount,0), coalesce(p_hours,8), coalesce(p_ot,0), coalesce(p_downtime,0), nullif(trim(p_dt_reason),''), p_note, p_order_batch_id, auth.uid(), auth.uid())
  on conflict (report_date, line_id, product_code, coalesce(order_batch_id, -1)) do update set plan_qty = excluded.plan_qty, good_qty = excluded.good_qty,
     ng_op = excluded.ng_op, ng_sup = excluded.ng_sup, defect_op = excluded.defect_op, defect_sup = excluded.defect_sup,
     headcount = excluded.headcount, hours = excluded.hours, ot_hours = excluded.ot_hours, downtime_min = excluded.downtime_min,
     downtime_reason = excluded.downtime_reason, note = excluded.note, last_edit_by = auth.uid()
  returning id into rid;
  return rid;
end $$;

revoke execute on function public.save_prod_row(date,int,text,int,int,int,int,int,int,numeric,numeric,numeric,int,text,text,bigint) from anon, public;
grant execute on function public.save_prod_row(date,int,text,int,int,int,int,int,int,numeric,numeric,numeric,int,text,text,bigint) to authenticated;

commit;

-- Kiểm tra sau khi chạy:
-- select conname from pg_constraint where conrelid = 'public.production_reports'::regclass and contype='u';
-- select indexname from pg_indexes where tablename = 'production_reports';
-- select proname, pronargs from pg_proc where proname = 'save_prod_row';
