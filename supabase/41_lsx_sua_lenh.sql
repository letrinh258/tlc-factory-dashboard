-- =====================================================================
-- GĐ36 (20/11): Sửa lệnh sản xuất (Lịch sử lệnh SX + Lệnh sản xuất).
-- lsx_edit(lệnh, mã lệnh, ngày, line, danh sách mã SP + SL):
--  * KHSX / Admin; chạy trọn gói 1 giao dịch.
--  * Mã lệnh mới không được trùng lệnh khác.
--  * Lệnh đã có báo cáo sản xuất (Form A) → không đổi ngày/line được,
--    và không bỏ được mã SP đã có báo cáo (chỉ sửa SL / thêm mã).
--  * Mã SP phải có trong danh mục; SL > 0.
-- =====================================================================
create or replace function public.lsx_edit(p_batch_id bigint, p_code text, p_date date, p_line int, p_items jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_old record; v_used boolean; v_bad text;
begin
  if not (public.is_admin() or public.in_dept(public.dept_id_of('KHSX'))) then
    raise exception 'Không có quyền sửa lệnh sản xuất'; end if;
  select * into v_old from production_order_batches where id = p_batch_id;
  if not found then raise exception 'Không tìm thấy lệnh'; end if;
  if coalesce(trim(p_code),'') = '' then raise exception 'Nhập mã lệnh'; end if;
  if p_date is null or p_line is null then raise exception 'Chọn ngày và tổ/line'; end if;
  if exists(select 1 from production_order_batches where code = trim(p_code) and id <> p_batch_id) then
    raise exception 'Mã lệnh % đã có ở lệnh khác', trim(p_code); end if;
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
revoke execute on function public.lsx_edit(bigint, text, date, int, jsonb) from anon, public;
grant execute on function public.lsx_edit(bigint, text, date, int, jsonb) to authenticated;
