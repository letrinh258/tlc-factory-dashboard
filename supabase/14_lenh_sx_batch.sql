-- =====================================================================
-- GĐ7c: Lệnh sản xuất có MÃ LỆNH riêng (đầu lệnh LSX-ddmmyy-LL), bên trong
-- gồm nhiều mã hàng + SL kế hoạch — thay cho thiết kế phẳng ở 13_lenh_sx.sql
-- (1 dòng = 1 line+mã, không có khái niệm "lệnh"/mã lệnh).
-- Chạy sau 13_lenh_sx.sql. CHƯA có dữ liệu thật nên xóa bảng cũ, dựng lại
-- theo 2 bảng header (production_order_batches) + items (production_orders).
-- =====================================================================

drop table if exists public.production_orders cascade;

create table if not exists public.production_order_batches(
  id bigserial primary key,
  code text unique not null,              -- LSX-ddmmyy-LL (LL = số line 2 chữ số)
  order_date date not null,
  line_id int not null,
  item_count int not null default 0,
  qty_total numeric not null default 0,
  source text not null default 'paste',
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (order_date, line_id)
);
create index if not exists idx_lsxb_date on public.production_order_batches(order_date, line_id);

create table if not exists public.production_orders(
  id bigserial primary key,
  batch_id bigint not null references public.production_order_batches(id) on delete cascade,
  item_code text not null,
  qty_planned numeric not null default 0,
  unique (batch_id, item_code)
);
create index if not exists idx_porders_batch on public.production_orders(batch_id);

alter table public.production_order_batches enable row level security;
alter table public.production_orders enable row level security;

drop policy if exists dept_read on public.production_order_batches;
drop policy if exists dept_write on public.production_order_batches;
-- SX cần đọc để tổ trưởng chọn lệnh khi nhập Form A; KHSX đọc/ghi để lập kế hoạch
create policy dept_read on public.production_order_batches for select to authenticated
  using (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')) or public.in_dept(public.dept_id_of('SX')));
create policy dept_write on public.production_order_batches for all to authenticated
  using (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')))
  with check (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')));

drop policy if exists items_read on public.production_orders;
drop policy if exists items_write on public.production_orders;
create policy items_read on public.production_orders for select to authenticated
  using (exists(select 1 from public.production_order_batches b where b.id = batch_id
    and (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')) or public.in_dept(public.dept_id_of('SX')))));
create policy items_write on public.production_orders for all to authenticated
  using (exists(select 1 from public.production_order_batches b where b.id = batch_id
    and (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')))))
  with check (exists(select 1 from public.production_order_batches b where b.id = batch_id
    and (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')))));

-- Kiểm tra sau khi chạy:
-- select count(*) from pg_policies where tablename in ('production_order_batches','production_orders');
