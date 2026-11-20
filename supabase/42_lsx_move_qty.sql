-- =====================================================================
-- GĐ38 (20/11): Sửa lại "Kéo lệnh ngày mai" (GĐ37) theo phản hồi của
-- anh Trình — bản GĐ37 (lsx_pull_tomorrow) GỘP số lượng kéo vào lệnh
-- hôm nay đang mở, làm MẤT mã đầu lệnh của ngày mai. Yêu cầu đúng:
--
--   "Mã đầu lệnh ngày mai vẫn giữ nguyên. Không được gộp đầu lệnh vào
--   ngày hôm nay. Và làm thêm nút quay lại đầu lệnh ngày mai nếu có
--   kéo nhầm. Lưu ý đầu lệnh không được thay đổi cho dù kéo lên hay
--   đẩy sang ngày khác."
--
-- => Nguyên tắc: MÃ LỆNH LÀ BẤT BIẾN theo mọi hướng di chuyển số lượng
-- (kéo lên hôm nay, hoặc trả lại ngày khác). Khi tách 1 phần số lượng
-- sang ngày khác, phần đó xuất hiện thành 1 LỆNH RIÊNG ở ngày đích,
-- mang ĐÚNG mã lệnh gốc — không gộp vào bất kỳ lệnh nào khác đang có ở
-- ngày đích (trừ khi lệnh đích đó CHÍNH LÀ cùng mã, tức đã từng tách
-- trước đó — khi ấy cộng dồn lại đúng lệnh của nó, không tạo lệnh mới).
--
-- Thay đổi:
-- 1. production_order_batches: nới UNIQUE(code) → UNIQUE(code, order_date)
--    để 1 mã lệnh có thể tồn tại song song ở NHIỀU NGÀY (bị tách).
-- 2. lsx_save / lsx_edit: khớp lệnh theo (code, order_date) thay vì
--    chỉ code — vì code không còn là khóa duy nhất toàn cục.
-- 3. lsx_move_qty(p_item_id, p_qty, p_to_date) THAY THẾ
--    lsx_pull_tomorrow — dùng chung cho cả 2 chiều (kéo lên hôm nay /
--    trả lại ngày khác): tìm lệnh đích CÙNG MÃ + CÙNG LINE ở p_to_date
--    (tạo mới nếu chưa có, giữ nguyên code), cộng p_qty vào dòng mã
--    hàng tương ứng ở đó, trừ p_qty khỏi dòng nguồn (giữ dòng dù về 0,
--    không DELETE). Lệnh đích tạo mới có kind='overflow' nếu đích là
--    HÔM NAY (giữ nguyên tắc GĐ33/37: phần tranh thủ không tính thiếu
--    hàng), ngược lại kind='planned'.
-- 4. lsx_pull_tomorrow bị REVOKE execute (không DROP — môi trường
--    migration chặn DROP/DELETE gửi trực tiếp) — không còn được gọi từ
--    giao diện, giữ lại trong DB chỉ để tham chiếu lịch sử.
--
-- Đã kiểm thử logic bằng dữ liệu test cô lập (production_order_batches
-- id 118/119, ngày 2099, không ảnh hưởng dữ liệu thật) trước khi deploy
-- bản có cổng quyền.
-- =====================================================================

alter table public.production_order_batches drop constraint production_order_batches_code_key;
alter table public.production_order_batches add constraint production_order_batches_code_date_key unique (code, order_date);

revoke execute on function public.lsx_pull_tomorrow(bigint,bigint,numeric) from authenticated;

create or replace function public.lsx_move_qty(p_item_id bigint, p_qty numeric, p_to_date date)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_src record; v_dst_batch_id bigint; v_dst_kind text;
begin
  if not (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')) or public.in_dept(public.dept_id_of('SX'))) then
    raise exception 'Không có quyền chuyển số lượng lệnh';
  end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Số lượng chuyển phải lớn hơn 0'; end if;
  if p_to_date is null then raise exception 'Chọn ngày đích'; end if;

  select o.id, o.batch_id, o.item_code, o.qty_planned, b.code, b.line_id, b.order_date, b.source
    into v_src
    from production_orders o join production_order_batches b on b.id = o.batch_id
    where o.id = p_item_id;
  if not found then raise exception 'Không tìm thấy dòng mã hàng'; end if;

  if p_to_date = v_src.order_date then raise exception 'Ngày đích phải khác ngày hiện tại của lệnh'; end if;
  if p_qty > v_src.qty_planned then
    raise exception 'Số lượng chuyển (%) vượt quá số lượng còn lại (%)', p_qty, v_src.qty_planned;
  end if;

  -- Mã lệnh KHÔNG đổi dù chuyển đi đâu — tìm lệnh đích CÙNG MÃ, cùng
  -- line, ở ngày đích; tạo mới (giữ nguyên code) nếu chưa có.
  select id into v_dst_batch_id from production_order_batches
    where code = v_src.code and order_date = p_to_date;

  if v_dst_batch_id is not null then
    if (select line_id from production_order_batches where id = v_dst_batch_id) <> v_src.line_id then
      raise exception 'Lệnh % đã tồn tại ở ngày % nhưng khác line', v_src.code, to_char(p_to_date,'DD/MM');
    end if;
  else
    v_dst_kind := case when p_to_date = current_date then 'overflow' else 'planned' end;
    insert into production_order_batches(code, order_date, line_id, source, kind, created_by)
    values (v_src.code, p_to_date, v_src.line_id, v_src.source, v_dst_kind, auth.uid())
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
revoke execute on function public.lsx_move_qty(bigint,numeric,date) from anon, public;
grant execute on function public.lsx_move_qty(bigint,numeric,date) to authenticated;

-- lsx_save: khớp lệnh hiện có theo (code, order_date) thay vì chỉ code —
-- định nghĩa đúng như đang chạy thật trên DB (lấy qua pg_get_functiondef
-- để tránh chép sai từ trí nhớ).
create or replace function public.lsx_save(p_date date, p_items jsonb)
returns json
language plpgsql security definer set search_path = public as $$
declare
  c record; v_id bigint; v_old record; n_new int := 0; n_upd int := 0; n_rows int := 0;
begin
  if not (public.is_admin() or public.in_dept(public.dept_id_of('KHSX'))) then
    raise exception 'Không có quyền nhập lệnh sản xuất'; end if;
  if p_date is null then raise exception 'Chưa chọn ngày sản xuất'; end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception 'Không có dòng lệnh nào để lưu'; end if;
  if exists(select 1 from jsonb_array_elements(p_items) e where coalesce(trim(e->>'code'),'') = '' or (e->>'line')::int is null or coalesce(trim(e->>'item'),'') = '') then
    raise exception 'Có dòng thiếu mã lệnh / line / mã sản phẩm'; end if;
  if exists(select 1 from jsonb_array_elements(p_items) e where coalesce((e->>'qty')::numeric,0) <= 0) then
    raise exception 'Có dòng số lượng kế hoạch = 0 hoặc trống'; end if;
  for c in select trim(e->>'code') code, min((e->>'line')::int) line, count(distinct (e->>'line')::int) nline,
                  jsonb_agg(jsonb_build_object('item', trim(e->>'item'), 'qty', (e->>'qty')::numeric)) items
           from jsonb_array_elements(p_items) e group by trim(e->>'code') loop
    if c.nline > 1 then raise exception 'Lệnh % có nhiều line khác nhau trong lượt dán', c.code; end if;
    -- GĐ38: khớp theo (mã lệnh, NGÀY) — 1 mã lệnh giờ có thể có nhiều dòng
    -- ở nhiều ngày khác nhau (bị tách do kéo/trả lệnh sang ngày khác), nên
    -- dán lại 1 mã cho ĐÚNG ngày nào chỉ cập nhật đúng dòng của ngày đó.
    select id, order_date, line_id into v_old from production_order_batches where code = c.code and order_date = p_date;
    if found then
      if exists(select 1 from production_reports r where r.order_batch_id = v_old.id and r.line_id <> c.line) then
        raise exception 'Lệnh % ngày % đã có báo cáo sản xuất ở line khác — không chuyển line được', c.code, to_char(p_date,'DD/MM');
      end if;
      v_id := v_old.id;
      delete from production_orders where batch_id = v_id;
      n_upd := n_upd + 1;
    else
      insert into production_order_batches(code, order_date, line_id, item_count, qty_total, source, created_by)
      values (c.code, p_date, c.line, 0, 0, 'paste', auth.uid()) returning id into v_id;
      n_new := n_new + 1;
    end if;
    insert into production_orders(batch_id, item_code, qty_planned)
    select v_id, x->>'item', sum((x->>'qty')::numeric) from jsonb_array_elements(c.items) x group by x->>'item';
    update production_order_batches b set line_id = c.line,
      item_count = (select count(*) from production_orders o where o.batch_id = v_id),
      qty_total = (select coalesce(sum(qty_planned),0) from production_orders o where o.batch_id = v_id)
    where b.id = v_id;
    n_rows := n_rows + jsonb_array_length(c.items);
  end loop;
  return json_build_object('new', n_new, 'updated', n_upd, 'rows', n_rows);
end $$;

-- lsx_edit: cho phép cùng mã lệnh tồn tại ở NHIỀU NGÀY (do kéo/trả) —
-- chỉ chặn trùng đúng (mã lệnh, ngày).
create or replace function public.lsx_edit(p_batch_id bigint, p_code text, p_date date, p_line integer, p_items jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare v_old record; v_used boolean; v_bad text;
begin
  if not (public.is_admin() or public.in_dept(public.dept_id_of('KHSX'))) then
    raise exception 'Không có quyền sửa lệnh sản xuất'; end if;
  select * into v_old from production_order_batches where id = p_batch_id;
  if not found then raise exception 'Không tìm thấy lệnh'; end if;
  if coalesce(trim(p_code),'') = '' then raise exception 'Nhập mã lệnh'; end if;
  if p_date is null or p_line is null then raise exception 'Chọn ngày và tổ/line'; end if;
  if exists(select 1 from production_order_batches where code = trim(p_code) and order_date = p_date and id <> p_batch_id) then
    raise exception 'Mã lệnh % đã có ở lệnh khác cùng ngày %', trim(p_code), to_char(p_date,'DD/MM'); end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception 'Lệnh phải có ít nhất 1 mã sản phẩm'; end if;
  if exists(select 1 from jsonb_array_elements(p_items) e where coalesce((e->>'qty')::numeric,0) <= 0) then
    raise exception 'Số lượng kế hoạch phải lớn hơn 0'; end if;
  select string_agg(distinct trim(e->>'item'), ', ') into v_bad from jsonb_array_elements(p_items) e
    where not exists(select 1 from products p where p.code = trim(e->>'item'));
  if v_bad is not null then raise exception 'Mã sản phẩm không có trong danh mục: %', v_bad; end if;
  v_used := exists(select 1 from production_reports r where r.order_batch_id = p_batch_id);
  if v_used and (p_date <> v_old.order_date or p_line <> v_old.line_id) then
    raise exception 'Lệnh đã có báo cáo sản xuất (Form A) — không đổi ngày/tổ được'; end if;
  if v_used then
    select string_agg(distinct r.product_code, ', ') into v_bad from production_reports r
      where r.order_batch_id = p_batch_id
        and not exists(select 1 from jsonb_array_elements(p_items) e where trim(e->>'item') = r.product_code);
    if v_bad is not null then raise exception 'Không bỏ được mã đã có báo cáo sản xuất: %', v_bad; end if;
  end if;
  delete from production_orders where batch_id = p_batch_id;
  insert into production_orders(batch_id, item_code, qty_planned)
  select p_batch_id, trim(e->>'item'), sum((e->>'qty')::numeric) from jsonb_array_elements(p_items) e group by trim(e->>'item');
  update production_order_batches set code = trim(p_code), order_date = p_date, line_id = p_line,
    item_count = (select count(*) from production_orders where batch_id = p_batch_id),
    qty_total = (select coalesce(sum(qty_planned),0) from production_orders where batch_id = p_batch_id)
  where id = p_batch_id;
end $$;
