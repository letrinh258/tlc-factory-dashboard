-- =====================================================================
-- GĐ19: Mục 1 KHSX (Báo cáo hằng ngày → "Kế hoạch & kết quả hôm nay")
-- đổi từ 6 ô số đơn lẻ sang 3 danh sách theo dòng, MỖI DÒNG LƯU RIÊNG
-- (theo yêu cầu 04/11):
--   1) Đơn có nguy cơ trễ: chọn Mã sản phẩm (danh mục products) → tự ra
--      Tên sản phẩm → nhập SL (pcs). Mỗi sản phẩm 1 dòng riêng.
--   2) Đơn đến hạn giao trong 3 ngày: GIỮ LẠI theo yêu cầu bổ sung, cũng
--      đổi sang dòng Mã sản phẩm → Tên SP → SL → Ngày cần giao.
--   3) Mã vật tư thiếu (3 ngày tới): tách thành mục riêng (vẫn đặt trong
--      mục 1 KHSX) — chọn Mã vật tư (danh mục materials) → tự ra Tên vật
--      tư → SL → Tình trạng/đã triển khai gì.
-- Bỏ khỏi UI: KH sản lượng hôm nay, Thực hiện nhập kho, Thay đổi kế hoạch
-- trong ngày, Ghi chú số liệu/chênh lệch — KHÔNG xóa app_settings.
-- report_metrics.KHSX (giữ nguyên để không vỡ dữ liệu lịch sử các ngày đã
-- nhập trước đây), chỉ ẩn khỏi màn hình (index.html render riêng cho
-- report_code = 'KHSX', các vị trí khác không đổi gì).
-- An toàn: chỉ thêm bảng mới, không đụng gì tới production_reports hay
-- daily_reports.metrics hiện có.
-- =====================================================================

create table if not exists public.khsx_risk_orders(
  id bigserial primary key,
  report_date date not null,
  product_code text not null references public.products(code),
  qty numeric not null check (qty > 0),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);
create index if not exists idx_khsx_risk_date on public.khsx_risk_orders(report_date);

create table if not exists public.khsx_due_orders(
  id bigserial primary key,
  report_date date not null,
  product_code text not null references public.products(code),
  qty numeric not null check (qty > 0),
  due_date date not null,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);
create index if not exists idx_khsx_due_date on public.khsx_due_orders(report_date);

create table if not exists public.khsx_missing_materials(
  id bigserial primary key,
  report_date date not null,
  material_code text not null references public.materials(code),
  qty numeric,
  status_note text not null,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);
create index if not exists idx_khsx_missing_date on public.khsx_missing_materials(report_date);

alter table public.khsx_risk_orders enable row level security;
alter table public.khsx_due_orders enable row level security;
alter table public.khsx_missing_materials enable row level security;

drop policy if exists dept_rw on public.khsx_risk_orders;
create policy dept_rw on public.khsx_risk_orders for all to authenticated
  using (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')))
  with check (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')));

drop policy if exists dept_rw on public.khsx_due_orders;
create policy dept_rw on public.khsx_due_orders for all to authenticated
  using (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')))
  with check (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')));

drop policy if exists dept_rw on public.khsx_missing_materials;
create policy dept_rw on public.khsx_missing_materials for all to authenticated
  using (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')))
  with check (public.is_admin() or public.in_dept(public.dept_id_of('KHSX')));

-- Kiểm tra sau khi chạy:
-- select count(*) from pg_policies where tablename in ('khsx_risk_orders','khsx_due_orders','khsx_missing_materials'); -- = 3
-- select tablename, rowsecurity from pg_tables where tablename in ('khsx_risk_orders','khsx_due_orders','khsx_missing_materials'); -- rowsecurity = true cả 3
