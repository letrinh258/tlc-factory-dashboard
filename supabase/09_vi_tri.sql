-- =====================================================================
-- GĐ6b: Cập nhật vị trí theo danh sách nhân sự thực tế (17 người, 02/11/26)
-- Chạy sau 08_alerts.sql, trong Supabase SQL Editor.
-- Sau khi chạy file này, GĐNM có thể tự thêm vị trí mới trong
-- Quản lý tài khoản → "Vị trí trong nhà máy" (không cần SQL nữa).
-- =====================================================================

-- Đổi tên phòng KHSX thành "Phòng Kế hoạch" cho khớp cách gọi thực tế
-- (mã phòng 'KHSX' giữ nguyên, mọi tham chiếu report_code/dept_id_of không đổi)
update public.departments set name = 'Phòng Kế hoạch' where code = 'KHSX';

-- Bỏ chức danh "Trưởng phòng KHSX" -> đổi thành "Phó phòng kế hoạch"
-- (giữ nguyên id vị trí, vẫn là vị trí đứng đầu phòng Kế hoạch)
update public.positions set code = 'PP-KHSX', name = 'Phó phòng kế hoạch' where code = 'TBP-KHSX';

-- Thêm "Phó giám đốc nhà máy" (Ban giám đốc), cấp Trưởng/Phó phòng
-- để không trùng vai trò admin với GĐNM (GĐNM vẫn là admin duy nhất)
insert into public.positions(code, name, dept_id, kind, report_code) values
 ('PGD-NM', 'Phó giám đốc nhà máy', 1, 'head', null)
on conflict (code) do update set name = excluded.name, dept_id = excluded.dept_id, kind = excluded.kind;

-- Tách "Tổ trưởng sản xuất" chung thành 2 vị trí theo dãy
-- Dãy A = Line 1-5, Dãy B = Line 6-10 (gán line cụ thể ở màn phân công line theo tài khoản)
update public.positions set code = 'TT-SXA', name = 'Tổ trưởng Dãy A (Line 1-5)' where code = 'TT-SX';

insert into public.positions(code, name, dept_id, kind, report_code) values
 ('TT-SXB', 'Tổ trưởng Dãy B (Line 6-10)', 3, 'staff', null)
on conflict (code) do update set name = excluded.name, dept_id = excluded.dept_id, kind = excluded.kind;

-- Kiểm tra sau khi chạy: mỗi phòng tối đa 1 vị trí kind='head' (ràng buộc positions_one_head_per_dept)
-- select dept_id, count(*) from public.positions where kind='head' group by dept_id having count(*)>1;
