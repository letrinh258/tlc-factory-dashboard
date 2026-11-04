-- =====================================================================
-- GĐ20: Đặt tên line sản xuất thật (theo xác nhận của anh 04/11) thay
-- cho tên mặc định "Line 1".."Line 10", để khớp đúng "Tên chuyền" trong
-- file Bravo khi dán Lệnh sản xuất / xem báo cáo:
--   Line 1  = Dây chuyền SXHN 01      Line 6  = Dây chuyền SXHN 06
--   Line 2  = Dây chuyền SXHN 02      Line 7  = Dây chuyền SXHN 07
--   Line 3  = Dây chuyền SXHN 03      Line 8  = Dây chuyền SXHN 08
--   Line 4  = Dây chuyền SXHN 04      Line 9  = Dây chuyền SXHN 09
--   Line 5  = Dây chuyền SXHN 05      Line 10 = Dây chuyền SXHN 10
-- (anh xác nhận trực tiếp 01/02/03/07; 04/05/06/08/09/10 đặt theo đúng
-- quy luật số thứ tự anh xác nhận "Dây chuyền SXHN 01 - 10").
--
-- Đồng thời thêm LINE THỨ 11 = "Tổ sản xuất 20" (đơn vị sản xuất riêng,
-- không thuộc 10 dây chuyền SXHN, theo xác nhận của anh 04/11) — thêm
-- hẳn 1 dòng mới vào production_lines (không phải đổi tên dòng cũ), vì
-- đây là 1 đơn vị sản xuất thật có lệnh SX riêng (vd LSXR11/26-002).
-- An toàn: production_lines.id không giới hạn ở 10 (chỉ là khóa chính
-- smallint, mọi nơi dùng CFG.lines.length để suy ra số line tối đa, nên
-- thêm dòng 11 không cần sửa gì ở index.html/app — đã kiểm tra).
-- =====================================================================

update public.production_lines set name = 'Dây chuyền SXHN 01' where id = 1;
update public.production_lines set name = 'Dây chuyền SXHN 02' where id = 2;
update public.production_lines set name = 'Dây chuyền SXHN 03' where id = 3;
update public.production_lines set name = 'Dây chuyền SXHN 04' where id = 4;
update public.production_lines set name = 'Dây chuyền SXHN 05' where id = 5;
update public.production_lines set name = 'Dây chuyền SXHN 06' where id = 6;
update public.production_lines set name = 'Dây chuyền SXHN 07' where id = 7;
update public.production_lines set name = 'Dây chuyền SXHN 08' where id = 8;
update public.production_lines set name = 'Dây chuyền SXHN 09' where id = 9;
update public.production_lines set name = 'Dây chuyền SXHN 10' where id = 10;

insert into public.production_lines(id, name, active) values (11, 'Tổ sản xuất 20', true)
  on conflict (id) do update set name = excluded.name, active = true;

-- Kiểm tra sau khi chạy:
-- select id, name, active from public.production_lines order by id; -- 11 dòng, đúng tên trên
