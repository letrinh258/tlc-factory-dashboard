-- =====================================================================
-- Module "Lịch điều hành" – cơ chế họp (Giao ban ngày/Tuần/Tháng/Đột xuất).
-- meeting_types: GĐNM thiết lập loại họp 1 lần (tần suất, thành phần).
-- meeting_sessions: mỗi buổi họp cụ thể, nội dung kéo sẵn tính ở client
-- (vấn đề mở, việc quá hạn), TBP ghi chú/quyết định ngay trong phiên.
-- Quyết định họp tự tạo thành "việc" trong module Giao việc đã có —
-- thêm cột meeting_session_id vào tasks để truy vết việc phát sinh từ
-- buổi họp nào.
-- =====================================================================

create table if not exists public.meeting_types(
  id bigserial primary key, name text not null,
  frequency text not null check (frequency in ('daily','weekly','monthly','adhoc')),
  attendees text, dept_id smallint references public.departments(id),
  active boolean not null default true,
  created_by uuid default auth.uid(), created_at timestamptz not null default now()
);
create table if not exists public.meeting_sessions(
  id bigserial primary key, meeting_type_id bigint not null references public.meeting_types(id),
  session_date date not null, issue_id bigint references public.issues(id),
  notes text, status text not null default 'scheduled' check (status in ('scheduled','done')),
  created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(meeting_type_id, session_date)
);
alter table public.tasks add column if not exists meeting_session_id bigint references public.meeting_sessions(id);

alter table public.meeting_types enable row level security;
alter table public.meeting_sessions enable row level security;
revoke all on public.meeting_types from anon;
revoke all on public.meeting_sessions from anon;

create policy mt_read on public.meeting_types for select to authenticated using (public.is_active_user());
create policy mt_write on public.meeting_types for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Phiên họp: ai cũng xem; GĐNM hoặc bất kỳ TBP nào ghi biên bản (giao ban có đủ các TBP tham dự)
create policy ms_read on public.meeting_sessions for select to authenticated using (public.is_active_user());
create policy ms_write on public.meeting_sessions for all to authenticated
  using (public.is_admin() or exists(select 1 from public.departments d where public.is_head_of(d.id)))
  with check (public.is_admin() or exists(select 1 from public.departments d where public.is_head_of(d.id)));

-- Kiểm tra sau khi chạy:
-- select count(*) from pg_policies where tablename in ('meeting_types','meeting_sessions');
-- select column_name from information_schema.columns where table_name='tasks' and column_name='meeting_session_id';
