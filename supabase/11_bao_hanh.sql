-- =====================================================================
-- GĐ6d: Bảo hành theo tháng (dán "Bảng kê phiếu sửa chữa hàng bảo hành"
-- xuất từ Bravo/nội bộ — có nhiều cột "Nguyên nhân: <tên lỗi>" tùy tháng)
-- Chạy sau 10_ton_kho.sql, trong Supabase SQL Editor.
-- Khác với Tồn kho (upsert theo dòng), ở đây 1 lần dán = 1 THÁNG, dán lại
-- cùng tháng sẽ XÓA và NẠP LẠI toàn bộ tháng đó (mỗi dòng không có mã
-- định danh ổn định để upsert riêng — chỉ có STT, Mặt hàng dạng tên chữ).
-- =====================================================================

create table if not exists public.warranty_batches(
  id bigserial primary key,
  report_month date not null,              -- luôn để ngày 01 của tháng báo cáo
  channel text not null default 'ALL' check (channel in ('ALL','BHM','BHN')),
  total_claims int not null default 0,
  total_qty numeric not null default 0,
  source text not null default 'file',
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (report_month, channel)
);

create table if not exists public.warranty_claims(
  id bigserial primary key,
  batch_id bigint not null references public.warranty_batches(id) on delete cascade,
  stt text,
  customer text,
  address text,
  item_name text not null,
  unit text,
  prod_month text,              -- "Tháng sản xuất" dạng text vd "09/2026"
  qty_sent numeric not null default 0,
  qty_received numeric not null default 0,
  total_qty numeric not null default 0
);
create index if not exists idx_wclaims_batch on public.warranty_claims(batch_id);

create table if not exists public.warranty_claim_causes(
  id bigserial primary key,
  claim_id bigint not null references public.warranty_claims(id) on delete cascade,
  cause text not null,
  qty numeric not null default 0
);
create index if not exists idx_wcauses_claim on public.warranty_claim_causes(claim_id);

alter table public.warranty_batches enable row level security;
alter table public.warranty_claims enable row level security;
alter table public.warranty_claim_causes enable row level security;

drop policy if exists dept_read on public.warranty_batches;
drop policy if exists dept_write on public.warranty_batches;
drop policy if exists admin_delete on public.warranty_batches;
create policy dept_read on public.warranty_batches for select to authenticated
  using (public.is_admin() or public.in_dept(public.dept_id_of('BHM')) or public.in_dept(public.dept_id_of('BHN')) or public.in_dept(public.dept_id_of('KTGT')));
create policy dept_write on public.warranty_batches for all to authenticated
  using (public.is_admin() or public.in_dept(public.dept_id_of('BHM')) or public.in_dept(public.dept_id_of('BHN')))
  with check (public.is_admin() or public.in_dept(public.dept_id_of('BHM')) or public.in_dept(public.dept_id_of('BHN')));

drop policy if exists claims_rw on public.warranty_claims;
create policy claims_rw on public.warranty_claims for all to authenticated
  using (exists(select 1 from public.warranty_batches b where b.id = batch_id))
  with check (exists(select 1 from public.warranty_batches b where b.id = batch_id
    and (public.is_admin() or public.in_dept(public.dept_id_of('BHM')) or public.in_dept(public.dept_id_of('BHN')))));

drop policy if exists causes_rw on public.warranty_claim_causes;
create policy causes_rw on public.warranty_claim_causes for all to authenticated
  using (exists(select 1 from public.warranty_claims c where c.id = claim_id))
  with check (exists(select 1 from public.warranty_claims c
    join public.warranty_batches b on b.id = c.batch_id where c.id = claim_id
    and (public.is_admin() or public.in_dept(public.dept_id_of('BHM')) or public.in_dept(public.dept_id_of('BHN')))));

-- Tổng hợp sẵn (tính ở client lúc dán, lưu kèm để màn hình không phải join nặng)
alter table public.warranty_batches add column if not exists cause_totals jsonb not null default '{}'::jsonb;
alter table public.warranty_batches add column if not exists item_totals jsonb not null default '{}'::jsonb;

-- Kiểm tra sau khi chạy:
-- select count(*) from pg_policies where tablename in ('warranty_batches','warranty_claims','warranty_claim_causes');
