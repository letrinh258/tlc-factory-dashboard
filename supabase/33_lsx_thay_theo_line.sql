-- =====================================================================
-- GĐ24: Sửa lỗi "dán lệnh SX nhiều line bị mất" — lsx_begin_replace() cũ
-- xóa TOÀN BỘ lệnh sản xuất của CẢ NGÀY đó mỗi lần dán, nên khi anh dán
-- lệnh Line 1 xong rồi dán tiếp lệnh Line 2 (2 lần dán riêng, cùng ngày),
-- lần dán sau xóa sạch luôn lệnh Line 1 vừa lưu trước đó.
--
-- Sửa: chỉ xóa lệnh của ĐÚNG NHỮNG LINE có trong lượt dán đang thực hiện,
-- giữ nguyên lệnh của các line khác trong cùng ngày. Nút "Xóa lệnh SX
-- ngày này" (xóa toàn bộ, chỉ Admin) vẫn gọi hàm này nhưng KHÔNG truyền
-- p_lines (null = xóa cả ngày, như cũ).
-- =====================================================================

drop function if exists public.lsx_begin_replace(date);

create or replace function public.lsx_begin_replace(p_date date, p_lines int[] default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_admin() or public.in_dept(public.dept_id_of('KHSX'))) then
    raise exception 'Không có quyền nhập lệnh sản xuất'; end if;
  perform set_config('app.lsx_batch_del', '1', true);
  if p_lines is null then
    delete from production_order_batches where order_date = p_date;
  else
    delete from production_order_batches where order_date = p_date and line_id = any(p_lines);
  end if;
end $$;
grant execute on function public.lsx_begin_replace(date, int[]) to authenticated;

-- Kiểm tra sau khi chạy:
-- select proname, pronargs from pg_proc where proname = 'lsx_begin_replace'; -- pronargs = 2
