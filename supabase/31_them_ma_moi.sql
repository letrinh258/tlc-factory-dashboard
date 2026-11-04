-- =====================================================================
-- GĐ22: Nút "Thêm mã mới" ở Cấu hình → Định mức năng suất, để GĐNM tự
-- thêm mã sản phẩm hoàn toàn mới khi phát hiện mã chưa có trong danh mục
-- (vd khi dán Lệnh sản xuất / cập nhật định mức từ Bravo mà gặp mã lạ).
-- Theo yêu cầu 04/11: form nhập TAY HOÀN TOÀN — không gợi ý/tự điền sẵn
-- nội dung nào, kể cả khi mã đó từng xuất hiện ở chỗ khác bị báo lỗi.
--
-- RPC admin-only, theo đúng khuôn mẫu set_norms() ở 04_gd5b.sql:
--  - Kiểm tra is_admin()
--  - Mã/tên không được rỗng, mã chưa tồn tại (tránh ghi đè nhầm — muốn
--    sửa mã đã có thì dùng "Dán nhiều dòng" hoặc sửa trực tiếp dòng đó)
--  - Định mức nếu nhập thì phải > 0; nếu có nhập thì đánh dấu norm_manual
--    = true (vì đây là số GĐNM tự gõ, không phải đồng bộ từ Bravo) và ghi
--    lịch sử vào norm_changes như set_norms vẫn làm
--  - source = 'manual' để phân biệt với các mã đồng bộ từ Bravo
-- =====================================================================

create or replace function public.add_product(
  p_code text, p_name text, p_norm numeric default null, p_is_semi boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_code text := trim(p_code); v_name text := trim(p_name);
begin
  if not public.is_admin() then raise exception 'Chỉ GĐNM mới được thêm mã sản phẩm mới'; end if;
  if v_code = '' then raise exception 'Chưa nhập mã sản phẩm'; end if;
  if v_name = '' then raise exception 'Chưa nhập tên sản phẩm'; end if;
  if exists(select 1 from public.products where code = v_code) then
    raise exception 'Mã "%" đã có trong danh mục — dùng "Dán nhiều dòng" nếu muốn sửa định mức', v_code;
  end if;
  if p_norm is not null and not (p_norm > 0) then
    raise exception 'Định mức phải là số lớn hơn 0';
  end if;

  insert into public.products(code, name, norm_per_hour, is_semi, active, source, norm_manual, norm_updated_at, norm_updated_by)
  values (v_code, v_name, p_norm, coalesce(p_is_semi,false), true, 'manual',
          p_norm is not null, case when p_norm is not null then now() end,
          case when p_norm is not null then auth.uid() end);

  if p_norm is not null then
    insert into public.norm_changes(product_code, old_norm, new_norm, note, changed_by)
    values (v_code, null, p_norm, 'Thêm mã mới', auth.uid());
  end if;

  return jsonb_build_object('code', v_code);
end $$;

grant execute on function public.add_product(text, text, numeric, boolean) to authenticated;

-- Kiểm tra sau khi chạy:
-- select proname from pg_proc where proname = 'add_product'; -- 1 dòng
