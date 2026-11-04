-- =====================================================================
-- GĐ23: "Loại lỗi" đổi từ dropdown chọn sẵn sang NHẬP TAY HOÀN TOÀN, ở cả
-- 2 nơi (theo yêu cầu 04/11 — không gợi ý/chọn sẵn nội dung):
--   1) Form A (Sản xuất theo line): "Loại lỗi thao tác" + "Loại lỗi NCC"
--   2) Form B (QAC): 4 dòng "Loại lỗi 1-4" khi lập phiếu kiểm
-- Dữ liệu cũ KHÔNG mất — được chuyển (backfill) từ danh mục defect_types
-- sang chữ (tên loại lỗi cũ) để vẫn hiển thị đúng trên các báo cáo/lịch sử
-- đã nhập trước đây. Bảng defect_types vẫn giữ nguyên (không xóa) để
-- không vỡ dữ liệu cũ còn tham chiếu qua defect_type_id.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Form A: production_reports.defect_op / defect_sup: smallint (FK) -> text (gõ tay)
-- ---------------------------------------------------------------------
alter table public.production_reports add column if not exists defect_op_txt text;
alter table public.production_reports add column if not exists defect_sup_txt text;
update public.production_reports r set defect_op_txt = t.name from public.defect_types t where t.id = r.defect_op and r.defect_op_txt is null;
update public.production_reports r set defect_sup_txt = t.name from public.defect_types t where t.id = r.defect_sup and r.defect_sup_txt is null;
alter table public.production_reports drop column if exists defect_op;
alter table public.production_reports drop column if exists defect_sup;
alter table public.production_reports rename column defect_op_txt to defect_op;
alter table public.production_reports rename column defect_sup_txt to defect_sup;

drop function if exists public.save_prod_row(date,int,text,int,int,int,int,int,int,numeric,time,time,int,int,text,text,bigint,bigint);

create or replace function public.save_prod_row(d date, p_line int, p_product text, p_plan int, p_good int, p_ng_op int, p_ng_sup int,
  p_defect_op text, p_defect_sup text, p_headcount numeric, p_start_time time, p_end_time time, p_break_min int, p_downtime int,
  p_dt_reason text, p_note text, p_order_batch_id bigint default null, p_row_id bigint default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare rid bigint; pl int; mins int; hrs numeric; v_dop text := nullif(trim(p_defect_op),''); v_dsup text := nullif(trim(p_defect_sup),'');
begin
  if not public.can_edit_line(p_line, d) then
    raise exception 'Báo cáo Line % ngày % đã khóa (sau 23:59) hoặc bạn không phụ trách line này', p_line, to_char(d,'DD/MM'); end if;
  if not exists(select 1 from products where code = p_product and active) then raise exception 'Mã sản phẩm % không có trong danh mục', p_product; end if;
  if coalesce(p_good,0) < 0 or coalesce(p_ng_op,0) < 0 or coalesce(p_ng_sup,0) < 0 then raise exception 'Số lượng không được âm'; end if;
  if coalesce(p_good,0) + coalesce(p_ng_op,0) + coalesce(p_ng_sup,0) > 0 and coalesce(p_headcount,0) <= 0 then raise exception 'Nhập số người làm'; end if;
  if p_start_time is null or p_end_time is null then raise exception 'Nhập giờ bắt đầu và giờ kết thúc'; end if;
  mins := (extract(hour from p_end_time)::int*60 + extract(minute from p_end_time)::int)
        - (extract(hour from p_start_time)::int*60 + extract(minute from p_start_time)::int);
  if mins <= 0 then mins := mins + 24*60; end if; -- ca qua đêm: Kết thúc < Bắt đầu coi là qua ngày hôm sau
  mins := mins - coalesce(p_break_min, 0);
  if mins <= 0 then raise exception 'Giờ nghỉ phải nhỏ hơn thời gian làm việc (Kết thúc − Bắt đầu)'; end if;
  hrs := mins / 60.0;
  if hrs > 16 then raise exception 'Thời gian làm việc (sau khi trừ giờ nghỉ) không quá 16 giờ'; end if;
  if coalesce(p_ng_op,0) > 0 and v_dop is null then raise exception 'Nhập loại lỗi cho NG thao tác'; end if;
  if coalesce(p_ng_sup,0) > 0 and v_dsup is null then raise exception 'Nhập loại lỗi cho NG nhà cung cấp'; end if;
  if coalesce(p_downtime,0) > 0 and coalesce(trim(p_dt_reason),'') = '' then raise exception 'Chọn nguyên nhân dừng máy'; end if;
  if p_order_batch_id is not null and not exists(select 1 from production_order_batches b where b.id = p_order_batch_id and b.order_date = d and b.line_id = p_line) then
    raise exception 'Lệnh sản xuất không khớp line/ngày đang nhập'; end if;
  pl := coalesce(p_plan, (select plan_qty from production_plans where plan_date = d and line_id = p_line and product_code = p_product));

  if p_row_id is not null then
    update production_reports set plan_qty = pl, good_qty = coalesce(p_good,0), ng_op = coalesce(p_ng_op,0), ng_sup = coalesce(p_ng_sup,0),
      defect_op = v_dop, defect_sup = v_dsup, headcount = coalesce(p_headcount,0),
      hours = hrs, ot_hours = 0, start_time = p_start_time, end_time = p_end_time, break_min = coalesce(p_break_min,0),
      downtime_min = coalesce(p_downtime,0), downtime_reason = nullif(trim(p_dt_reason),''), note = p_note, last_edit_by = auth.uid()
    where id = p_row_id and report_date = d and line_id = p_line
    returning id into rid;
    if rid is null then raise exception 'Không tìm thấy dòng báo cáo % của line % ngày % để sửa', p_row_id, p_line, to_char(d,'DD/MM'); end if;
  else
    insert into production_reports(report_date, line_id, product_code, plan_qty, good_qty, ng_op, ng_sup, defect_op, defect_sup,
       headcount, hours, ot_hours, start_time, end_time, break_min, downtime_min, downtime_reason, note, order_batch_id, created_by, last_edit_by)
    values (d, p_line, p_product, pl, coalesce(p_good,0), coalesce(p_ng_op,0), coalesce(p_ng_sup,0), v_dop, v_dsup,
       coalesce(p_headcount,0), hrs, 0, p_start_time, p_end_time, coalesce(p_break_min,0), coalesce(p_downtime,0), nullif(trim(p_dt_reason),''), p_note, p_order_batch_id, auth.uid(), auth.uid())
    returning id into rid;
  end if;
  return rid;
end $$;

revoke execute on function public.save_prod_row(date,int,text,int,int,int,int,text,text,numeric,time,time,int,int,text,text,bigint,bigint) from anon, public;
grant execute on function public.save_prod_row(date,int,text,int,int,int,int,text,text,numeric,time,time,int,int,text,text,bigint,bigint) to authenticated;

-- ---------------------------------------------------------------------
-- 2. Form B (QAC): quality_defects.defect_type_id (FK chọn sẵn) -> thêm
--    defect_source ('op'/'sup', vẫn chọn vì cần để cộng dồn NG thao tác/
--    NCC, không phải "loại lỗi") + defect_name (gõ tay, thay cho danh mục)
-- ---------------------------------------------------------------------
alter table public.quality_defects add column if not exists defect_source text;
alter table public.quality_defects add column if not exists defect_name text;
update public.quality_defects qd set defect_source = t.source, defect_name = t.name
  from public.defect_types t where t.id = qd.defect_type_id and qd.defect_source is null;
alter table public.quality_defects alter column defect_type_id drop not null;
alter table public.quality_defects drop constraint if exists quality_defects_source_chk;
alter table public.quality_defects add constraint quality_defects_source_chk check (defect_source in ('op','sup'));

create or replace function public.save_qc(d date, p_stage text, p_line int, p_product text, p_material text, p_supplier text,
  p_inspected int, p_rework int, p_defects jsonb, p_note text) returns bigint
language plpgsql security definer set search_path = public as $$
declare rid bigint; it jsonb; tot int := 0;
begin
  perform public.need_form('QAC', d);
  if p_stage not in ('IQC','PQC','OQC') then raise exception 'Công đoạn kiểm phải là IQC, PQC hoặc OQC'; end if;
  if p_stage in ('PQC','OQC') and (p_line is null or p_product is null) then raise exception 'PQC/OQC: chọn line và mã sản phẩm'; end if;
  if p_stage = 'IQC' and coalesce(trim(p_material),'') = '' then raise exception 'IQC: nhập mã vật tư'; end if;
  if p_product is not null and not exists(select 1 from products where code = p_product) then raise exception 'Mã sản phẩm % không có trong danh mục', p_product; end if;
  if coalesce(p_inspected,0) <= 0 then raise exception 'Nhập số lượng kiểm'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_defects,'[]')) loop
    if coalesce((it->>'qty')::int,0) <= 0 then raise exception 'Số lỗi phải > 0'; end if;
    if coalesce(it->>'source','') not in ('op','sup') then raise exception 'Chọn NG thao tác hoặc NG NCC cho mỗi dòng lỗi'; end if;
    if coalesce(trim(it->>'name'),'') = '' then raise exception 'Nhập loại lỗi'; end if;
    tot := tot + (it->>'qty')::int;
  end loop;
  if tot > p_inspected then raise exception 'Tổng lỗi (%) lớn hơn số kiểm (%)', tot, p_inspected; end if;
  select id into rid from quality_reports where report_date = d and stage = p_stage and coalesce(line_id,0) = coalesce(p_line,0)
    and coalesce(product_code,'') = coalesce(p_product,'') and coalesce(material_code,'') = coalesce(nullif(trim(p_material),''),'');
  if rid is null then
    insert into quality_reports(report_date, stage, line_id, product_code, material_code, supplier, inspected, rework, note)
    values (d, p_stage, p_line, p_product, nullif(trim(p_material),''), nullif(trim(p_supplier),''), p_inspected, coalesce(p_rework,0), p_note) returning id into rid;
  else
    update quality_reports set supplier = nullif(trim(p_supplier),''), inspected = p_inspected, rework = coalesce(p_rework,0), note = p_note where id = rid;
    delete from quality_defects where report_id = rid;
  end if;
  insert into quality_defects(report_id, defect_source, defect_name, qty, cause, action)
    select rid, x->>'source', trim(x->>'name'), (x->>'qty')::int, nullif(x->>'cause',''), nullif(x->>'action','') from jsonb_array_elements(coalesce(p_defects,'[]')) x;
  return rid;
end $$;

-- ---------------------------------------------------------------------
-- 3. Tổng quan (dash_summary): tính NG thao tác/NCC + top lỗi theo
--    defect_source/defect_name mới, vẫn đọc được dữ liệu cũ qua defect_types
--    (coalesce) để không mất lịch sử trước GĐ23
-- ---------------------------------------------------------------------
drop function if exists public.dash_summary(date,date,int,int);
create or replace function public.dash_summary(d1 date, d2 date, p_line int, p_dept int default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare std numeric := coalesce((select (value->>'stdProd')::numeric from app_settings where key = 'rules'), 32); r jsonb;
  full_view boolean := public.can_overview(); dc text; v_dept int := p_dept;
  sec_prod boolean; sec_qc boolean; sec_cd boolean; sec_lines boolean; sec_hr boolean; sec_wh boolean;
begin
  if not full_view then
    if p_dept is null or not coalesce(public.is_head_of(p_dept), false) then raise exception 'Bạn chưa được cấp quyền xem Tổng quan. Liên hệ GĐNM.'; end if;
  end if;
  dc := (select code from departments where id = v_dept);
  sec_prod  := full_view or dc in ('SX','KHSX');
  sec_qc    := full_view or dc = 'QAC';
  sec_cd    := full_view or dc = 'CD';
  sec_lines := full_view or dc in ('SX','KHSX','CD');
  sec_hr    := full_view or dc = 'HCNS';
  sec_wh    := full_view or dc = 'KHO';
  with pr as (
    select r.*, coalesce(p.norm_per_hour, std) norm, p.norm_per_hour is null no_norm
    from production_reports r left join products p on p.code = r.product_code
    where r.report_date between d1 and d2 and (p_line is null or r.line_id = p_line)),
  qc as (
    select q.*, (select coalesce(sum(df.qty),0) from quality_defects df left join defect_types t on t.id = df.defect_type_id
                   where df.report_id = q.id and coalesce(df.defect_source, t.source) = 'op') op,
                (select coalesce(sum(df.qty),0) from quality_defects df left join defect_types t on t.id = df.defect_type_id
                   where df.report_id = q.id and coalesce(df.defect_source, t.source) = 'sup') sup
    from quality_reports q where q.report_date between d1 and d2 and (p_line is null or q.line_id = p_line)),
  mt as (select * from maintenance_reports where report_date between d1 and d2 and (p_line is null or line_id = p_line)),
  ff as (select f.*, a.audit_date from fives_findings f join fives_audits a on a.id = f.audit_id where a.audit_date between d1 and d2 and (v_dept is null or a.target_dept_id = v_dept))
  select jsonb_build_object(
    'mode', case when full_view then 'full' else 'dept' end, 'dept', dc,
    'prod', (select json_build_object('rows', count(*), 'days', count(distinct report_date), 'plan', coalesce(sum(plan_qty),0), 'plan_rows', count(plan_qty),
        'good', coalesce(sum(good_qty),0), 'ng_op', coalesce(sum(ng_op),0), 'ng_sup', coalesce(sum(ng_sup),0),
        'man_hours', coalesce(sum(headcount * (hours + ot_hours)),0), 'ot_hours', coalesce(sum(headcount * ot_hours),0),
        'std_hours', coalesce(sum(good_qty / nullif(norm,0)),0), 'downtime', coalesce(sum(downtime_min),0),
        'no_norm', count(*) filter (where no_norm)) from pr),
    'qc', (select json_build_object('pqc_insp', coalesce(sum(inspected) filter (where stage = 'PQC'),0), 'pqc_op', coalesce(sum(op) filter (where stage = 'PQC'),0),
        'pqc_sup', coalesce(sum(sup) filter (where stage = 'PQC'),0), 'rework', coalesce(sum(rework) filter (where stage = 'PQC'),0),
        'iqc_insp', coalesce(sum(inspected) filter (where stage = 'IQC'),0), 'iqc_ng', coalesce(sum(op + sup) filter (where stage = 'IQC'),0),
        'oqc_insp', coalesce(sum(inspected) filter (where stage = 'OQC'),0), 'oqc_ng', coalesce(sum(op + sup) filter (where stage = 'OQC'),0)) from qc),
    'defects', (select coalesce(json_agg(x order by x.qty desc), '[]') from (
        select coalesce(df.defect_name, t.name) name, coalesce(df.defect_source, t.source) source, sum(df.qty) qty
        from qc join quality_defects df on df.report_id = qc.id left join defect_types t on t.id = df.defect_type_id
        where qc.stage = 'PQC' group by coalesce(df.defect_name, t.name), coalesce(df.defect_source, t.source)) x),
    'cd', (select json_build_object('stops', count(*) filter (where kind = 'breakdown'), 'downtime', coalesce(sum(downtime_min) filter (where kind = 'breakdown'),0),
        'open', count(*) filter (where kind = 'breakdown' and end_at is null), 'pm', count(*) filter (where kind = 'pm')) from mt),
    'lines', (select coalesce(json_agg(x order by x.line_id), '[]') from (
        select l.id line_id, l.name, coalesce(sum(p.plan_qty),0) plan, count(p.plan_qty) plan_rows, coalesce(sum(p.good_qty),0) good,
          coalesce(sum(p.ng_op),0) ng_op, coalesce(sum(p.ng_sup),0) ng_sup, coalesce(sum(p.headcount * (p.hours + p.ot_hours)),0) man_hours,
          coalesce(sum(p.good_qty / nullif(p.norm,0)),0) std_hours, coalesce(sum(p.downtime_min),0) dt_sx,
          (select coalesce(sum(downtime_min),0) from mt where mt.line_id = l.id and mt.kind = 'breakdown') dt_cd, count(p.id) n_rows
        from production_lines l left join pr p on p.line_id = l.id where l.active and (p_line is null or l.id = p_line) group by l.id, l.name) x),
    'trend', (select coalesce(json_agg(x order by x.d), '[]') from (
        select report_date d, sum(plan_qty) plan, sum(good_qty) good, sum(ng_op + ng_sup) ng, sum(good_qty / nullif(norm,0)) std_hours,
          sum(headcount * (hours + ot_hours)) man_hours, sum(downtime_min) dt from pr group by report_date) x),
    'top_codes', (select coalesce(json_agg(x), '[]') from (
        select product_code code, (select name from products where code = product_code) name, sum(good_qty) good, sum(ng_op) ng_op, sum(ng_sup) ng_sup,
          sum(good_qty / nullif(norm,0)) / nullif(sum(headcount * (hours + ot_hours)),0) * 100 prod_pct, bool_or(no_norm) no_norm
        from pr group by product_code order by sum(good_qty) desc limit 10) x),
    'hr', (select json_build_object('days', count(*), 'total', (select total from hr_reports where report_date between d1 and d2 order by report_date desc limit 1),
        'present_avg', avg(present), 'absent_avg', avg(absent), 'absent_pct', avg(absent::numeric / nullif(total,0) * 100), 'new', coalesce(sum(new_hires),0),
        'quits', coalesce(sum(quits),0), 'recruiting', (select recruiting from hr_reports where report_date between d1 and d2 order by report_date desc limit 1))
        from hr_reports where report_date between d1 and d2),
    'wh', (select json_build_object('receipt_sx', coalesce(sum(qty) filter (where kind = 'receipt_sx' and (p_line is null or line_id = p_line)),0),
        'shortage_items', count(distinct item_code) filter (where kind = 'shortage'), 'ng_return', coalesce(sum(qty) filter (where kind = 'ng_return'),0))
        from wh_entries where report_date between d1 and d2),
    'fives', (select json_build_object('s1', count(*) filter (where criterion = 'S1'), 's2', count(*) filter (where criterion = 'S2'), 's3', count(*) filter (where criterion = 'S3'),
        'open', count(*) filter (where status <> 'closed'), 'closed', count(*) filter (where status = 'closed')) from ff),
    'fives_overdue', (select count(*) from fives_findings f join fives_audits a on a.id = f.audit_id where f.status <> 'closed' and f.due_date < public.tlc_today() and (v_dept is null or a.target_dept_id = v_dept)),
    'tasks', (select json_build_object('open', count(*) filter (where status not in ('done','cancelled')),
        'overdue', count(*) filter (where status not in ('done','cancelled') and due_date < public.tlc_today()),
        'pending_close', count(*) filter (where status = 'pending_confirm'), 'due_req', count(*) filter (where requested_due is not null and status not in ('done','cancelled')),
        'done_in', count(*) filter (where status = 'done' and done_date between d1 and d2)) from tasks where v_dept is null or dept_id = v_dept),
    'issues_red', (select count(*) from issues where severity = 'red' and status not in ('resolved','closed') and (v_dept is null or public.dept_of_code(report_code) = v_dept)),
    'recon_flags', (select count(*) from generate_series(d1, least(d2, public.tlc_today()), interval '1 day') g, lateral public.recon(g::date) x
        where x.flagged and (p_line is null or x.line_id = p_line)
          and (v_dept is null or (dc in ('SX','KHSX')) or (dc = 'KHO' and x.flow like 'SX → Kho%') or (dc = 'QAC' and x.flow like 'NG%') or (dc = 'CD' and x.flow like 'Dừng%')))
  ) into r;
  if not sec_prod then r := r - 'prod' - 'top_codes' - 'trend'; end if;
  if not sec_lines then r := r - 'lines'; end if;
  if not sec_qc then r := r - 'qc' - 'defects'; end if;
  if not sec_cd then r := r - 'cd'; end if;
  if not sec_hr then r := r - 'hr'; end if;
  if not sec_wh then r := r - 'wh'; end if;
  return r::json;
end $$;
revoke execute on function public.can_overview(), public.dash_summary(date,date,int,int) from anon, public;
grant execute on function public.can_overview(), public.dash_summary(date,date,int,int) to authenticated;

-- Kiểm tra sau khi chạy:
-- select column_name,data_type from information_schema.columns where table_name='production_reports' and column_name in ('defect_op','defect_sup'); -- text, text
-- select column_name,data_type,is_nullable from information_schema.columns where table_name='quality_defects' and column_name in ('defect_type_id','defect_source','defect_name');
-- select proname,pronargs from pg_proc where proname in ('save_prod_row','save_qc','dash_summary');
