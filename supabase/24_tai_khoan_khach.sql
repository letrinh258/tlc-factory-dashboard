-- =====================================================================
-- GĐ14: Thêm vai trò "Khách" (guest) cho tài khoản quản lý. Theo yêu
-- cầu của anh 03/11: "Tạo cho người mới, vai trò là khách. Lúc đó tôi
-- phân quyền cho xem toàn bộ tổng quan mà không được sửa hoặc do tôi
-- tích phân quyền" — nghĩa là:
--   - Khách KHÔNG thấy menu nào khác ngoài "Tổng quan nhà máy" (không
--     Công việc của tôi/Báo cáo hằng ngày/KPI/3S/Vấn đề/Lịch điều hành
--     như tài khoản Nhân viên thường có mặc định).
--   - Chỉ xem được Tổng quan khi CHÍNH ANH tích ô "Xem Tổng quan" cho
--     tài khoản đó (tái dùng đúng cơ chế user_roles.module='overview'
--     đã có, không cơ chế riêng) — chưa tích thì vào thấy "Chưa có
--     quyền xem", không có menu nào cả.
--   - Không sửa được gì: Khách không có bộ phận/vị trí báo cáo thật
--     nên không có màn nhập liệu nào hiện ra cho họ; Tổng quan vốn
--     chỉ hiển thị số liệu, không có nút sửa.
--
-- 1 phòng ban mới "Khách / Đối tác" (KHACH) + 1 vị trí "Khách" (không
-- gắn mã báo cáo ngày) để tài khoản khách có dept_id/position_id hợp
-- lệ (2 cột này bắt buộc not null trong profiles) mà không lẫn vào
-- bộ phận thật nào. Chạy lại được (idempotent).
-- =====================================================================

insert into public.departments(id, code, name, sort) values (12,'KHACH','Khách / Đối tác',99)
on conflict (id) do update set code = excluded.code, name = excluded.name, sort = excluded.sort;

insert into public.positions(code, name, dept_id, kind, report_code)
  select 'KHACH','Khách',12,'staff',null
  where not exists(select 1 from public.positions where code = 'KHACH');

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('admin','head','staff','guest'));

-- Kiểm tra sau khi chạy:
-- select id,code,name from public.departments where code='KHACH';
-- select code,name,dept_id,kind from public.positions where code='KHACH';
-- select conname, pg_get_constraintdef(oid) from pg_constraint where conname='profiles_role_check';
--
-- LƯU Ý QUAN TRỌNG: Edge Function "admin-users" (file
-- supabase/functions/admin-users/index.ts) cũng đã sửa để chấp nhận
-- role "guest" — phải DEPLOY LẠI function này trên Supabase (Edge
-- Functions → admin-users → dán lại code → Deploy) thì tạo tài khoản
-- "Khách" mới hoạt động được. Chỉ chạy file SQL này KHÔNG đủ.
