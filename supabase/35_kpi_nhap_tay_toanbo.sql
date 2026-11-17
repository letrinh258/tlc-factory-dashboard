-- =====================================================================
-- GĐ30c (16/11): Theo yêu cầu — TOÀN BỘ 19 chỉ số Báo cáo KPI đều cho
-- phép NHẬP TAY ĐÈ SỐ (override), vẫn ƯU TIÊN số tính tự động trước;
-- số nhập tay áp dụng đúng theo KỲ đang xem lúc nhập (cùng ngày bắt
-- đầu–kết thúc d1,d2) — đổi sang kỳ khác (vd Tuần → Tháng) hệ thống
-- dùng lại số tính tự động cho kỳ đó, trừ khi cũng nhập tay riêng cho
-- kỳ đó.
--
-- Thay thế bảng/RPC nhập tay riêng theo tuần (kpi_manual_weekly /
-- kpi_manual_save) của GĐ30 bằng 1 cơ chế chung — áp dụng được cho cả
-- nhóm "Bảo hành tại nhà" (BHN): vì BHN xử lý tại nhà khách, không có
-- khái niệm "tồn tại nhà máy" nên không nhập được ở từng phiếu — nay
-- GĐNM/trợ lý nhập tay thẳng vào số KPI cuối (vd "Hàng BH tồn tại nhà
-- máy", "Ca BH quá cam kết") cho đúng kỳ đang xem.
-- =====================================================================

create table if not exists public.kpi_overrides(
  id bigint generated always as identity primary key,
  metric_key text not null,
  d1 date not null,
  d2 date not null,
  value numeric,
  note text,
  created_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  unique(metric_key, d1, d2)
);
alter table public.kpi_overrides enable row level security;
drop policy if exists kov_read on public.kpi_overrides;
drop policy if exists kov_write on public.kpi_overrides;
create policy kov_read on public.kpi_overrides for select to authenticated using (public.can_overview());
create policy kov_write on public.kpi_overrides for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- di chuyển dữ liệu đã nhập ở GĐ30 (nếu có) sang cơ chế mới, theo đúng
-- tuần đã nhập (week_start .. week_start+6)
insert into public.kpi_overrides(metric_key, d1, d2, value, note, created_by, updated_at)
select 'tai_nan_vu', week_start, week_start + 6, tai_nan_count, note, created_by, updated_at from public.kpi_manual_weekly where tai_nan_count is not null
union all
select 'iqc_ton_lo', week_start, week_start + 6, iqc_ton_chua_kiem, note, created_by, updated_at from public.kpi_manual_weekly where iqc_ton_chua_kiem is not null
union all
select 'chiphi_ngoai_kh_trieu', week_start, week_start + 6, chi_phi_ngoai_ke_hoach, note, created_by, updated_at from public.kpi_manual_weekly where chi_phi_ngoai_ke_hoach is not null
on conflict (metric_key, d1, d2) do nothing;
drop function if exists public.kpi_manual_save(date,int,int,numeric,text);
drop table if exists public.kpi_manual_weekly;

create or replace function public.kpi_override_save(p_metric text, p_d1 date, p_d2 date, p_value numeric, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Chỉ GĐNM được nhập tay số liệu KPI'; end if;
  if p_value is null then
    delete from public.kpi_overrides where metric_key = p_metric and d1 = p_d1 and d2 = p_d2;
  else
    insert into public.kpi_overrides(metric_key, d1, d2, value, note, created_by, updated_at)
    values (p_metric, p_d1, p_d2, p_value, p_note, auth.uid(), now())
    on conflict (metric_key, d1, d2) do update set value = excluded.value, note = excluded.note, created_by = excluded.created_by, updated_at = now();
  end if;
end $$;
revoke execute on function public.kpi_override_save(text,date,date,numeric,text) from anon, public;
grant execute on function public.kpi_override_save(text,date,date,numeric,text) to authenticated;

create or replace function public.kpi_scorecard(d1 date, d2 date) returns json
language plpgsql stable security definer set search_path = public as $$
declare std numeric := coalesce((select (value->>'stdProd')::numeric from app_settings where key = 'rules'), 32); r jsonb; ov jsonb; ndays int; v_d1 date := d1; v_d2 date := d2;
begin
  if not public.can_overview() then raise exception 'Bạn chưa được cấp quyền xem Báo cáo KPI. Liên hệ GĐNM.'; end if;
  ndays := greatest(1, d2 - d1 + 1);
  with pr as (
    select r.*, coalesce(p.norm_per_hour, std) norm
    from production_reports r left join products p on p.code = r.product_code
    where r.report_date between d1 and d2),
  prday as (select report_date d, sum(good_qty) good, sum(plan_qty) plan, sum(good_qty/nullif(norm,0)) std_hours, sum(headcount*(hours+ot_hours)) man_hours
    from pr group by report_date),
  whtp as (select report_date d, coalesce(sum(qty) filter (where warehouse='TP' and kind='receipt_sx'),0) qty
    from wh_entries where report_date between d1 and d2 group by report_date),
  planday as (select plan_date d, sum(plan_qty) plan from production_plans where plan_date between d1 and d2 group by plan_date),
  pob as (select * from production_order_batches where order_date between d1 and d2),
  poful as (
    select po.id, po.qty_planned, b.order_date, b.line_id, po.item_code,
      (select coalesce(sum(w.qty),0) from wh_entries w where w.item_code = po.item_code and w.warehouse='TP' and w.kind='receipt_sx'
        and w.report_date between b.order_date and b.order_date + 10) received
    from production_orders po join pob b on b.id = po.batch_id),
  qc as (select q.*, (select coalesce(sum(qty),0) from quality_defects where report_id=q.id) ngq from quality_reports q where q.report_date between d1 and d2),
  qcday as (select report_date d, sum(inspected) filter (where stage='PQC') pqc_ins, sum(ngq) filter (where stage='PQC') pqc_ng,
    sum(inspected) filter (where stage='IQC') iqc_ins, sum(ngq) filter (where stage='IQC') iqc_ng from qc group by report_date),
  mt as (select * from maintenance_reports where report_date between d1 and d2),
  hr as (select * from hr_reports where report_date between d1 and d2),
  cst as (select * from cost_reports where period_start <= d2 and period_end >= d1),
  invl as (select l.* from inventory_report_lines l join inventory_reports ir on ir.id = l.report_id where ir.report_date between d1 and d2),
  ord as (select * from orders),
  wcl as (select c.*, b.report_month from warranty_claims c join warranty_batches b on b.id = c.batch_id)
  select jsonb_build_object(
    'd1', d1, 'd2', d2, 'days', ndays,
    'sl_nhapkho_tp_tuan', (select coalesce(sum(qty),0) from whtp),
    'sl_nhapkho_tp_kh', (select coalesce(sum(plan),0) from planday),
    'sl_nhapkho_tp_ngay_pct', (select avg(case when p.plan>0 then w.qty/p.plan*100 else null end) from whtp w join planday p on p.d=w.d),
    'lenh_sx_du_hang_pct', (select case when count(*)=0 then null else count(*) filter (where received >= qty_planned)::numeric/count(*)*100 end from poful),
    'don_hang_cham_giao', (select count(*) from ord where due_date <= d2 and status not in ('done','completed','closed','cancelled') and (completed_date is null or completed_date > d2)),
    'hieu_suat_pct', (select avg(case when man_hours>0 then std_hours/man_hours*100 else null end) from prday),
    'dung_chuyen_phut', (select coalesce(sum(downtime_min),0) from pr),
    'dung_may_thietbi_phut', (select case when count(*)=0 then null else coalesce(sum(downtime_min) filter (where kind='breakdown'),0) end from mt),
    'hien_dien_pct', (select avg(case when total>0 then present::numeric/total*100 else null end) from hr),
    'iqc_khong_dat_pct', (select avg(case when iqc_ins>0 then iqc_ng::numeric/iqc_ins*100 else null end) from qcday),
    'loi_line_pqc_pct', (select avg(case when pqc_ins>0 then pqc_ng::numeric/pqc_ins*100 else null end) from qcday),
    'bh_ca_qua_camket', (select count(*) from wcl where status='open' and received_at is not null and received_at <= (d2::timestamptz + interval '1 day') and now() - received_at > interval '72 hours'),
    'bh_ton_nha_may', (select count(*) from wcl where status='open' and received_at is not null and received_at <= (d2::timestamptz + interval '1 day')),
    'bh_ton_tren_30ngay', (select count(*) from wcl where status='open' and received_at is not null and received_at <= (d2::timestamptz + interval '1 day') and now() - received_at > interval '30 days'),
    'phe_pham_loi_trieu', (select case when count(*)=0 then null else coalesce(sum(defect_cost),0)/1000000.0 end from cst),
    'vattu_vuot_dm_trieu', (select case when count(*)=0 then null else coalesce(sum(material_cost * greatest(material_variance_pct,0) / 100.0),0)/1000000.0 end from cst),
    'chiphi_ngoai_kh_trieu', null,
    'ma_kiemke_lech_pct', (select case when count(*)=0 then null else count(*) filter (where closing is distinct from ref_qty)::numeric/count(*)*100 end from invl),
    'tai_nan_vu', null,
    'iqc_ton_lo', null
  ) into r;
  -- áp số nhập tay (đè số tính tự động) đúng theo kỳ [d1,d2] đang xem
  select coalesce(jsonb_object_agg(ko.metric_key, jsonb_build_object('value', ko.value, 'note', ko.note, 'updated_at', ko.updated_at)), '{}'::jsonb)
    into ov from kpi_overrides ko where ko.d1 = v_d1 and ko.d2 = v_d2;
  r := (select jsonb_object_agg(kv.key, case when ov ? kv.key then ov->kv.key->'value' else kv.value end) from jsonb_each(r) kv)
       || jsonb_build_object('d1', d1, 'd2', d2, 'days', ndays, 'overrides', ov);
  return r::json;
end $$;
revoke execute on function public.kpi_scorecard(date,date) from anon, public;
grant execute on function public.kpi_scorecard(date,date) to authenticated;
