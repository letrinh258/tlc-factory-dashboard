-- =====================================================================
-- GĐ7d: Mã lệnh sản xuất (LSX) do KHSX TỰ ĐIỀN khi dán (lấy từ Bravo hoặc
-- tự đặt) — KHÔNG để hệ thống tự sinh mã như GĐ7c nữa. Vì vậy 1 line/ngày
-- có thể có NHIỀU lệnh khác mã (ví dụ ca sáng/ca chiều, hoặc nhiều đợt) —
-- bỏ ràng buộc 1 lệnh/line/ngày của 14_lenh_sx_batch.sql.
-- Chạy sau 14_lenh_sx_batch.sql.
-- =====================================================================

alter table public.production_order_batches drop constraint if exists production_order_batches_order_date_line_id_key;

-- code vẫn UNIQUE (ràng buộc có sẵn từ 14_lenh_sx_batch.sql) — mỗi mã lệnh
-- là 1 lệnh duy nhất trong toàn hệ thống, đúng với số lệnh thật của Bravo.

-- Kiểm tra sau khi chạy:
-- select conname from pg_constraint where conrelid = 'public.production_order_batches'::regclass;
