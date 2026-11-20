-- =====================================================================
-- GĐ34 (20/11): BÁO CÁO ĐIỀU HÀNH TLC thay thế toàn bộ nội dung trang
-- "Báo cáo KPI" (GĐ30–32). Cấu trúc theo bản demo đã duyệt: 25 chỉ tiêu,
-- 5 nhóm (Sản lượng & giao hàng / Năng suất & con người / Chất lượng /
-- Chi phí & tài sản / Cung ứng & điều độ SX), xem theo Tuần hoặc Tháng,
-- mỗi nhóm có bảng Vấn đề phát sinh – Nguyên nhân – Bộ phận chủ trì –
-- Hành động khắc phục – Người phụ trách – Hạn hoàn thành.
--
-- NGUỒN SỐ LIỆU = dữ liệu các bộ phận nhập HẰNG NGÀY (không dùng Excel):
--  * Tự động từ form đang có: Lệnh SX (KH), Kho TP (nhập kho), Form A
--    (sản lượng, giờ công, dừng chuyền theo nguyên nhân), Form B QAC
--    (IQC/PQC), Form E HCNS, Báo cáo ngày BHN (ca quá cam kết).
--  * Ô nhập MỚI trong Báo cáo hằng ngày (khóa "dh_*" trong
--    daily_reports.metrics): KHSX, QAC, HCNS, KTKLK/KTKTP, TKLK, KHVT.
--  * Danh sách lỗi nghiêm trọng: bảng mới bcdh_defects (QAC nhập).
--  * 3 chỉ tiêu tuần (phế phẩm, VT vượt ĐM, chi phí ngoài KH): GĐNM nhập
--    tay theo tuần (bcdh_weekly) — giữ như cách làm hiện tại.
--  * Mục tiêu: bcdh_targets, GĐNM sửa ngay trên trang báo cáo.
--  * Vấn đề: dùng bảng issues (mục 2 Báo cáo ngày) + cột mới kpi_stt.
-- Các bảng cũ của Báo cáo KPI (kpi_overrides, kpi_plan_items...) GIỮ
-- NGUYÊN, không xóa — chỉ không còn hiển thị.
-- =====================================================================

-- 1. Vấn đề gắn với chỉ tiêu báo cáo điều hành
alter table public.issues add column if not exists kpi_stt smallint;

-- 2. Lỗi nghiêm trọng (QAC nhập trong Báo cáo hằng ngày)
create table if not exists public.bcdh_defects(
  id bigint generated always as identity primary key,
  report_date date not null,
  ma_loi text,
  mo_ta text not null,
  cong_doan text,
  so_luong numeric,
  tai_dien boolean not null default false,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists idx_bcdh_defects_date on public.bcdh_defects(report_date);
alter table public.bcdh_defects enable row level security;
create policy bcdh_def_read on public.bcdh_defects for select to authenticated
  using (public.can_overview() or public.in_dept(public.dept_id_of('QAC')));
create policy bcdh_def_write on public.bcdh_defects for all to authenticated
  using (public.is_admin() or public.in_dept(public.dept_id_of('QAC')))
  with check (public.is_admin() or public.in_dept(public.dept_id_of('QAC')));

-- 3. Chỉ tiêu nhập tay theo tuần (GĐNM/trợ lý)
create table if not exists public.bcdh_weekly(
  week_start date not null,
  key text not null check (key in ('phe_pham','vt_vuot','cp_ngoai')),
  value numeric,
  note text,
  updated_by uuid references auth.users(id) default auth.uid(),
  updated_at timestamptz not null default now(),
  primary key (week_start, key)
);
alter table public.bcdh_weekly enable row level security;
create policy bcdh_wk_read on public.bcdh_weekly for select to authenticated using (public.can_overview());
create policy bcdh_wk_write on public.bcdh_weekly for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- 4. Mục tiêu từng chỉ tiêu (GĐNM sửa trên trang)
create table if not exists public.bcdh_targets(
  stt smallint primary key,
  dir text not null default 'min' check (dir in ('max','min')),
  target numeric,
  updated_by uuid references auth.users(id) default auth.uid(),
  updated_at timestamptz not null default now()
);
alter table public.bcdh_targets enable row level security;
create policy bcdh_tg_read on public.bcdh_targets for select to authenticated using (true);
create policy bcdh_tg_write on public.bcdh_targets for all to authenticated using (public.is_admin()) with check (public.is_admin());
insert into public.bcdh_targets(stt,dir,target) values
 (1,'max',null),(2,'max',100),(3,'min',null),(4,'min',0),(5,'min',0),
 (8,'max',90),(9,'max',null),(10,'min',300),(11,'min',2),(12,'min',0),
 (15,'min',3),(16,'min',5),(17,'min',1.5),(18,'max',97),(19,'min',0),(20,'min',0),(21,'min',0),
 (22,'min',10),(23,'min',5),(24,'min',10),(25,'min',2),(26,'min',5),
 (27,'min',0),(28,'min',0),(29,'max',95)
on conflict (stt) do nothing;

-- 5. Dữ liệu báo cáo điều hành theo ngày cho khoảng d1..d2
create or replace function public.bcdh_data(d1 date, d2 date)
returns json language plpgsql stable security definer set search_path = public as $$
declare std numeric := coalesce((select (value->>'stdProd')::numeric from app_settings where key = 'rules'), 32);
  r json;
begin
  if not public.can_overview() then raise exception 'Bạn chưa được cấp quyền xem Báo cáo điều hành. Liên hệ GĐNM.'; end if;
  if d2 < d1 or d2 - d1 > 62 then raise exception 'Khoảng ngày không hợp lệ (tối đa 63 ngày)'; end if;
  with days as (select g::date d from generate_series(d1, d2, interval '1 day') g),
  -- số nhập trong Báo cáo hằng ngày (mục 1), cộng theo mã vị trí + ngày
  dm as (select dr.report_date d, dr.report_code c, kv.key k, sum(case when kv.value ~ '^-?[0-9]+(\.[0-9]+)?$' then kv.value::numeric end) v
         from daily_reports dr, jsonb_each_text(coalesce(dr.metrics,'{}'::jsonb)) kv
         where dr.report_date between d1 and d2 group by 1,2,3),
  m as (select d, jsonb_object_agg(c||'.'||k, v) j from dm where v is not null group by d),
  -- Form A sản xuất
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
  -- Form B QAC
  qc as (select q.report_date d, q.stage, q.inspected, (select coalesce(sum(qty),0) from quality_defects x where x.report_id = q.id) ng
         from quality_reports q where q.report_date between d1 and d2),
  qcd as (select d, count(*) filter (where stage='IQC') iqc_kiem, count(*) filter (where stage='IQC' and ng > 0) iqc_kd,
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
      nullif(qcd.iqc_kiem,0) iqc_kiem, case when coalesce(qcd.iqc_kiem,0) > 0 then qcd.iqc_kd end iqc_kd,
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
