-- =====================================================================
-- GĐ12: Thêm Sửa/Xóa cho các màn còn thiếu (Bảo hành, HCNS, Kỹ thuật/ECR,
-- Tồn kho, Lệnh SX). Theo yêu cầu của anh 02/11:
--   "Chỉ admin được xóa. Còn lại các thành viên khác chỉ được sửa."
-- (Giao việc/Tasks GIỮ NGUYÊN cơ chế duyệt hạn hiện tại — không đổi.)
--
-- Rà soát trước khi viết file này cho thấy:
--   - inventory_snapshots: đã có policy admin_delete (10_ton_kho.sql) — ĐỦ,
--     không cần SQL mới, chỉ thêm nút Xóa ở index.html.
--   - hr_reports: đã có policy admin_delete (01_tlc_schema.sql, dòng ~632,
--     sinh tự động theo loop Form báo cáo chuyên môn) — ĐỦ, chỉ thêm nút
--     Xóa ở index.html.
--   - purchase_batches (PO): đã có nút Xóa admin-only + xóa trực tiếp đúng
--     — KHÔNG cần đổi.
--   - warranty_batches, production_order_batches: policy "dept_write for
--     all" hiện cho phép BHM/BHN (hoặc KHSX) tự xóa trực tiếp qua API —
--     CHƯA đúng yêu cầu "chỉ admin xóa". Thêm trigger chặn xóa trực tiếp
--     (chỉ admin hoặc qua RPC "..._begin_replace" khi dán lại = sửa dữ
--     liệu tháng/ngày đó) + nút Xóa admin-only riêng (không dán lại).
--   - ecr: CHƯA có policy update/delete nào — thêm RPC ecr_edit (chủ phiếu
--     hoặc admin, chỉ khi còn "pending") + policy xóa admin-only (chỉ
--     "pending" — không xóa phiếu đã duyệt/từ chối vì đã thành lịch sử).
-- Chạy lại được (idempotent với DROP...IF EXISTS / CREATE OR REPLACE).
-- =====================================================================

-- ---------- BẢO HÀNH: chặn xóa trực tiếp, chỉ admin hoặc qua RPC dán lại ----------
create or replace function public.tg_guard_warranty_delete() returns trigger language plpgsql as $$
begin
  if not (public.is_admin() or coalesce(current_setting('app.wh_batch_del', true), '') = '1') then
    raise exception 'Chỉ Admin được xóa dữ liệu bảo hành. Dùng "Dán lại / cập nhật" để sửa tháng này.';
  end if;
  return old;
end $$;
drop trigger if exists trg_guard_warranty_delete on public.warranty_batches;
create trigger trg_guard_warranty_delete before delete on public.warranty_batches for each row execute function public.tg_guard_warranty_delete();

create or replace function public.warranty_begin_replace(p_month date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_admin() or public.in_dept(public.dept_id_of('BHM')) or public.in_dept(public.dept_id_of('BHN'))) then
    raise exception 'Không có quyền nhập dữ liệu bảo hành'; end if;
  perform set_config('app.wh_batch_del', '1', true);
  delete from warranty_batches where report_month = p_month and channel = 'ALL';
end $$;
grant execute on function public.warranty_begin_replace(date) to authenticated;

-- ---------- LỆNH SX: chặn xóa trực tiếp, chỉ admin hoặc qua RPC dán lại ----------
create or replace function public.tg_guard_lsx_delete() returns trigger language plpgsql as $$
begin
  if not (public.is_admin() or coalesce(current_setting('app.lsx_batch_del', true), '') = '1') then
    raise exception 'Chỉ Admin được xóa lệnh sản xuất. Dùng "Dán lại / cập nhật" để sửa ngày này.';
  end if;
  return old;
end $$;
drop trigger if exists trg_guard_lsx_delete on public.production_order_batches;
create trigger trg_guard_lsx_delete before delete on public.production_order_batches for each row execute function public.tg_guard_lsx_delete();

create or replace function public.lsx_begin_replace(p_date date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_admin() or public.in_dept(public.dept_id_of('KHSX'))) then
    raise exception 'Không có quyền nhập lệnh sản xuất'; end if;
  perform set_config('app.lsx_batch_del', '1', true);
  delete from production_order_batches where order_date = p_date;
end $$;
grant execute on function public.lsx_begin_replace(date) to authenticated;

-- ---------- KỸ THUẬT (ECR): sửa khi còn "pending", xóa chỉ admin + "pending" ----------
create or replace function public.ecr_edit(p_id bigint, p_content text, p_reason text, p_product_code text, p_new_code text, p_new_name text, p_new_norm numeric) returns void
language plpgsql security definer set search_path = public as $$
declare r public.ecr;
begin
  select * into r from public.ecr where id = p_id; if not found then raise exception 'Không tìm thấy phiếu ECR'; end if;
  if r.status <> 'pending' then raise exception 'Chỉ sửa được phiếu đang chờ duyệt'; end if;
  if not (public.is_admin() or r.proposed_by = auth.uid()) then raise exception 'Chỉ người đề xuất hoặc Admin được sửa phiếu này'; end if;
  if coalesce(trim(p_content), '') = '' then raise exception 'Nhập nội dung đề xuất'; end if;
  if r.change_type = 'new_product' then
    if coalesce(trim(p_new_code), '') = '' or coalesce(trim(p_new_name), '') = '' then raise exception 'Nhập mã và tên sản phẩm mới'; end if;
    update public.ecr set content = trim(p_content), reason = nullif(trim(p_reason), ''), new_code = trim(p_new_code), new_name = trim(p_new_name), new_norm = p_new_norm where id = p_id;
  else
    if coalesce(trim(p_product_code), '') = '' then raise exception 'Nhập mã sản phẩm liên quan'; end if;
    if r.change_type = 'norm' and p_new_norm is null then raise exception 'Nhập định mức mới'; end if;
    update public.ecr set content = trim(p_content), reason = nullif(trim(p_reason), ''), product_code = trim(p_product_code), new_norm = p_new_norm where id = p_id;
  end if;
end $$;
revoke execute on function public.ecr_edit(bigint,text,text,text,text,text,numeric) from anon;
grant execute on function public.ecr_edit(bigint,text,text,text,text,text,numeric) to authenticated;

drop policy if exists ecr_delete on public.ecr;
create policy ecr_delete on public.ecr for delete to authenticated using (public.is_admin() and status = 'pending');

-- Kiểm tra sau khi chạy:
-- select tgname from pg_trigger where tgrelid in ('public.warranty_batches'::regclass,'public.production_order_batches'::regclass);
-- select proname from pg_proc where proname in ('warranty_begin_replace','lsx_begin_replace','ecr_edit');
-- select count(*) from pg_policies where tablename='ecr' and policyname='ecr_delete';
