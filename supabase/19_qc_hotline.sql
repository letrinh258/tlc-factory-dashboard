-- =====================================================================
-- Module QAC – Hotline: theo dõi xử lý vấn đề/khiếu nại phản ánh qua
-- hotline (thị trường/đại lý báo lỗi), theo đúng mẫu "Tổng hợp xử lý
-- vấn đề Hotline" anh gửi 02/11 + trạng thái Mở sự vụ/Đang xử lý/Đã
-- đóng để theo dõi. Bảng mới, không đụng tới các bảng QC Form B đã có
-- (quality_reports/quality_defects) vì đây là vấn đề thị trường phản
-- ánh, khác lỗi kiểm PQC/OQC/IQC nội bộ.
-- =====================================================================

create table if not exists public.hotline_issues(
  id bigserial primary key, code text unique not null,              -- HL-ddmm-NN
  product_code text,                                                 -- Mã SP (tự do, không ép theo danh mục vì hàng thị trường có thể ghi tên thương mại)
  issue_desc text not null,                                          -- Nội dung vấn đề
  cause text,                                                        -- Nguyên nhân
  countermeasure text,                                               -- Đối sách
  response_qty integer,                                              -- Số lượng phản hồi
  dept_id smallint references public.departments(id),                -- Bộ phận phụ trách
  short_term_action text,                                            -- Xử lý ngắn hạn
  long_term_action text,                                             -- Xử lý dài hạn
  status text not null default 'open' check (status in ('open','processing','closed')),
  opened_at date not null default (now() at time zone 'Asia/Ho_Chi_Minh')::date,
  closed_at date,
  created_by uuid default auth.uid() references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.hotline_issues enable row level security;
revoke all on public.hotline_issues from anon;

create policy hl_read on public.hotline_issues for select to authenticated using (public.is_active_user());
-- QAC (ai thuộc phòng QAC) hoặc GĐNM được tạo/sửa/xóa; mọi người active đều xem được (để BP liên quan theo dõi)
create policy hl_write on public.hotline_issues for all to authenticated
  using (public.is_admin() or public.in_dept(public.dept_id_of('QAC')))
  with check (public.is_admin() or public.in_dept(public.dept_id_of('QAC')));

-- Kiểm tra sau khi chạy:
-- select count(*) from pg_policies where tablename = 'hotline_issues';
-- select dept_id_of('QAC');
