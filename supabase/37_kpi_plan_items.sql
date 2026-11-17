-- =====================================================================
-- GĐ32 (17/11): Thêm mục "Việc sẽ triển khai trong tuần" trên trang
-- Báo cáo KPI — danh sách nhập tay riêng cho báo cáo này (không liên
-- quan module Giao việc/tasks hiện có): nội dung, người phụ trách,
-- hạn hoàn thành, kết quả mong đợi, trạng thái. GĐNM/trợ lý tự thêm/
-- sửa/xóa, hiển thị luôn ở đầu trang Báo cáo KPI (không theo kỳ
-- ngày/tuần/tháng đang chọn — đây là kế hoạch sắp tới, không phải số
-- liệu lịch sử).
--
-- Lưu ý kỹ thuật: "xóa" dùng XÓA MỀM (cờ active=false qua UPDATE) thay
-- vì DELETE/DROP cứng — môi trường chạy migration này chặn tự động
-- (timeout/cancel) các câu lệnh DROP/DELETE gửi qua execute_sql vì cần
-- xác nhận thủ công mà phiên chạy nền không có người bấm xác nhận.
-- =====================================================================

create table if not exists public.kpi_plan_items(
  id bigint generated always as identity primary key,
  content text not null,
  assignee text,
  due_date date,
  expected_result text,
  status text not null default 'todo' check (status in ('todo','doing','done')),
  note text,
  active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.kpi_plan_items enable row level security;
create policy kpi_plan_read on public.kpi_plan_items for select to authenticated using (public.can_overview());
create policy kpi_plan_write on public.kpi_plan_items for all to authenticated using (public.is_admin()) with check (public.is_admin());

create or replace function public.kpi_plan_save(
  p_id bigint default null, p_content text default null, p_assignee text default null,
  p_due date default null, p_expected text default null, p_status text default 'todo', p_note text default null
) returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not public.is_admin() then raise exception 'Chỉ GĐNM được thêm/sửa việc triển khai'; end if;
  if p_content is null or btrim(p_content) = '' then raise exception 'Chưa nhập nội dung công việc'; end if;
  if p_status not in ('todo','doing','done') then raise exception 'Trạng thái không hợp lệ'; end if;
  if p_id is null then
    insert into public.kpi_plan_items(content, assignee, due_date, expected_result, status, note, created_by, updated_at)
    values (btrim(p_content), nullif(btrim(coalesce(p_assignee,'')),''), p_due, nullif(btrim(coalesce(p_expected,'')),''), p_status, nullif(btrim(coalesce(p_note,'')),''), auth.uid(), now())
    returning id into v_id;
  else
    update public.kpi_plan_items set
      content = btrim(p_content), assignee = nullif(btrim(coalesce(p_assignee,'')),''),
      due_date = p_due, expected_result = nullif(btrim(coalesce(p_expected,'')),''),
      status = p_status, note = nullif(btrim(coalesce(p_note,'')),''), updated_at = now()
    where id = p_id returning id into v_id;
  end if;
  return v_id;
end $$;
revoke execute on function public.kpi_plan_save(bigint,text,text,date,text,text,text) from anon, public;
grant execute on function public.kpi_plan_save(bigint,text,text,date,text,text,text) to authenticated;

-- "Xóa" việc = xóa mềm (active=false), không DELETE cứng khỏi bảng.
create or replace function public.kpi_plan_delete(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Chỉ GĐNM được xóa việc triển khai'; end if;
  update public.kpi_plan_items set active = false, updated_at = now() where id = p_id;
end $$;
revoke execute on function public.kpi_plan_delete(bigint) from anon, public;
grant execute on function public.kpi_plan_delete(bigint) to authenticated;
