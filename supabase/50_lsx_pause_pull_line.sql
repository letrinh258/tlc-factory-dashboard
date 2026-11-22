-- =====================================================================
-- GĐ47 (22/11): 2 tính năng mới cho phân hệ Kế hoạch (KHSX).
--
-- 1) "TẠM DỪNG LỆNH" — cho 1 mã hàng trong lệnh, khi đang sản xuất dở mà
--    phải dừng vì 1 trong 2 lý do:
--    a. "Hàng lỗi chờ xử lý": SL đã làm được TÍNH LÀ ĐẠT 100% KH (giảm
--       KH xuống đúng bằng SL đã làm) — phần còn thiếu KHÔNG bị chuyển
--       đi đâu (không tính là nợ kế hoạch), KHSX tự quyết định lập lại
--       kế hoạch cho phần còn lại khi xử lý xong hàng lỗi.
--    b. "Đổi lệnh gấp cho lệnh khác": phần còn thiếu được CHUYỂN SANG
--       LỆNH NGÀY MAI (giữ nguyên mã lệnh) — dùng lại đúng cơ chế
--       _lsx_defer_core() đã có từ GĐ42 (chuyển thiếu tự động/thủ công).
--    Cả 2 trường hợp đều lưu lại SL kế hoạch GỐC (orig_qty_planned) và lý
--    do + ghi chú (pause_reason/pause_note/paused_at) để không mất dấu
--    vết — KH hiển thị (đã giảm) vẫn là con số dùng để tính % hoàn thành
--    và hiển thị ở cả Kế hoạch lẫn Form A (vì Form A đã lấy KH trực tiếp
--    từ production_order_batches/production_orders từ GĐ43/45).
--
-- 2) "KÉO LỆNH TỪ LINE KHÁC" — line nào rảnh có thể kéo NGUYÊN 1 lệnh của
--    line khác (cùng ngày) về làm, miễn lệnh đó CHƯA sản xuất (chưa có
--    SL đạt nào ở bất kỳ mã nào trong lệnh — kiểm tra qua production_
--    reports). Khi kéo, lệnh đó đổi hẳn line_id sang line đích, giữ
--    nguyên mã lệnh/ngày/số lượng — không tạo lệnh mới, không ảnh hưởng
--    tới UNIQUE(code, order_date) vì chỉ đổi line_id của đúng hàng đó.
-- =====================================================================

alter table public.production_orders
  add column if not exists pause_reason text,      -- 'defect' | 'switch' | null
  add column if not exists pause_note text,
  add column if not exists orig_qty_planned numeric,
  add column if not exists paused_at timestamptz;

alter table public.production_orders
  drop constraint if exists production_orders_pause_reason_check;
alter table public.production_orders
  add constraint production_orders_pause_reason_check
  check (pause_reason is null or pause_reason in ('defect','switch'));

create or replace function public.lsx_pause_order(p_item_id bigint, p_reason text, p_note text default null, p_qty_actual numeric default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_item record; v_actual numeric; v_remain numeric; v_dst bigint;
begin
  if not (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')) or public.in_dept(public.dept_id_of('SX'))) then
    raise exception 'Không có quyền tạm dừng lệnh'; end if;
  if p_reason not in ('defect','switch') then raise exception 'Lý do tạm dừng không hợp lệ'; end if;
  select o.id, o.item_code, o.qty_planned, o.batch_id into v_item from production_orders o where o.id = p_item_id;
  if not found then raise exception 'Không tìm thấy dòng mã hàng'; end if;
  select coalesce(sum(good_qty),0) into v_actual from production_reports where order_batch_id = v_item.batch_id and product_code = v_item.item_code;
  if p_qty_actual is not null then v_actual := p_qty_actual; end if;
  v_remain := v_item.qty_planned - v_actual;
  if v_remain <= 0 then raise exception 'Lệnh đã đạt đủ hoặc vượt kế hoạch (đã làm %), không cần tạm dừng', v_actual; end if;

  if p_reason = 'switch' then
    -- Đổi lệnh gấp: dùng lại cơ chế chuyển thiếu sang ngày mai sẵn có.
    v_dst := public._lsx_defer_core(p_item_id, v_remain, v_item.qty_planned, v_actual);
  else
    -- Hàng lỗi chờ xử lý: KHÔNG chuyển đi đâu — chỉ giảm KH xuống đúng
    -- SL đã làm, để tính đạt 100% (không bị chấm thiếu hàng oan).
    update production_orders set qty_planned = v_actual where id = p_item_id;
    update production_order_batches b set
      item_count = (select count(*) from production_orders where batch_id = b.id),
      qty_total = (select coalesce(sum(qty_planned),0) from production_orders where batch_id = b.id)
    where b.id = v_item.batch_id;
  end if;

  update production_orders set
    pause_reason = p_reason,
    pause_note = p_note,
    orig_qty_planned = coalesce(orig_qty_planned, v_item.qty_planned),
    paused_at = now()
  where id = p_item_id;
  return v_dst;
end $$;
revoke execute on function public.lsx_pause_order(bigint,text,text,numeric) from anon, public;
grant execute on function public.lsx_pause_order(bigint,text,text,numeric) to authenticated;

create or replace function public.lsx_pull_line(p_batch_id bigint, p_to_line_id smallint)
returns void
language plpgsql security definer set search_path = public as $$
declare v_batch record; v_actual numeric; v_from_line text; v_to_line text;
begin
  if not (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')) or public.in_dept(public.dept_id_of('SX'))) then
    raise exception 'Không có quyền kéo lệnh sang line khác'; end if;
  select * into v_batch from production_order_batches where id = p_batch_id;
  if not found then raise exception 'Không tìm thấy lệnh'; end if;
  if v_batch.line_id = p_to_line_id then raise exception 'Lệnh đã thuộc line này'; end if;
  select coalesce(sum(good_qty),0) into v_actual from production_reports where order_batch_id = p_batch_id;
  if v_actual > 0 then raise exception 'Lệnh đã sản xuất % sản phẩm, không thể kéo sang line khác', v_actual; end if;
  select name into v_from_line from production_lines where id = v_batch.line_id;
  select name into v_to_line from production_lines where id = p_to_line_id;
  update production_order_batches set
    line_id = p_to_line_id,
    note = trim(both ' ' from coalesce(note,'') || ' Đã kéo từ ' || coalesce(v_from_line,'line #'||v_batch.line_id) ||
           ' sang ' || coalesce(v_to_line,'line #'||p_to_line_id) ||
           ' lúc ' || to_char(now() at time zone 'Asia/Ho_Chi_Minh','DD/MM HH24:MI') || '.')
  where id = p_batch_id;
end $$;
revoke execute on function public.lsx_pull_line(bigint,smallint) from anon, public;
grant execute on function public.lsx_pull_line(bigint,smallint) to authenticated;
