-- =====================================================================
-- GĐ50 (23/11): Mục "Vấn đề phát sinh & hành động khắc phục" ở cuối Báo
-- cáo điều hành (thêm ở GĐ49) KHÔNG lấy tự động từ mục 2 Báo cáo hằng
-- ngày của các vị trí nữa — chỉ hiện đúng những vấn đề GĐNM tự nhập tay
-- trực tiếp ở form "Thêm vấn đề" cuối trang Báo cáo điều hành.
--
-- 1. Thêm cột issues.source (text, mặc định NULL). Mỗi lần GĐNM thêm vấn
--    đề ở form cuối Báo cáo điều hành, frontend lưu source='bcdh'. Các
--    vấn đề nhập ở mục 2 Báo cáo hằng ngày (các vị trí tự ghi nhận hằng
--    ngày) vẫn lưu vào đúng bảng issues như cũ, KHÔNG set source — vẫn
--    hiện đầy đủ ở Tổng quan/Vấn đề & cải tiến/Lịch điều hành như trước,
--    chỉ không còn kéo vào Báo cáo điều hành nữa.
-- 2. Sửa hàm bcdh_data(d1,d2): phần 'issues' thêm điều kiện
--    "s.source = 'bcdh'" — chỉ trả về đúng các vấn đề nhập tay ở đây.
-- =====================================================================

alter table public.issues add column if not exists source text;
-- (nội dung đầy đủ hàm bcdh_data mới: xem migration đã áp dụng trực tiếp
--  qua Supabase MCP — chỉ khác phần CTE 'issues' thêm "s.source = 'bcdh'"
--  so với bản gốc ở supabase/39_bao_cao_dieu_hanh.sql)
