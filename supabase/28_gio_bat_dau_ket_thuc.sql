-- =====================================================================
-- GĐ18: Form A (Sản xuất) đổi "Giờ hành chính" + "Giờ tăng ca" (2 ô số
-- thập phân) thành "Giờ bắt đầu" + "Giờ kết thúc" (hh:mm) + "Giờ nghỉ
-- (phút)". Theo yêu cầu 03/11 + trả lời làm rõ của anh:
--   - Thời gian sản xuất để tính năng suất = Kết thúc − Bắt đầu − giờ nghỉ.
--   - Ca qua đêm (Kết thúc < Bắt đầu, vd 20:00→04:00): tự hiểu là qua ngày
--     hôm sau (cộng thêm 24h trước khi trừ).
--   - Bỏ hẳn khái niệm Hành chính/Tăng ca riêng — chỉ còn 1 số giờ công.
--
-- Giữ nguyên 2 cột hours/ot_hours đã có (để KHÔNG phải sửa lại mọi màn
-- hình/báo cáo/KPI khác đang cộng r.hours + r.ot_hours — ví dụ Tổng quan,
-- dash_summary, daily_summary, prod_line_status): từ nay trở đi
-- save_prod_row tự TÍNH giờ công từ giờ bắt đầu/kết thúc/nghỉ rồi ghi vào
-- "hours", luôn ghi "ot_hours" = 0 (không còn ai nhập tay 2 cột này nữa).
-- Dữ liệu cũ (trước GĐ18) giữ nguyên hours/ot_hours như đã nhập, không đụng
-- tới — chỉ không có start_time/end_time/break_min (null) nên bảng hiển
-- thị tự rơi về dạng "Xh" cũ cho các dòng này.
--
-- An toàn: chỉ thêm cột mới (không xóa/đổi kiểu cột cũ), rồi đổi chữ ký
-- save_prod_row (bỏ p_hours/p_ot, thêm p_start_time/p_end_time/p_break_min)
-- — DROP đúng chữ ký cũ (18 tham số từ 27_bo_chan_trung_ma.sql) trước khi
-- CREATE OR REPLACE để tránh Postgres hiểu nhầm thành 2 hàm chồng nhau.
-- =====================================================================

alter table public.production_reports add column if not exists start_time time;
alter table public.production_reports add column if not exists end_time time;
alter table public.production_reports add column if not exists break_min int not null default 0;

drop function if exists public.save_prod_row(date,int,text,int,int,int,int,int,int,numeric,numeric,numeric,int,text,text,bigint,bigint);

create or replace function public.save_prod_row(d date, p_line int, p_product text, p_plan int, p_good int, p_ng_op int, p_ng_sup int,
  p_defect_op int, p_defect_sup int, p_headcount numeric, p_start_time time, p_end_time time, p_break_min int, p_downtime int,
  p_dt_reason text, p_note text, p_order_batch_id bigint default null, p_row_id bigint default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare rid bigint; pl int; mins int; hrs numeric;
begin
  if not public.can_edit_line(p_line, d) then
    raise exception 'Báo cáo Line % ngày % đã khóa (sau 23:59) hoặc bạn không phụ trách line này', p_line, to_char(d,'DD/MM'); end if;
  if not exists(select 1 from products where code = p_product and active) then raise exception 'Mã sản phẩm % không có trong danh mục', p_product; end if;
  if coalesce(p_good,0) < 0 or coalesce(p_ng_op,0) < 0 or coalesce(p_ng_sup,0) < 0 then raise exception 'Số lượng không được âm'; end if;
  if coalesce(p_good,0) + coalesce(p_ng_op,0) + coalesce(p_ng_sup,0) > 0 and coalesce(p_headcount,0) <= 0 then raise exception 'Nhập số người làm'; end if;
  if p_start_time is null or p_end_time is null then raise exception 'Nhập giờ bắt đầu và giờ kết thúc'; end if;
  mins := (extract(hour from p_end_time)::int*60 + extract(minute from p_end_time)::int)
        - (extract(hour from p_start_time)::int*60 + extract(minute from p_start_time)::int);
  if mins <= 0 then mins := mins + 24*60; end if; -- ca qua đêm: Kết thúc < Bắt đầu coi là qua ngày hôm sau
  mins := mins - coalesce(p_break_min, 0);
  if mins <= 0 then raise exception 'Giờ nghỉ phải nhỏ hơn thời gian làm việc (Kết thúc − Bắt đầu)'; end if;
  hrs := mins / 60.0;
  if hrs > 16 then raise exception 'Thời gian làm việc (sau khi trừ giờ nghỉ) không quá 16 giờ'; end if;
  if coalesce(p_ng_op,0) > 0 and p_defect_op is null then raise exception 'Chọn loại lỗi cho NG thao tác'; end if;
  if coalesce(p_ng_sup,0) > 0 and p_defect_sup is null then raise exception 'Chọn loại lỗi cho NG nhà cung cấp'; end if;
  if coalesce(p_downtime,0) > 0 and coalesce(trim(p_dt_reason),'') = '' then raise exception 'Chọn nguyên nhân dừng máy'; end if;
  if p_order_batch_id is not null and not exists(select 1 from production_order_batches b where b.id = p_order_batch_id and b.order_date = d and b.line_id = p_line) then
    raise exception 'Lệnh sản xuất không khớp line/ngày đang nhập'; end if;
  pl := coalesce(p_plan, (select plan_qty from production_plans where plan_date = d and line_id = p_line and product_code = p_product));

  if p_row_id is not null then
    update production_reports set plan_qty = pl, good_qty = coalesce(p_good,0), ng_op = coalesce(p_ng_op,0), ng_sup = coalesce(p_ng_sup,0),
      defect_op = p_defect_op, defect_sup = p_defect_sup, headcount = coalesce(p_headcount,0),
      hours = hrs, ot_hours = 0, start_time = p_start_time, end_time = p_end_time, break_min = coalesce(p_break_min,0),
      downtime_min = coalesce(p_downtime,0), downtime_reason = nullif(trim(p_dt_reason),''), note = p_note, last_edit_by = auth.uid()
    where id = p_row_id and report_date = d and line_id = p_line
    returning id into rid;
    if rid is null then raise exception 'Không tìm thấy dòng báo cáo % của line % ngày % để sửa', p_row_id, p_line, to_char(d,'DD/MM'); end if;
  else
    insert into production_reports(report_date, line_id, product_code, plan_qty, good_qty, ng_op, ng_sup, defect_op, defect_sup,
       headcount, hours, ot_hours, start_time, end_time, break_min, downtime_min, downtime_reason, note, order_batch_id, created_by, last_edit_by)
    values (d, p_line, p_product, pl, coalesce(p_good,0), coalesce(p_ng_op,0), coalesce(p_ng_sup,0), p_defect_op, p_defect_sup,
       coalesce(p_headcount,0), hrs, 0, p_start_time, p_end_time, coalesce(p_break_min,0), coalesce(p_downtime,0), nullif(trim(p_dt_reason),''), p_note, p_order_batch_id, auth.uid(), auth.uid())
    returning id into rid;
  end if;
  return rid;
end $$;

revoke execute on function public.save_prod_row(date,int,text,int,int,int,int,int,int,numeric,time,time,int,int,text,text,bigint,bigint) from anon, public;
grant execute on function public.save_prod_row(date,int,text,int,int,int,int,int,int,numeric,time,time,int,int,text,text,bigint,bigint) to authenticated;

-- Kiểm tra sau khi chạy:
-- select column_name from information_schema.columns where table_name='production_reports' and column_name in ('start_time','end_time','break_min');
-- select proname, pronargs from pg_proc where proname = 'save_prod_row'; -- pronargs = 18
