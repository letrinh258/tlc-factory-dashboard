-- =====================================================================
-- TLC FACTORY OPERATION DASHBOARD · Tổng quan nhà máy – SỐ LIỆU THẬT
-- Tổng hợp từ Form A (SX), B (QAC), C (Cơ điện), D (Kho), E (HCNS), 3S, giao việc, báo cáo ngày
-- p_line null = toàn nhà máy. Chỉ GĐNM. Chạy SAU 01–05b. Chạy lại được.
-- =====================================================================
create or replace function public.dash_summary(d1 date, d2 date, p_line int) returns json
language plpgsql stable security definer set search_path = public as $$
declare std numeric := coalesce((select (value->>'stdProd')::numeric from app_settings where key = 'rules'), 32); r json;
begin
  if not public.is_admin() then raise exception 'Chỉ GĐNM xem tổng quan nhà máy'; end if;
  with pr as (
    select r.*, coalesce(p.norm_per_hour, std) norm, p.norm_per_hour is null no_norm
    from production_reports r left join products p on p.code = r.product_code
    where r.report_date between d1 and d2 and (p_line is null or r.line_id = p_line)),
  qc as (
    select q.*, (select coalesce(sum(df.qty),0) from quality_defects df join defect_types t on t.id = df.defect_type_id where df.report_id = q.id and t.source = 'op') op,
                (select coalesce(sum(df.qty),0) from quality_defects df join defect_types t on t.id = df.defect_type_id where df.report_id = q.id and t.source = 'sup') sup
    from quality_reports q where q.report_date between d1 and d2 and (p_line is null or q.line_id = p_line)),
  mt as (select * from maintenance_reports where report_date between d1 and d2 and (p_line is null or line_id = p_line)),
  ff as (select f.*, a.audit_date from fives_findings f join fives_audits a on a.id = f.audit_id where a.audit_date between d1 and d2)
  select json_build_object(
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
        select t.name, t.source, sum(df.qty) qty from qc join quality_defects df on df.report_id = qc.id join defect_types t on t.id = df.defect_type_id
        where qc.stage = 'PQC' group by t.name, t.source) x),
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
    'fives_overdue', (select count(*) from fives_findings where status <> 'closed' and due_date < public.tlc_today()),
    'tasks', (select json_build_object('open', count(*) filter (where status not in ('done','cancelled')),
        'overdue', count(*) filter (where status not in ('done','cancelled') and due_date < public.tlc_today()),
        'pending_close', count(*) filter (where status = 'pending_confirm'), 'due_req', count(*) filter (where requested_due is not null and status not in ('done','cancelled')),
        'done_in', count(*) filter (where status = 'done' and done_date between d1 and d2)) from tasks),
    'issues_red', (select count(*) from issues where severity = 'red' and status not in ('resolved','closed')),
    'recon_flags', (select count(*) from generate_series(d1, least(d2, public.tlc_today()), interval '1 day') g, lateral public.recon(g::date) x
        where x.flagged and (p_line is null or x.line_id = p_line))
  ) into r;
  return r;
end $$;
revoke execute on function public.dash_summary(date,date,int) from anon, public;
grant execute on function public.dash_summary(date,date,int) to authenticated;
