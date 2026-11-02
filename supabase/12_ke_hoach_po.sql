-- =====================================================================
-- GĐ7a: Kế hoạch – Theo dõi mua hàng (PO) theo đợt, dán trực tiếp từ file
-- "Kế hoạch mua hàng" xuất từ Bravo (cột: Stt, Mã đối tượng, Tên NCC,
-- Mã vật tư, Tên vật tư, Đvt, Số lượng — có dòng tổng theo từng NCC,
-- bỏ qua các dòng đó vì không có Mã vật tư).
-- Khác với Tồn kho/Bảo hành (ghi đè theo kỳ): mỗi lần dán PO là MỘT ĐỢT
-- mua hàng MỚI (không ghi đè đợt cũ) — cộng dồn thành lịch sử các đợt.
-- Chạy sau 11_bao_hanh.sql, trong Supabase SQL Editor.
-- =====================================================================

create table if not exists public.purchase_batches(
  id bigserial primary key,
  order_date date not null,              -- ngày lập đợt kế hoạch mua hàng
  total_items int not null default 0,
  total_suppliers int not null default 0,
  note text,
  source text not null default 'file',
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists public.purchase_items(
  id bigserial primary key,
  batch_id bigint not null references public.purchase_batches(id) on delete cascade,
  stt text,
  supplier_code text,
  supplier_name text,
  item_code text,
  item_name text not null,
  unit text,
  qty numeric not null default 0
);
create index if not exists idx_pitems_batch on public.purchase_items(batch_id);

alter table public.purchase_batches enable row level security;
alter table public.purchase_items enable row level security;

drop policy if exists dept_read on public.purchase_batches;
drop policy if exists dept_write on public.purchase_batches;
create policy dept_read on public.purchase_batches for select to authenticated
  using (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')));
create policy dept_write on public.purchase_batches for all to authenticated
  using (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')))
  with check (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')));

drop policy if exists items_rw on public.purchase_items;
create policy items_rw on public.purchase_items for all to authenticated
  using (exists(select 1 from public.purchase_batches b where b.id = batch_id))
  with check (exists(select 1 from public.purchase_batches b where b.id = batch_id
    and (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')))));

-- GĐNM/admin có thể xóa đợt nhập nhầm; KHSX chỉ thêm/sửa (không xóa) qua dept_write phía trên
-- (dept_write ở trên đã cho phép delete cho cả KHSX — chấp nhận, vì đây là đợt KHSX tự quản lý,
--  giống Tồn kho cho phép KHO tự xóa phiếu của mình).

-- Kiểm tra sau khi chạy:
-- select count(*) from pg_policies where tablename in ('purchase_batches','purchase_items');
