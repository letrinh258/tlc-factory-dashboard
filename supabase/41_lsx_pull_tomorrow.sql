-- =====================================================================
-- GĐ37 (20/11): "Kéo lệnh ngày mai" — khi line làm vượt kế hoạch hôm nay
-- và muốn tranh thủ làm sớm 1 phần lệnh đã lập cho NGÀY MAI (cùng line),
-- thay vì tổ trưởng/KHSX phải tự vào sửa tay kế hoạch ngày mai.
--
-- Quyết định (hỏi qua AskUserQuestion 20/11):
-- - Thao tác ngay trong khu vực nút "Đánh dấu Tranh thủ ngoài KH" (cả ở
--   trang Kế hoạch KHSX lẫn Form A Sản xuất).
-- - Kéo 1 PHẦN số lượng do SX/KHSX tự chọn (không bắt buộc kéo cả lệnh).
-- - Lệnh hôm nay nhận số lượng kéo LUÔN là kind='overflow' — KHÔNG tính
--   vào "% lệnh SX đủ hàng" của hôm nay (giữ nguyên nguyên tắc GĐ33).
--
-- Cơ chế: trừ số lượng đã kéo khỏi dòng mã hàng của lệnh ngày mai (giữ
-- lại dòng dù về 0 — không DELETE — để không mất lịch sử/liên kết), cộng
-- vào dòng mã hàng tương ứng của lệnh hôm nay (gộp nếu đã có).
-- =====================================================================

create or replace function public.lsx_pull_tomorrow(p_target_batch_id bigint, p_source_item_id bigint, p_qty numeric)
returns void
language plpgsql security definer set search_path = public as $$
declare v_target record; v_src record;
begin
  if not (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')) or public.in_dept(public.dept_id_of('SX'))) then
    raise exception 'Không có quyền kéo lệnh ngày mai';
  end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Số lượng kéo phải lớn hơn 0'; end if;

  select * into v_target from production_order_batches where id = p_target_batch_id;
  if not found then raise exception 'Không tìm thấy lệnh hôm nay'; end if;

  select o.id, o.batch_id, o.item_code, o.qty_planned, b.order_date, b.line_id
    into v_src
    from production_orders o join production_order_batches b on b.id = o.batch_id
    where o.id = p_source_item_id;
  if not found then raise exception 'Không tìm thấy dòng mã hàng của lệnh ngày mai'; end if;

  if v_src.order_date <> v_target.order_date + 1 then
    raise exception 'Chỉ kéo được từ lệnh của đúng ngày hôm sau (%)', to_char(v_target.order_date + 1, 'DD/MM/YYYY');
  end if;
  if v_src.line_id <> v_target.line_id then
    raise exception 'Lệnh nguồn (ngày mai) phải cùng line với lệnh hôm nay';
  end if;
  if p_qty > v_src.qty_planned then
    raise exception 'Số lượng kéo (%) vượt quá số lượng còn lại của lệnh ngày mai (%)', p_qty, v_src.qty_planned;
  end if;

  update production_order_batches set kind = 'overflow' where id = p_target_batch_id;

  insert into production_orders(batch_id, item_code, qty_planned)
  values (p_target_batch_id, v_src.item_code, p_qty)
  on conflict (batch_id, item_code) do update set qty_planned = production_orders.qty_planned + excluded.qty_planned;

  update production_orders set qty_planned = qty_planned - p_qty where id = p_source_item_id;

  update production_order_batches b set
    item_count = (select count(*) from production_orders where batch_id = b.id),
    qty_total = (select coalesce(sum(qty_planned),0) from production_orders where batch_id = b.id)
  where b.id in (p_target_batch_id, v_src.batch_id);
end $$;
revoke execute on function public.lsx_pull_tomorrow(bigint,bigint,numeric) from anon, public;
grant execute on function public.lsx_pull_tomorrow(bigint,bigint,numeric) to authenticated;
