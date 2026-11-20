-- =====================================================================
-- GĐ35 (20/11): Sửa lỗi "nhập lệnh SX hôm nay, mai xem lại bị mất".
--
-- Nguyên nhân (kiểm tra nhật ký 16/11 13:18–13:39): mỗi lần dán, màn
-- Lệnh SX gọi lsx_begin_replace(ngày, line) → XÓA TOÀN BỘ lệnh của line
-- đó trong ngày, rồi mới chèn lệnh vừa dán. KHSX dán TỪNG LỆNH một (mỗi
-- lệnh Bravo là 1 mã) nên lệnh dán sau xóa mất lệnh dán trước cùng
-- line/ngày — cuối cùng chỉ còn lệnh dán cuối. Ngoài ra lưu không trọn
-- gói: xóa xong mà chèn lỗi (vd trùng mã lệnh) thì mất cả lệnh cũ.
--
-- Sửa:
-- 1) lsx_save(ngày, danh sách dòng): CHỈ THÊM MỚI / CẬP NHẬT đúng các
--    mã lệnh có trong lượt dán, KHÔNG đụng lệnh khác. Chạy trong 1
--    giao dịch (lỗi bất kỳ dòng nào → không lưu gì, không mất gì).
--    Mã lệnh đã tồn tại: cập nhật lại mã SP/số lượng; nếu lệnh đó đã
--    có báo cáo sản xuất (Form A) ở ngày/line khác thì báo lỗi rõ ràng.
-- 2) lsx_delete(lệnh): xóa TỪNG lệnh (KHSX/Admin); lệnh đã có báo cáo
--    sản xuất thì không cho xóa (tránh mất liên kết số liệu).
-- 3) lsx_begin_replace (nút Admin "Xóa lệnh SX ngày này") giữ nguyên,
--    nhưng bỏ qua lệnh đã có báo cáo sản xuất thay vì báo lỗi cả ngày.
-- =====================================================================

create or replace function public.lsx_save(p_date date, p_items jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare
  c record; v_id bigint; v_old record; n_new int := 0; n_upd int := 0; n_rows int := 0;
begin
  if not (public.is_admin() or public.in_dept(public.dept_id_of('KHSX'))) then
    raise exception 'Không có quyền nhập lệnh sản xuất'; end if;
  if p_date is null then raise exception 'Chưa chọn ngày sản xuất'; end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception 'Không có dòng lệnh nào để lưu'; end if;
  -- kiểm tra dữ liệu
  if exists(select 1 from jsonb_array_elements(p_items) e where coalesce(trim(e->>'code'),'') = '' or (e->>'line')::int is null or coalesce(trim(e->>'item'),'') = '') then
    raise exception 'Có dòng thiếu mã lệnh / line / mã sản phẩm'; end if;
  if exists(select 1 from jsonb_array_elements(p_items) e where coalesce((e->>'qty')::numeric,0) <= 0) then
    raise exception 'Có dòng số lượng kế hoạch = 0 hoặc trống'; end if;
  for c in select trim(e->>'code') code, min((e->>'line')::int) line, count(distinct (e->>'line')::int) nline,
                  jsonb_agg(jsonb_build_object('item', trim(e->>'item'), 'qty', (e->>'qty')::numeric)) items
           from jsonb_array_elements(p_items) e group by trim(e->>'code') loop
    if c.nline > 1 then raise exception 'Lệnh % có nhiều line khác nhau trong lượt dán', c.code; end if;
    select id, order_date, line_id into v_old from production_order_batches where code = c.code;
    if found then
      if (v_old.order_date <> p_date or v_old.line_id <> c.line)
         and exists(select 1 from production_reports r where r.order_batch_id = v_old.id) then
        raise exception 'Lệnh % đã có báo cáo sản xuất ngày %/line % — không chuyển sang ngày/line khác được', c.code, to_char(v_old.order_date,'DD/MM'), v_old.line_id;
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
    update production_order_batches b set order_date = p_date, line_id = c.line,
      item_count = (select count(*) from production_orders o where o.batch_id = v_id),
      qty_total = (select coalesce(sum(qty_planned),0) from production_orders o where o.batch_id = v_id)
    where b.id = v_id;
    n_rows := n_rows + jsonb_array_length(c.items);
  end loop;
  return json_build_object('new', n_new, 'updated', n_upd, 'rows', n_rows);
end $$;
revoke execute on function public.lsx_save(date, jsonb) from anon, public;
grant execute on function public.lsx_save(date, jsonb) to authenticated;

create or replace function public.lsx_delete(p_batch_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v_code text;
begin
  if not (public.is_admin() or public.in_dept(public.dept_id_of('KHSX'))) then
    raise exception 'Không có quyền xóa lệnh sản xuất'; end if;
  select code into v_code from production_order_batches where id = p_batch_id;
  if v_code is null then raise exception 'Không tìm thấy lệnh'; end if;
  if exists(select 1 from production_reports r where r.order_batch_id = p_batch_id) then
    raise exception 'Lệnh % đã có báo cáo sản xuất (Form A) — không xóa được. Sửa số lượng bằng cách dán lại lệnh.', v_code; end if;
  perform set_config('app.lsx_batch_del', '1', true);
  delete from production_order_batches where id = p_batch_id;
end $$;
revoke execute on function public.lsx_delete(bigint) from anon, public;
grant execute on function public.lsx_delete(bigint) to authenticated;

create or replace function public.lsx_begin_replace(p_date date, p_lines int[] default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_admin() or public.in_dept(public.dept_id_of('KHSX'))) then
    raise exception 'Không có quyền nhập lệnh sản xuất'; end if;
  perform set_config('app.lsx_batch_del', '1', true);
  delete from production_order_batches b where b.order_date = p_date
    and (p_lines is null or b.line_id = any(p_lines))
    and not exists(select 1 from production_reports r where r.order_batch_id = b.id);
end $$;
grant execute on function public.lsx_begin_replace(date, int[]) to authenticated;
