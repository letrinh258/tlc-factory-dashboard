-- =====================================================================
-- Hotline (QAC): thêm "Hạn trả lời" cho phần khắc phục (đối sách). Theo
-- yêu cầu của anh 02/11: MỌI thay đổi hạn trả lời đều phải qua Admin
-- (GĐNM) duyệt — không cho sửa trực tiếp trên dòng dữ liệu như các cột
-- khác. Mẫu theo đúng cơ chế đề nghị/duyệt đã dùng ở ECR (17_ky_thuat_ecr.sql).
-- Chạy lại được (idempotent với ALTER...IF NOT EXISTS / CREATE OR REPLACE).
-- =====================================================================

alter table public.hotline_issues add column if not exists response_due date; -- Hạn trả lời (đổi phải qua đề nghị + Admin duyệt)

create table if not exists public.hotline_due_requests(
  id bigserial primary key,
  issue_id bigint not null references public.hotline_issues(id) on delete cascade,
  old_due date,
  new_due date not null,
  reason text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  requested_by uuid default auth.uid() references public.profiles(id),
  requested_at timestamptz not null default now(),
  decided_by uuid references public.profiles(id),
  decided_at timestamptz,
  decide_note text
);
alter table public.hotline_due_requests enable row level security;
revoke all on public.hotline_due_requests from anon;
-- Chỉ đọc trực tiếp (để hiện yêu cầu đang chờ duyệt); mọi ghi đều qua RPC bên dưới.
drop policy if exists hdr_read on public.hotline_due_requests;
create policy hdr_read on public.hotline_due_requests for select to authenticated using (public.is_active_user());

-- Chặn sửa trực tiếp cột response_due qua .update() thường — chỉ cho phép khi RPC bên
-- dưới bật cờ phiên app.hl_due_rpc='1' ngay trước khi ghi.
create or replace function public.tg_guard_hotline_due() returns trigger language plpgsql as $$
begin
  if new.response_due is distinct from old.response_due and coalesce(current_setting('app.hl_due_rpc', true), '') <> '1' then
    raise exception 'Đổi hạn trả lời phải qua đề nghị và được Admin duyệt, không sửa trực tiếp.';
  end if;
  return new;
end $$;
drop trigger if exists trg_guard_hotline_due on public.hotline_issues;
create trigger trg_guard_hotline_due before update on public.hotline_issues for each row execute function public.tg_guard_hotline_due();

-- Đề nghị đổi hạn trả lời. QAC/Admin gọi được; nếu người gọi là Admin thì áp dụng
-- ngay (đã là người duyệt); nếu không, tạo yêu cầu "chờ duyệt" cho Admin xử lý sau.
create or replace function public.hotline_request_due(p_issue_id bigint, p_new_due date, p_reason text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_old date; v_id bigint;
begin
  if not (public.is_admin() or public.in_dept(public.dept_id_of('QAC'))) then
    raise exception 'Không có quyền đổi hạn trả lời hotline'; end if;
  if p_new_due is null then raise exception 'Chọn hạn trả lời mới'; end if;
  select response_due into v_old from hotline_issues where id = p_issue_id;
  if not found then raise exception 'Không tìm thấy vấn đề hotline'; end if;
  insert into hotline_due_requests(issue_id, old_due, new_due, reason, status, requested_by)
    values (p_issue_id, v_old, p_new_due, nullif(trim(p_reason),''), case when public.is_admin() then 'approved' else 'pending' end, auth.uid())
    returning id into v_id;
  if public.is_admin() then
    perform set_config('app.hl_due_rpc','1', true);
    update hotline_issues set response_due = p_new_due, updated_at = now() where id = p_issue_id;
    update hotline_due_requests set decided_by = auth.uid(), decided_at = now(), decide_note = 'Admin tự đặt hạn' where id = v_id;
  end if;
  return v_id;
end $$;

-- Admin duyệt/từ chối yêu cầu đổi hạn đang chờ.
create or replace function public.hotline_decide_due(p_id bigint, p_action text, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare r hotline_due_requests;
begin
  if not public.is_admin() then raise exception 'Chỉ Admin được duyệt đổi hạn trả lời'; end if;
  select * into r from hotline_due_requests where id = p_id; if not found then raise exception 'Không tìm thấy yêu cầu'; end if;
  if r.status <> 'pending' then raise exception 'Yêu cầu đã được xử lý'; end if;
  if p_action = 'approve' then
    perform set_config('app.hl_due_rpc','1', true);
    update hotline_issues set response_due = r.new_due, updated_at = now() where id = r.issue_id;
    update hotline_due_requests set status='approved', decided_by=auth.uid(), decided_at=now(), decide_note=p_note where id = p_id;
  elsif p_action = 'reject' then
    update hotline_due_requests set status='rejected', decided_by=auth.uid(), decided_at=now(), decide_note=p_note where id = p_id;
  else raise exception 'Thao tác không hợp lệ'; end if;
end $$;

grant execute on function public.hotline_request_due(bigint,date,text) to authenticated;
grant execute on function public.hotline_decide_due(bigint,text,text) to authenticated;

-- Kiểm tra sau khi chạy:
-- select column_name from information_schema.columns where table_name='hotline_issues' and column_name='response_due';
-- select proname from pg_proc where proname in ('hotline_request_due','hotline_decide_due','tg_guard_hotline_due');
-- select tgname from pg_trigger where tgrelid = 'public.hotline_issues'::regclass and tgname='trg_guard_hotline_due';
