-- =====================================================================
-- GĐ17: BỎ HẲN cảnh báo/chặn nhập trùng mã trong cùng line/ngày.
-- Theo yêu cầu của anh 03/11: "Vẫn có thể sản xuất Một mã hàng giống nhau
-- nhưng sản xuất thành hai lần, và nhập riêng biệt. Không có cảnh báo cấm
-- nhập gộp mã. Bỏ cảnh báo nhập trùng mã hoặc không cho nhập trùng mã."
--
-- GĐ16 (26_ma_nhieu_lenh.sql) chỉ nới lỏng theo lệnh sản xuất: 1 mã được
-- 2 dòng NẾU thuộc 2 lệnh khác nhau, nhưng vẫn giữ unique index + chặn ở
-- client khi trùng mã trong CÙNG 1 lệnh (hoặc cùng "ngoài lệnh"). Giờ bỏ
-- hẳn mọi ràng buộc duy nhất theo mã — 1 line/ngày có bao nhiêu dòng cùng
-- mã cũng được, tổ trưởng tự quyết định nhập riêng hay gộp.
--
-- Thay đổi:
-- 1) Xóa unique index production_reports_uniq_idx — không còn ràng buộc
--    (ngày, line, mã, lệnh) phải duy nhất.
-- 2) save_prod_row: bỏ cơ chế "upsert theo mã" (on conflict), thêm tham
--    số p_row_id — có giá trị thì SỬA đúng dòng đó theo id, không có thì
--    LUÔN TẠO DÒNG MỚI (không còn tự động ghi đè dòng trùng mã cũ nữa,
--    vì không còn gì để "conflict" vào).
-- An toàn: không xóa/đổi dữ liệu cũ, chỉ bỏ ràng buộc và đổi cách lưu.
-- =====================================================================

drop index if exists public.production_reports_uniq_idx;

drop function if exists public.save_prod_row(date,int,text,int,int,int,int,int,int,numeric,numeric,numeric,int,text,text,bigint);

create or replace function public.save_prod_row(d date, p_line int, p_product text, p_plan int, p_good int, p_ng_op int, p_ng_sup int,
  p_defect_op int, p_defect_sup int, p_headcount numeric, p_hours numeric, p_ot numeric, p_downtime int, p_dt_reason text, p_note text,
  p_order_batch_id bigint default null, p_row_id bigint default null)
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

  if p_row_id is not null then
    update production_reports set plan_qty = pl, good_qty = coalesce(p_good,0), ng_op = coalesce(p_ng_op,0), ng_sup = coalesce(p_ng_sup,0),
      defect_op = p_defect_op, defect_sup = p_defect_sup, headcount = coalesce(p_headcount,0), hours = coalesce(p_hours,8), ot_hours = coalesce(p_ot,0),
      downtime_min = coalesce(p_downtime,0), downtime_reason = nullif(trim(p_dt_reason),''), note = p_note, last_edit_by = auth.uid()
    where id = p_row_id and report_date = d and line_id = p_line
    returning id into rid;
    if rid is null then raise exception 'Không tìm thấy dòng báo cáo % của line % ngày % để sửa', p_row_id, p_line, to_char(d,'DD/MM'); end if;
  else
    insert into production_reports(report_date, line_id, product_code, plan_qty, good_qty, ng_op, ng_sup, defect_op, defect_sup,
       headcount, hours, ot_hours, downtime_min, downtime_reason, note, order_batch_id, created_by, last_edit_by)
    values (d, p_line, p_product, pl, coalesce(p_good,0), coalesce(p_ng_op,0), coalesce(p_ng_sup,0), p_defect_op, p_defect_sup,
       coalesce(p_headcount,0), coalesce(p_hours,8), coalesce(p_ot,0), coalesce(p_downtime,0), nullif(trim(p_dt_reason),''), p_note, p_order_batch_id, auth.uid(), auth.uid())
    returning id into rid;
  end if;
  return rid;
end $$;

revoke execute on function public.save_prod_row(date,int,text,int,int,int,int,int,int,numeric,numeric,numeric,int,text,text,bigint,bigint) from anon, public;
grant execute on function public.save_prod_row(date,int,text,int,int,int,int,int,int,numeric,numeric,numeric,int,text,text,bigint,bigint) to authenticated;

-- Kiểm tra sau khi chạy:
-- select indexname from pg_indexes where tablename = 'production_reports'; -- không còn production_reports_uniq_idx
-- select proname, pronargs from pg_proc where proname = 'save_prod_row'; -- pronargs = 17
