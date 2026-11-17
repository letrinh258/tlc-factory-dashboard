-- =====================================================================
-- GĐ33 (17/11): Cách 2 — tách lệnh sản xuất "Kế hoạch" (chốt từ đầu,
-- KHSX lập theo KH tuần/tháng) ↔ "Tranh thủ ngoài KH" (line dư công
-- suất, tự làm thêm lệnh mới trong ngày). Theo tư vấn: lệnh tranh thủ
-- không nên bị chấm "đạt/không đạt" giống lệnh kế hoạch (nó mới bắt
-- đầu, làm được bao nhiêu hay bấy nhiêu, không phải lệnh trễ/hỏng).
--
-- - Thêm cột kind ('planned' mặc định | 'overflow') trên
--   production_order_batches. KHSX/GĐNM tự đánh dấu lại lệnh nào là
--   tranh thủ ngay trên màn "Lệnh sản xuất" (RPC lsx_set_kind).
-- - kpi_scorecard: % lệnh SX đủ hàng (lenh_sx_du_hang_pct) CHỈ tính
--   trên lệnh kind='planned'. Thêm chỉ số mới "Sản lượng tận dụng
--   công suất dư" = tổng SL đã nhập kho từ các lệnh tranh thủ trong
--   kỳ — chỉ tiêu theo dõi, KHÔNG chấm đạt/thiếu (làm thêm được bao
--   nhiêu là tốt bấy nhiêu, không có KPI thiếu).
-- =====================================================================

alter table public.production_order_batches add column if not exists kind text not null default 'planned' check (kind in ('planned','overflow'));

create or replace function public.lsx_set_kind(p_batch_id bigint, p_kind text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_kind not in ('planned','overflow') then raise exception 'Loại lệnh không hợp lệ'; end if;
  if not (public.is_admin() or public.in_dept(public.dept_id_of('KHSX'))) then
    raise exception 'Chỉ KHSX/GĐNM được đổi loại lệnh';
  end if;
  update public.production_order_batches set kind = p_kind where id = p_batch_id;
end $$;
revoke execute on function public.lsx_set_kind(bigint,text) from anon, public;
grant execute on function public.lsx_set_kind(bigint,text) to authenticated;
