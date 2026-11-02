-- =====================================================================
-- GĐ6c: Tồn kho TP/LK theo ngày (dán dữ liệu Nhập-Xuất-Tồn xuất từ Bravo)
-- Chạy sau 09_vi_tri.sql, trong Supabase SQL Editor.
-- Lưu ý: file Bravo KHÔNG có đơn giá, nên chưa tính được "giá trị tồn kho
-- tỷ đồng" ở Tổng quan — card đó vẫn là số mẫu cho tới khi có đơn giá.
-- Bảng này phục vụ theo dõi SỐ LƯỢNG tồn theo mã, theo ngày.
-- =====================================================================

create table if not exists public.inventory_snapshots(
  id bigserial primary key,
  snapshot_date date not null,
  warehouse text not null check (warehouse in ('TP','LK')),
  item_code text not null,
  item_name text,
  unit text,
  opening_qty numeric not null default 0,
  in_qty numeric not null default 0,
  out_qty numeric not null default 0,
  closing_qty numeric not null default 0,
  source text not null default 'bravo',
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (snapshot_date, warehouse, item_code)
);
create index if not exists idx_inv_snap_wh_date on public.inventory_snapshots(warehouse, snapshot_date);

alter table public.inventory_snapshots enable row level security;
drop policy if exists dept_read on public.inventory_snapshots;
drop policy if exists dept_insert on public.inventory_snapshots;
drop policy if exists dept_update on public.inventory_snapshots;
drop policy if exists admin_delete on public.inventory_snapshots;
create policy dept_read on public.inventory_snapshots for select to authenticated
  using (public.is_admin() or public.in_dept(public.dept_id_of('KHO')));
create policy dept_insert on public.inventory_snapshots for insert to authenticated
  with check (public.is_admin() or public.in_dept(public.dept_id_of('KHO')));
create policy dept_update on public.inventory_snapshots for update to authenticated
  using (public.is_admin() or public.in_dept(public.dept_id_of('KHO')))
  with check (public.is_admin() or public.in_dept(public.dept_id_of('KHO')));
create policy admin_delete on public.inventory_snapshots for delete to authenticated
  using (public.is_admin());

-- Kiểm tra: select count(*) from pg_policies where tablename='inventory_snapshots';
