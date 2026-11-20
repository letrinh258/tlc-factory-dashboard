-- =====================================================================
-- GĐ42 (20/11): TỰ ĐỘNG chuyển phần sản lượng THIẾU so với kế hoạch
-- sang lệnh ngày mai (giữ nguyên mã lệnh) + GHI CHÚ trên lệnh đích.
--
-- Ví dụ: KH hôm nay mã A 1.000pcs, chỉ làm được 900pcs → mỗi đêm (00:05
-- giờ VN) hệ thống tự quét, chuyển 100pcs còn thiếu sang lệnh NGÀY MAI,
-- GIỮ NGUYÊN mã lệnh (tận dụng cơ chế GĐ38 — UNIQUE(code,order_date)),
-- tính là kế hoạch chính thức ngày hôm sau; kế hoạch hôm nay tự giảm
-- còn đúng 900 (số đã làm) nên không bị chấm thiếu hàng oan. Lệnh đích
-- được ghi chú vàng: "Gồm 100 sp mã ... chuyển từ lệnh ngày .../... chưa
-- sản xuất hết (KH 1.000, đã làm 900)." để GĐNM/KHSX biết đây là phần
-- carry-over, không phải kế hoạch gốc.
--
-- 1. production_order_batches: thêm cột note (text) — hiển thị banner
--    vàng trên card lệnh ở cả trang Kế hoạch (KHSX) và Form A (Sản xuất).
-- 2. _lsx_defer_core(item_id, qty, kh, actual): hàm lõi dùng chung, nội
--    bộ (không gate quyền, không lộ ra ngoài) — chuyển qty, set/ghép nối
--    note trên lệnh đích.
-- 3. lsx_defer_shortfall(item_id, qty?): gọi tay từ nút "Chuyển thiếu
--    sang ngày mai" (trang Kế hoạch) — có cổng quyền (is_admin/KHSX/SX),
--    tự tính SL còn thiếu = KH − đã làm (Form A) nếu không truyền qty.
--    THAY THẾ lsx_move_qty cho nút này (lsx_move_qty vẫn giữ cho panel
--    "Kéo từ ngày mai…", không đổi).
-- 4. lsx_auto_defer_day(d date): quét mọi lệnh kind='planned' của ngày
--    d còn thiếu so với Form A, tự chuyển. Không gate quyền (chỉ gọi từ
--    pg_cron hoặc tay qua SQL bởi admin) — không có nút trong giao diện.
-- 5. pg_cron 'lsx-auto-defer-shortfall': chạy '5 17 * * *' (UTC) = 00:05
--    giờ VN hàng ngày, gọi lsx_auto_defer_day(ngày VN vừa kết thúc).
--
-- Đã kiểm thử: dữ liệu cô lập ngày 2099 (KH 1.000 / đã làm 900) → tách
-- đúng 900/100 giữ nguyên mã, note đúng nội dung; chạy lại lần 2 không
-- di chuyển thêm gì (idempotent, an toàn nếu cron chạy trùng).
-- =====================================================================

alter table public.production_order_batches add column if not exists note text;

create or replace function public._lsx_defer_core(p_item_id bigint, p_qty numeric, p_kh numeric, p_actual numeric)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_src record; v_dst_batch_id bigint; v_to_date date; v_note text;
begin
  select o.id, o.batch_id, o.item_code, o.qty_planned, b.code, b.line_id, b.order_date, b.source
    into v_src from production_orders o join production_order_batches b on b.id = o.batch_id where o.id = p_item_id;
  if not found then raise exception 'Không tìm thấy dòng mã hàng'; end if;
  v_to_date := v_src.order_date + 1;
  if p_qty is null or p_qty <= 0 or p_qty > v_src.qty_planned then
    raise exception 'Số lượng chuyển không hợp lệ'; end if;

  select id into v_dst_batch_id from production_order_batches where code = v_src.code and order_date = v_to_date;
  v_note := 'Gồm '||trim(to_char(p_qty,'FM999G999G999'))||' sp mã '||v_src.item_code||' chuyển từ lệnh ngày '||to_char(v_src.order_date,'DD/MM')||
            ' chưa sản xuất hết (KH '||trim(to_char(p_kh,'FM999G999G999'))||', đã làm '||trim(to_char(p_actual,'FM999G999G999'))||').';
  if v_dst_batch_id is not null then
    update production_order_batches set note = case when note is null or note = '' then v_note else note||' '||v_note end where id = v_dst_batch_id;
    if (select line_id from production_order_batches where id = v_dst_batch_id) <> v_src.line_id then
      raise exception 'Lệnh % đã tồn tại ở ngày % nhưng khác line', v_src.code, to_char(v_to_date,'DD/MM');
    end if;
  else
    insert into production_order_batches(code, order_date, line_id, source, kind, note, created_by)
    values (v_src.code, v_to_date, v_src.line_id, v_src.source, 'planned', v_note, auth.uid())
    returning id into v_dst_batch_id;
  end if;

  insert into production_orders(batch_id, item_code, qty_planned)
  values (v_dst_batch_id, v_src.item_code, p_qty)
  on conflict (batch_id, item_code) do update set qty_planned = production_orders.qty_planned + excluded.qty_planned;
  update production_orders set qty_planned = qty_planned - p_qty where id = p_item_id;

  update production_order_batches b set
    item_count = (select count(*) from production_orders where batch_id = b.id),
    qty_total = (select coalesce(sum(qty_planned),0) from production_orders where batch_id = b.id)
  where b.id in (v_dst_batch_id, v_src.batch_id);

  return v_dst_batch_id;
end $$;

create or replace function public.lsx_defer_shortfall(p_item_id bigint, p_qty numeric default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_item record; v_actual numeric; v_remain numeric;
begin
  if not (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')) or public.in_dept(public.dept_id_of('SX'))) then
    raise exception 'Không có quyền chuyển số lượng thiếu'; end if;
  select o.id, o.item_code, o.qty_planned, o.batch_id into v_item from production_orders o where o.id = p_item_id;
  if not found then raise exception 'Không tìm thấy dòng mã hàng'; end if;
  select coalesce(sum(good_qty),0) into v_actual from production_reports where order_batch_id = v_item.batch_id and product_code = v_item.item_code;
  v_remain := v_item.qty_planned - v_actual;
  if p_qty is null then p_qty := v_remain; end if;
  if p_qty > v_remain then raise exception 'Số lượng chuyển vượt quá phần còn thiếu thực tế (%)', v_remain; end if;
  return public._lsx_defer_core(p_item_id, p_qty, v_item.qty_planned, v_actual);
end $$;
revoke execute on function public.lsx_defer_shortfall(bigint,numeric) from anon, public;
grant execute on function public.lsx_defer_shortfall(bigint,numeric) to authenticated;

create or replace function public.lsx_auto_defer_day(p_date date)
returns int
language plpgsql security definer set search_path = public as $$
declare v_row record; v_remain numeric; v_moved int := 0;
begin
  for v_row in
    select o.id, o.qty_planned,
           coalesce((select sum(pr.good_qty) from production_reports pr where pr.order_batch_id = b.id and pr.product_code = o.item_code),0) as actual
    from production_orders o join production_order_batches b on b.id = o.batch_id
    where b.order_date = p_date and b.kind = 'planned' and o.qty_planned > 0
  loop
    v_remain := v_row.qty_planned - v_row.actual;
    if v_remain > 0 then
      perform public._lsx_defer_core(v_row.id, v_remain, v_row.qty_planned, v_row.actual);
      v_moved := v_moved + 1;
    end if;
  end loop;
  return v_moved;
end $$;
revoke execute on function public.lsx_auto_defer_day(date) from anon, public;
grant execute on function public.lsx_auto_defer_day(date) to authenticated;

select cron.schedule(
  'lsx-auto-defer-shortfall',
  '5 17 * * *',  -- UTC = 00:05 giờ VN hàng ngày
  $$select public.lsx_auto_defer_day(((now() at time zone 'Asia/Ho_Chi_Minh')::date) - 1)$$
);
