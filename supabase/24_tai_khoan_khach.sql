-- =====================================================================
-- GĐ14: Thêm vai trò "Khách" (guest) cho tài khoản quản lý. Theo yêu
-- cầu của anh 03/11:
--   1) "Tạo cho người mới, vai trò là khách. Lúc đó tôi phân quyền cho
--      xem toàn bộ tổng quan mà không được sửa hoặc do tôi tích phân
--      quyền" — nghĩa là:
--        - Khách KHÔNG thấy menu nào khác ngoài menu Điều hành (xem
--          bước 2) khi CHƯA được tích "Xem Tổng quan".
--        - Chỉ xem được khi CHÍNH ANH tích ô "Xem Tổng quan" cho tài
--          khoản đó (tái dùng đúng cơ chế user_roles.module='overview'
--          đã có, không cơ chế riêng) — chưa tích thì vào thấy "Chưa
--          có quyền xem", không có menu nào cả.
--        - Không sửa được gì: can_edit_code() không cấp quyền sửa cho
--          Khách vì Khách không có report_code/my_report_codes() thật.
--   2) "Nếu chọn vai trò là khách thì bỏ vị trí. Và có thể có nhiều vị
--      trí khách. Vị trí khách thì xem được toàn bộ mục điều hành" —
--      nghĩa là:
--        - KHÔNG còn 1 vị trí "Khách" chung — mỗi tài khoản khách được
--          đặt TÊN VỊ TRÍ RIÊNG (vd "Khách – Công ty ABC") lúc tạo,
--          trang web tự tạo vị trí mới trong phòng "Khách / Đối tác"
--          (xem bindAccounts() trong index.html) — file SQL này KHÔNG
--          seed sẵn 1 vị trí "Khách" nữa (bỏ so với bản trước).
--        - "Vị trí khách thì xem được toàn bộ mục điều hành": khi đã
--          tích Xem Tổng quan, Khách được xem đủ các màn Tổng quan nhà
--          máy / Tổng hợp báo cáo ngày / Giao việc / Công việc của tôi
--          / Báo cáo hằng ngày (nhóm menu "Điều hành") — TRỪ "Bộ phận
--          của tôi" (xem comment tại allowedMods() trong index.html —
--          mọi tài khoản Khách dùng chung 1 phòng "Khách / Đối tác" nên
--          màn đó sẽ lộ danh sách các khách khác cho nhau).
--        - Để các màn "Tổng hợp báo cáo ngày"/"Báo cáo hằng ngày" thật
--          sự hiện đủ dữ liệu (không chỉ trống trơn), hàm phân quyền
--          đọc public.can_read_code() được nới rộng CHỈ CHO vai trò
--          Khách khi đã được tích Xem Tổng quan — xem phần 3 dưới.
--          KHÔNG đổi quyền đọc của bất kỳ tài khoản Nhân viên/Trưởng BP
--          nào đang có (điều kiện mới chỉ đúng khi role='guest', vai
--          trò này chưa từng tồn tại trên dữ liệu thật).
--
-- 1 phòng ban mới "Khách / Đối tác" (KHACH) để tài khoản khách có
-- dept_id/position_id hợp lệ (2 cột này bắt buộc not null trong
-- profiles) mà không lẫn vào bộ phận thật nào. Vị trí khách được tạo
-- động theo tên lúc tạo tài khoản (trang web tự insert vào positions).
-- Chạy lại được (idempotent).
-- =====================================================================

insert into public.departments(id, code, name, sort) values (12,'KHACH','Khách / Đối tác',99)
on conflict (id) do update set code = excluded.code, name = excluded.name, sort = excluded.sort;

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('admin','head','staff','guest'));

-- 3. Nới quyền ĐỌC (không phải quyền sửa) cho Khách khi đã được tích
-- "Xem Tổng quan": can_read_code() vẫn giữ nguyên 3 điều kiện cũ (admin /
-- đúng report_code của mình / trưởng BP phòng đó) và CHỈ THÊM điều kiện
-- 4 — is_guest() and can_overview() — nên không ảnh hưởng tài khoản nào
-- đang có (vai trò 'guest' chưa tồn tại trước khi chạy file này).
create or replace function public.is_guest() returns boolean language sql stable security definer set search_path = public as
$$ select exists(select 1 from profiles where id = auth.uid() and role = 'guest' and status = 'active') $$;

create or replace function public.can_read_code(p_code text) returns boolean language sql stable security definer set search_path = public as
$$ select public.is_admin() or p_code = any(public.my_report_codes()) or public.is_head_of(public.dept_of_code(p_code))
     or (public.is_guest() and public.can_overview()) $$;

grant execute on function public.is_guest() to authenticated;

-- Kiểm tra sau khi chạy:
-- select id,code,name from public.departments where code='KHACH';
-- select conname, pg_get_constraintdef(oid) from pg_constraint where conname='profiles_role_check';
-- select pg_get_functiondef('public.can_read_code(text)'::regprocedure);
--
-- LƯU Ý QUAN TRỌNG: Edge Function "admin-users" (file
-- supabase/functions/admin-users/index.ts) cũng đã sửa để chấp nhận
-- role "guest" — phải DEPLOY LẠI function này trên Supabase (Edge
-- Functions → admin-users → dán lại code → Deploy) thì tạo tài khoản
-- "Khách" mới hoạt động được. Chỉ chạy file SQL này KHÔNG đủ.
