-- =====================================================================
-- GĐ7b: Lệnh sản xuất theo ngày (KHSX giao mã + SL kế hoạch cho từng
-- line/ngày) — Form A (Sản xuất) sẽ cho tổ trưởng CHỌN từ danh sách lệnh
-- này thay vì tự gõ mã sản phẩm, SL kế hoạch lấy thẳng từ lệnh.
-- Chạy sau 12_ke_hoach_po.sql, trong Supabase SQL Editor.
-- Dán lại cùng ngày sẽ XÓA và NẠP LẠI toàn bộ lệnh SX ngày đó (giống
-- Tồn kho) — vì lệnh SX là 1 kế hoạch chốt cho ngày đó, không phải log.
-- =====================================================================

create table if not exists public.production_orders(
  id bigserial primary key,
  order_date date not null,
  line_id int not null,
  item_code text not null,
  qty_planned numeric not null default 0,
  note text,
  source text not null default 'manual',
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (order_date, line_id, item_code)
);
create index if not exists idx_porders_date on public.production_orders(order_date, line_id);

alter table public.production_orders enable row level security;

drop policy if exists dept_read on public.production_orders;
drop policy if exists dept_write on public.production_orders;
-- SX cần đọc để tổ trưởng chọn lệnh khi nhập Form A; KHSX đọc/ghi để lập kế hoạch
create policy dept_read on public.production_orders for select to authenticated
  using (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')) or public.in_dept(public.dept_id_of('SX')));
create policy dept_write on public.production_orders for all to authenticated
  using (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')))
  with check (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')));

-- Kiểm tra sau khi chạy:
-- select count(*) from pg_policies where tablename = 'production_orders';
