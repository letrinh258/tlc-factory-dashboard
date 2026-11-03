-- =====================================================================
-- GĐ13: Sản xuất (Form A) – Loại lỗi (NG thao tác / NG NCC) đổi từ chọn
-- 1 loại cố định sang GÕ TAY TỰ DO + NHIỀU DÒNG LỖI (1 mã SP có thể có
-- nhiều loại lỗi khác nhau). Theo yêu cầu của anh 03/11:
--   "Loại lỗi ở mục lỗi thao tác và lỗi NCC hãy để gõ bằng tay và cần
--    thêm dòng lỗi. Vì 1 sản phẩm có thể nhiều loại lỗi"
-- Quyết định đi kèm (anh chọn 03/11):
--   - Tổng NG thao tác / NG NCC TỰ CỘNG từ các dòng lỗi (bỏ ô tổng nhập tay).
--   - Tên lỗi gõ HOÀN TOÀN TỰ DO, không gợi ý từ danh_mục defect_types.
-- Theo đúng mẫu đã dùng cho quality_defects (QAC Form B): bảng chi tiết
-- riêng, ghi/xóa chỉ qua RPC save_prod_row (bảo đảm tổng luôn khớp chi
-- tiết), không có insert/update/delete trực tiếp từ client.
-- Chạy lại được (idempotent với DROP...IF EXISTS / CREATE OR REPLACE).
-- =====================================================================

create table if not exists public.production_defects(
  id bigserial primary key,
  report_id bigint not null references public.production_reports(id) on delete cascade,
  source text not null check (source in ('op','sup')),
  defect_name text not null,
  qty int not null check (qty > 0)
);
alter table public.production_defects enable row level security;
revoke all on public.production_defects from anon;
drop policy if exists prod_defects_read on public.production_defects;
create policy prod_defects_read on public.production_defects for select to authenticated
  using (exists(select 1 from public.production_reports r where r.id = report_id));
-- (ghi/xóa chỉ qua save_prod_row, không có policy insert/update/delete)

-- Thay chữ ký cũ (ng_op/ng_sup nhập tay + defect_op/defect_sup chọn 1 loại)
drop function if exists public.save_prod_row(date,int,text,int,int,int,int,int,int,numeric,numeric,numeric,int,text,text);

create or replace function public.save_prod_row(d date, p_line int, p_product text, p_plan int, p_good int,
  p_defects_op jsonb, p_defects_sup jsonb,
  p_headcount numeric, p_hours numeric, p_ot numeric, p_downtime int, p_dt_reason text, p_note text)
returns bigint language plpgsql security definer set search_path = public as $$
declare rid bigint; pl int; v_ng_op int; v_ng_sup int; it jsonb;
begin
  if not public.can_edit_line(p_line, d) then
    raise exception 'Báo cáo Line % ngày % đã khóa (sau 23:59) hoặc bạn không phụ trách line này', p_line, to_char(d,'DD/MM'); end if;
  if not exists(select 1 from products where code = p_product and active) then raise exception 'Mã sản phẩm % không có trong danh mục', p_product; end if;
  if coalesce(p_good,0) < 0 then raise exception 'Số lượng không được âm'; end if;

  for it in select * from jsonb_array_elements(coalesce(p_defects_op,'[]'::jsonb) || coalesce(p_defects_sup,'[]'::jsonb))
  loop
    if coalesce(trim(it->>'name'),'') = '' then raise exception 'Nhập tên loại lỗi cho từng dòng lỗi'; end if;
    if coalesce((it->>'qty')::int,0) <= 0 then raise exception 'Số lượng mỗi dòng lỗi phải lớn hơn 0'; end if;
  end loop;

  select coalesce(sum((it->>'qty')::int),0) into v_ng_op from jsonb_array_elements(coalesce(p_defects_op,'[]'::jsonb)) it;
  select coalesce(sum((it->>'qty')::int),0) into v_ng_sup from jsonb_array_elements(coalesce(p_defects_sup,'[]'::jsonb)) it;

  if coalesce(p_good,0) + v_ng_op + v_ng_sup > 0 and coalesce(p_headcount,0) <= 0 then raise exception 'Nhập số người làm'; end if;
  if coalesce(p_hours,0) + coalesce(p_ot,0) > 16 then raise exception 'Tổng giờ hành chính + tăng ca không quá 16'; end if;
  if coalesce(p_downtime,0) > 0 and coalesce(trim(p_dt_reason),'') = '' then raise exception 'Chọn nguyên nhân dừng máy'; end if;

  pl := coalesce(p_plan, (select plan_qty from production_plans where plan_date = d and line_id = p_line and product_code = p_product));
  insert into production_reports(report_date, line_id, product_code, plan_qty, good_qty, ng_op, ng_sup,
     headcount, hours, ot_hours, downtime_min, downtime_reason, note, created_by, last_edit_by)
  values (d, p_line, p_product, pl, coalesce(p_good,0), v_ng_op, v_ng_sup,
     coalesce(p_headcount,0), coalesce(p_hours,8), coalesce(p_ot,0), coalesce(p_downtime,0), nullif(trim(p_dt_reason),''), p_note, auth.uid(), auth.uid())
  on conflict (report_date, line_id, product_code) do update set plan_qty = excluded.plan_qty, good_qty = excluded.good_qty,
     ng_op = excluded.ng_op, ng_sup = excluded.ng_sup,
     headcount = excluded.headcount, hours = excluded.hours, ot_hours = excluded.ot_hours, downtime_min = excluded.downtime_min,
     downtime_reason = excluded.downtime_reason, note = excluded.note, last_edit_by = auth.uid()
  returning id into rid;

  delete from production_defects where report_id = rid;
  insert into production_defects(report_id, source, defect_name, qty)
    select rid, 'op', trim(it->>'name'), (it->>'qty')::int from jsonb_array_elements(coalesce(p_defects_op,'[]'::jsonb)) it
    union all
    select rid, 'sup', trim(it->>'name'), (it->>'qty')::int from jsonb_array_elements(coalesce(p_defects_sup,'[]'::jsonb)) it;

  return rid;
end $$;
revoke execute on function public.save_prod_row(date,int,text,int,int,jsonb,jsonb,numeric,numeric,numeric,int,text,text) from anon;
grant execute on function public.save_prod_row(date,int,text,int,int,jsonb,jsonb,numeric,numeric,numeric,int,text,text) to authenticated;

-- defect_op/defect_sup (cột cũ chọn-1-loại) giữ nguyên trong production_reports để không
-- mất lịch sử các dòng đã nhập trước đây, nhưng từ nay KHÔNG còn được ghi nữa.

-- Kiểm tra sau khi chạy:
-- select count(*) from pg_tables where schemaname='public' and tablename='production_defects';
-- select proname, pronargs from pg_proc where proname='save_prod_row';
