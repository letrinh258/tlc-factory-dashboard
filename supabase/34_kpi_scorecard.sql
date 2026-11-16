-- =====================================================================
-- GĐ30: "Báo cáo KPI" — trang mới, 19 chỉ số theo 4 nhóm (Sản lượng &
-- giao hàng / Năng suất & con người / Chất lượng / Chi phí & tài sản),
-- có bộ lọc Ngày/Tuần/Tháng dùng chung kiểu với Tổng quan (GĐ25).
--
-- 15/19 chỉ số tính thẳng từ dữ liệu đã có (production_reports,
-- quality_reports, maintenance_reports, hr_reports, cost_reports,
-- inventory_report_lines, orders, wh_entries, production_order_batches).
--
-- 3 chỉ số CHƯA có bảng lưu (Tai nạn/suýt tai nạn lao động, Lô IQC tồn
-- chưa kiểm, Chi phí ngoài kế hoạch) — theo yêu cầu 16/11: thêm Ô NHẬP TAY
-- hàng tuần, do 1 người (GĐNM hoặc trợ lý) nhập ở ngay trang Báo cáo KPI.
--
-- 1 chỉ số còn lại ("Ca BH tại nhà quá cam kết 72h") — theo yêu cầu 16/11:
-- thêm TRƯỜNG THÔNG TIN ngay trong module Bảo hành (ngày/giờ nhận hàng +
-- trạng thái xử lý từng phiếu) để tự tính, không phải nhập tay riêng.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Bảng nhập tay hàng tuần — 3 chỉ số chưa có nguồn dữ liệu
-- ---------------------------------------------------------------------
create table if not exists public.kpi_manual_weekly(
  id bigint generated always as identity primary key,
  week_start date not null unique,            -- Thứ Hai của tuần áp dụng
  tai_nan_count int,                          -- Tai nạn / suýt tai nạn lao động (vụ, cả tuần)
  iqc_ton_chua_kiem int,                      -- Lô IQC tồn chưa kiểm (lô, cuối tuần)
  chi_phi_ngoai_ke_hoach numeric,              -- Chi phí ngoài kế hoạch (triệu đ, cả tuần)
  note text,
  created_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);
alter table public.kpi_manual_weekly enable row level security;
drop policy if exists kmw_read on public.kpi_manual_weekly;
drop policy if exists kmw_write on public.kpi_manual_weekly;
create policy kmw_read on public.kpi_manual_weekly for select to authenticated using (public.can_overview());
create policy kmw_write on public.kpi_manual_weekly for all to authenticated using (public.is_admin()) with check (public.is_admin());

create or replace function public.kpi_manual_save(p_week date, p_tai_nan int, p_iqc_ton int, p_chi_phi numeric, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_monday date := p_week - ((extract(isodow from p_week)::int - 1));
begin
  if not public.is_admin() then raise exception 'Chỉ GĐNM được nhập số liệu KPI tay'; end if;
  insert into public.kpi_manual_weekly(week_start, tai_nan_count, iqc_ton_chua_kiem, chi_phi_ngoai_ke_hoach, note, created_by, updated_at)
  values (v_monday, p_tai_nan, p_iqc_ton, p_chi_phi, p_note, auth.uid(), now())
  on conflict (week_start) do update set tai_nan_count = excluded.tai_nan_count, iqc_ton_chua_kiem = excluded.iqc_ton_chua_kiem,
    chi_phi_ngoai_ke_hoach = excluded.chi_phi_ngoai_ke_hoach, note = excluded.note, created_by = excluded.created_by, updated_at = now();
end $$;
revoke execute on function public.kpi_manual_save(date,int,int,numeric,text) from anon, public;
grant execute on function public.kpi_manual_save(date,int,int,numeric,text) to authenticated;

-- ---------------------------------------------------------------------
-- 2. Module Bảo hành: thêm trường "nhận lúc" + "trạng thái" cho từng
--    phiếu (warranty_claims) để tính "Ca BH tại nhà quá cam kết 72h"
-- ---------------------------------------------------------------------
alter table public.warranty_claims add column if not exists received_at timestamptz;
alter table public.warranty_claims add column if not exists status text not null default 'open';
alter table public.warranty_claims add column if not exists done_at timestamptz;
alter table public.warranty_claims drop constraint if exists warranty_claims_status_chk;
alter table public.warranty_claims add constraint warranty_claims_status_chk check (status in ('open','done'));

-- Backfill dữ liệu cũ (trước GĐ30): coi như đã xử lý xong, không tính vào
-- "tồn tại nhà máy" hiện tại — vì trước đây không theo dõi theo từng phiếu.
update public.warranty_claims c set
  received_at = coalesce(received_at, b.created_at),
  status = 'done',
  done_at = coalesce(done_at, b.created_at)
from public.warranty_batches b where b.id = c.batch_id and c.status = 'open' and c.received_at is null;

create or replace function public.warranty_claim_set_status(p_claim_id bigint, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Chỉ GĐNM được cập nhật trạng thái phiếu bảo hành'; end if;
  if p_status not in ('open','done') then raise exception 'Trạng thái không hợp lệ'; end if;
  update public.warranty_claims set status = p_status, done_at = case when p_status = 'done' then now() else null end where id = p_claim_id;
end $$;
revoke execute on function public.warranty_claim_set_status(bigint,text) from anon, public;
grant execute on function public.warranty_claim_set_status(bigint,text) to authenticated;

create or replace function public.warranty_claim_set_received(p_claim_id bigint, p_received_at timestamptz)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Chỉ GĐNM được sửa ngày nhận phiếu bảo hành'; end if;
  update public.warranty_claims set received_at = p_received_at where id = p_claim_id;
end $$;
revoke execute on function public.warranty_claim_set_received(bigint,timestamptz) from anon, public;
grant execute on function public.warranty_claim_set_received(bigint,timestamptz) to authenticated;

-- ---------------------------------------------------------------------
-- 3. RPC tổng hợp 19 chỉ số Báo cáo KPI cho kỳ [d1, d2]
-- ---------------------------------------------------------------------
create or replace function public.kpi_scorecard(d1 date, d2 date) returns json
language plpgsql stable security definer set search_path = public as $$
declare std numeric := coalesce((select (value->>'stdProd')::numeric from app_settings where key = 'rules'), 32); r jsonb; ndays int;
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
  poful as ( -- % lệnh SX nhập kho đủ trong ngày KH: so lệnh (theo item_code trong production_orders) có wh_entries nhập đủ qty_planned trước/đúng expected_date
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
  manual as (select * from kpi_manual_weekly where week_start between (d1 - 6) and d2 order by week_start),
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
    'chiphi_ngoai_kh_trieu', (select sum(chi_phi_ngoai_ke_hoach) from manual where week_start between d1 and d2),
    'ma_kiemke_lech_pct', (select case when count(*)=0 then null else count(*) filter (where closing is distinct from ref_qty)::numeric/count(*)*100 end from invl),
    'tai_nan_vu', (select sum(tai_nan_count) from manual where week_start between d1 and d2),
    'iqc_ton_lo', (select iqc_ton_chua_kiem from manual where week_start <= d2 order by week_start desc limit 1),
    'manual_weeks', (select coalesce(json_agg(json_build_object('week_start',week_start,'tai_nan_count',tai_nan_count,'iqc_ton_chua_kiem',iqc_ton_chua_kiem,'chi_phi_ngoai_ke_hoach',chi_phi_ngoai_ke_hoach,'note',note)),'[]') from manual)
  ) into r;
  return r::json;
end $$;
revoke execute on function public.kpi_scorecard(date,date) from anon, public;
grant execute on function public.kpi_scorecard(date,date) to authenticated;

-- Kiểm tra sau khi chạy:
-- select proname from pg_proc where proname in ('kpi_manual_save','warranty_claim_set_status','warranty_claim_set_received','kpi_scorecard');
-- select column_name from information_schema.columns where table_name='warranty_claims' and column_name in ('received_at','status','done_at');
