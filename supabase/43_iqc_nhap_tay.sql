-- =====================================================================
-- GĐ39 (20/11): Số lô IQC kiểm / lỗi chuyển sang QAC nhập tay.
--
-- Trước đây "Tỷ lệ lô IQC không đạt" ở Báo cáo điều hành tự động đếm từ
-- Form B (quality_reports, stage='IQC'): số lô kiểm = tổng số dòng ghi,
-- số lô lỗi = số dòng có NG > 0. Theo lựa chọn của anh Trình (hỏi qua
-- AskUserQuestion 20/11, chọn "Thay cho Form B"): QAC chỉ cần gõ TỔNG số
-- lô kiểm/lỗi trong ngày ở ô "Số liệu Báo cáo điều hành" (dưới Mục 1,
-- Báo cáo hằng ngày) — đơn giản, nhanh hơn ghi từng dòng. Form B (IQC)
-- vẫn giữ để ghi chi tiết nếu cần nhưng KHÔNG còn cộng vào KPI này nữa
-- (tránh đếm trùng 2 nguồn).
--
-- Thay đổi:
-- 1. bcdh_data: cột iqc_kiem/iqc_kd trong CTE rows đổi nguồn từ qcd
--    (đếm Form B) sang (m.j->>'QAC.dh_iqc_kiem')/(m.j->>'QAC.dh_iqc_kd')
--    — cùng mẫu với dh_iqc_ton đã có từ trước. qcd chỉ còn giữ pqc_kiem/
--    pqc_loi (Form B PQC không đổi).
-- 2. report_metrics.QAC (Mục 1, báo cáo hằng ngày — field chung không
--    nối KPI): bỏ ô "Số lô IQC" cũ (mồ côi, không nối đâu) để tránh
--    trùng với 2 ô mới.
-- 3. Frontend (index.html): DH_IN.QAC thêm dh_iqc_kiem/dh_iqc_kd; thêm
--    kiểm tra lô lỗi ≤ lô kiểm; DH_CH[3][0] đổi từ 1 cột % sang: cột Lô
--    kiểm tra + cột Lô lỗi + đường % không đạt (cùng mẫu chart "Sản
--    lượng TP nhập kho" GĐ37).
-- =====================================================================

create or replace function public.bcdh_data(d1 date, d2 date)
returns json language plpgsql stable security definer set search_path = public as $$
declare std numeric := coalesce((select (value->>'stdProd')::numeric from app_settings where key = 'rules'), 32);
  r json;
begin
  if not public.can_overview() then raise exception 'Bạn chưa được cấp quyền xem Báo cáo điều hành. Liên hệ GĐNM.'; end if;
  if d2 < d1 or d2 - d1 > 62 then raise exception 'Khoảng ngày không hợp lệ (tối đa 63 ngày)'; end if;
  with days as (select g::date d from generate_series(d1, d2, interval '1 day') g),
  dm as (select dr.report_date d, dr.report_code c, kv.key k, sum(case when kv.value ~ '^-?[0-9]+(\.[0-9]+)?$' then kv.value::numeric end) v
         from daily_reports dr, jsonb_each_text(coalesce(dr.metrics,'{}'::jsonb)) kv
         where dr.report_date between d1 and d2 group by 1,2,3),
  m as (select d, jsonb_object_agg(c||'.'||k, v) j from dm where v is not null group by d),
  pr as (select r.report_date d, r.good_qty, r.ng_qty, r.downtime_min, coalesce(r.downtime_reason,'') rs,
           r.headcount*(coalesce(r.hours,0)+coalesce(r.ot_hours,0)) mh,
           r.good_qty/nullif(coalesce(p.norm_per_hour, std),0) sh,
           b.kind
         from production_reports r left join products p on p.code = r.product_code
         left join production_order_batches b on b.id = r.order_batch_id
         where r.report_date between d1 and d2),
  prd as (select d, sum(good_qty) sl_sx, sum(ng_qty) ng_sx, sum(sh) std_h, sum(mh) gio_cong,
           sum(good_qty) filter (where kind = 'overflow') sx_ngoai,
           sum(downtime_min) filter (where rs ilike '%máy%' or rs ilike '%thiết bị%' or rs ilike '%điện%') dung_tb,
           sum(downtime_min) filter (where rs ilike '%QC%' or rs ilike '%lỗi%') dung_loi,
           sum(downtime_min) filter (where rs ilike '%vật tư%') dung_vt,
           sum(downtime_min) filter (where not (rs ilike '%máy%' or rs ilike '%thiết bị%' or rs ilike '%điện%' or rs ilike '%QC%' or rs ilike '%lỗi%' or rs ilike '%vật tư%')) dung_line,
           count(*) filter (where downtime_min > 0 and rs ilike '%vật tư%') vt_dung
         from pr group by d),
  pob as (select order_date d, sum(qty_total) kh from production_order_batches where order_date between d1 and d2 and kind = 'planned' group by 1),
  whtp as (select report_date d, sum(qty) tp from wh_entries where report_date between d1 and d2 and warehouse = 'TP' and kind = 'receipt_sx' group by 1),
  qc as (select q.report_date d, q.stage, q.inspected, (select coalesce(sum(qty),0) from quality_defects x where x.report_id = q.id) ng
         from quality_reports q where q.report_date between d1 and d2),
  qcd as (select d,
           sum(inspected) filter (where stage='PQC') pqc_kiem, sum(ng) filter (where stage='PQC') pqc_loi from qc group by d),
  hr as (select report_date d, total, quits from hr_reports where report_date between d1 and d2),
  rows as (
    select dd.d,
      nullif(coalesce(pob.kh, (select sum(plan_qty) from production_reports x where x.report_date = dd.d)),0) kh_sl,
      whtp.tp tp_total, prd.sx_ngoai,
      (m.j->>'KHSX.dh_don_cham')::numeric don_cham, (m.j->>'KHSX.dh_don_cham_ck')::numeric don_cham_ck, (m.j->>'KHSX.dh_ton_kh')::numeric ton_kh,
      prd.sl_sx, prd.ng_sx, prd.std_h, prd.gio_cong, prd.dung_tb, prd.dung_loi, prd.dung_vt, prd.dung_line, prd.vt_dung,
      coalesce(hr.total::numeric, (m.j->>'HCNS.tong')::numeric) ld_bq,
      coalesce(hr.quits::numeric, (m.j->>'HCNS.nghi_viec')::numeric) ld_nghiviec,
      (m.j->>'HCNS.dh_nghi_kp')::numeric nghi_kp, (m.j->>'HCNS.dh_tai_nan')::numeric tai_nan,
      (m.j->>'QAC.dh_iqc_kiem')::numeric iqc_kiem, (m.j->>'QAC.dh_iqc_kd')::numeric iqc_kd,
      (m.j->>'QAC.dh_iqc_ton')::numeric iqc_ton,
      qcd.pqc_kiem, qcd.pqc_loi,
      (m.j->>'QAC.dh_fpy_kiem')::numeric fpy_kiem, (m.j->>'QAC.dh_fpy_dat')::numeric fpy_dat,
      (m.j->>'BHN.ca_qua_han')::numeric bh_quahan,
      nullif(coalesce((m.j->>'KTKLK.dh_kk_ma')::numeric,0) + coalesce((m.j->>'KTKTP.dh_kk_ma')::numeric,0), 0) kk_ma,
      case when (m.j ? 'KTKLK.dh_kk_lech') or (m.j ? 'KTKTP.dh_kk_lech') then coalesce((m.j->>'KTKLK.dh_kk_lech')::numeric,0) + coalesce((m.j->>'KTKTP.dh_kk_lech')::numeric,0) end kk_lech,
      case when (m.j ? 'KTKLK.dh_kk_gt') or (m.j ? 'KTKTP.dh_kk_gt') then coalesce((m.j->>'KTKLK.dh_kk_gt')::numeric,0) + coalesce((m.j->>'KTKTP.dh_kk_gt')::numeric,0) end kk_gt,
      (m.j->>'TKLK.dh_cp_yc')::numeric cp_yc, (m.j->>'TKLK.dh_cp_dung')::numeric cp_dung,
      (m.j->>'KHVT.dh_vt_thieu')::numeric vt_thieu,
      (m.j->>'KTGT.gia_tri_loi')::numeric phe_pham_ngay
    from days dd left join m on m.d = dd.d left join prd on prd.d = dd.d left join pob on pob.d = dd.d
      left join whtp on whtp.d = dd.d left join qcd on qcd.d = dd.d left join hr on hr.d = dd.d)
  select json_build_object(
    'd1', d1, 'd2', d2,
    'days', (select coalesce(json_agg(json_strip_nulls(row_to_json(x)) order by x.d), '[]'::json) from rows x),
    'weekly', (select coalesce(json_agg(w), '[]'::json) from (select week_start, key, value, note from bcdh_weekly where week_start between d1 - 6 and d2) w),
    'defects', (select coalesce(json_agg(f order by f.report_date, f.id), '[]'::json) from (select id, report_date, ma_loi, mo_ta, cong_doan, so_luong, tai_dien from bcdh_defects where report_date between d1 and d2) f),
    'targets', (select coalesce(json_object_agg(stt, json_build_object('dir', dir, 'target', target)), '{}'::json) from bcdh_targets),
    'issues', (select coalesce(json_agg(i order by i.open_date, i.code), '[]'::json) from (
        select s.id, s.code, s.open_date, s.report_code, s.dept_id, dp.code dept_code, dp.name dept_name, s.description, s.initial_cause, s.temp_action, s.root_fix,
               s.owner_name, s.due_date, s.status, s.severity, s.kpi_stt, s.closed_at
        from issues s left join departments dp on dp.id = s.dept_id
        where s.open_date <= d2 and (s.status <> 'closed' or s.closed_at is null or s.closed_at::date >= d1)) i),
    'submits', (select coalesce(json_agg(z), '[]'::json) from (
        select p.report_code code, p.name, p.status, count(distinct dr.report_date) filter (where dr.last_edit_at is not null or dr.metrics <> '{}'::jsonb) days, max(dr.report_date) last
        from positions p left join daily_reports dr on dr.report_code = p.report_code and dr.report_date between d1 and d2
        where p.report_code is not null and p.active group by p.report_code, p.name, p.status, p.id order by p.id) z)
  ) into r;
  return r;
end $$;
revoke execute on function public.bcdh_data(date,date) from anon, public;
grant execute on function public.bcdh_data(date,date) to authenticated;

-- Bỏ ô "Số lô IQC" cũ (mồ côi, chỉ hiển thị Mục 1, không nối KPI) khỏi
-- report_metrics.QAC để tránh trùng với 2 ô mới ở "Số liệu Báo cáo điều
-- hành" (dh_iqc_kiem / dh_iqc_kd, khai báo trong index.html DH_IN.QAC).
update public.app_settings set value = jsonb_set(value, '{QAC}',
  '[["pqc_kt","PQC kiểm tra","sp"],["ng_op","NG thao tác","sp"],["ng_sup","NG nhà cung cấp","sp"],["oqc","OQC kiểm tra","sp"],["capa_mo","CAPA đang mở","việc"]]'::jsonb)
where key = 'report_metrics';
