-- =====================================================================
-- TLC FACTORY OPERATION DASHBOARD · Giai đoạn 5B
-- Định mức năng suất do GĐNM thiết lập trong Cấu hình (có lịch sử)
-- Form B QAC · Form C Cơ điện · Form D Kho · Form E HCNS · Đối chiếu tự động với SX
-- Chạy SAU file 01, 02, 03. Chạy lại được.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. ĐỊNH MỨC: GĐNM sửa trong Cấu hình; số đã sửa tay không bị file Bravo ghi đè
-- ---------------------------------------------------------------------
alter table public.products add column if not exists norm_manual boolean not null default false;
alter table public.products add column if not exists norm_updated_at timestamptz;
alter table public.products add column if not exists norm_updated_by uuid;
create table if not exists public.norm_changes(
  id bigserial primary key, product_code text not null references public.products(code) on delete cascade,
  old_norm numeric, new_norm numeric, note text, changed_by uuid default auth.uid(), changed_at timestamptz not null default now()
);
alter table public.norm_changes enable row level security;
revoke all on public.norm_changes from anon;

-- items: [{"code":"TLC-...","norm":120}] ; norm null = xóa định mức (dùng định mức mặc định)
create or replace function public.set_norms(p_items jsonb, p_note text) returns json language plpgsql security definer set search_path = public as $$
declare it jsonb; c text; n numeric; o numeric; ok int := 0; bad text[] := '{}';
begin
  if not public.is_admin() then raise exception 'Chỉ GĐNM được sửa định mức'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Không có dòng nào để lưu'; end if;
  if jsonb_array_length(p_items) > 2000 then raise exception 'Tối đa 2.000 dòng mỗi lần'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    c := trim(it->>'code');
    n := case when it->>'norm' is null or trim(it->>'norm') = '' then null else (it->>'norm')::numeric end;
    if n is not null and (n <= 0 or n > 100000) then bad := bad || (c || ': định mức phải > 0'); continue; end if;
    select norm_per_hour into o from products where code = c;
    if not found then bad := bad || (c || ': không có mã'); continue; end if;
    if o is not distinct from n then continue; end if;
    update products set norm_per_hour = n, norm_manual = true, norm_updated_at = now(), norm_updated_by = auth.uid() where code = c;
    insert into norm_changes(product_code, old_norm, new_norm, note) values (c, o, n, p_note);
    ok := ok + 1;
  end loop;
  return json_build_object('saved', ok, 'errors', bad);
end $$;

-- ---------------------------------------------------------------------
-- 2. QUYỀN NHẬP FORM BỘ PHẬN: thành viên BP (hoặc GĐNM); hôm nay hoặc GĐNM mở khóa mã FORM-<BP>
-- ---------------------------------------------------------------------
create or replace function public.can_edit_form(p_dept text, d date) returns boolean language sql stable security definer set search_path = public as $$
  select public.is_active_user() and (public.is_admin() or public.in_dept(public.dept_id_of(p_dept)))
     and (d = public.tlc_today()
          or exists(select 1 from report_unlocks u where u.report_code = 'FORM-' || p_dept and u.report_date = d and u.until_at > now()))
$$;
create or replace function public.need_form(p_dept text, d date) returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_edit_form(p_dept, d) then
    raise exception 'Form % ngày % đã khóa (sau 23:59) hoặc bạn không thuộc bộ phận này', p_dept, to_char(d,'DD/MM'); end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. FORM B – QAC: kiểm PQC/OQC theo line × mã; IQC theo vật tư × NCC; lỗi theo loại (thao tác / NCC)
-- ---------------------------------------------------------------------
create unique index if not exists quality_reports_key on public.quality_reports
  (report_date, stage, coalesce(line_id, 0), coalesce(product_code, ''), coalesce(material_code, ''));
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
    if not exists(select 1 from defect_types where id = (it->>'type')::int) then raise exception 'Loại lỗi không hợp lệ'; end if;
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
  insert into quality_defects(report_id, defect_type_id, qty, cause, action)
    select rid, (x->>'type')::int, (x->>'qty')::int, nullif(x->>'cause',''), nullif(x->>'action','') from jsonb_array_elements(coalesce(p_defects,'[]')) x;
  return rid;
end $$;
create or replace function public.delete_qc(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
declare d date;
begin select report_date into d from quality_reports where id = p_id; if not found then raise exception 'Không tìm thấy'; end if;
  perform public.need_form('QAC', d); delete from quality_reports where id = p_id; end $$;

-- ---------------------------------------------------------------------
-- 4. FORM C – CƠ ĐIỆN: sự cố / dừng máy theo line, giờ bắt đầu – kết thúc
-- ---------------------------------------------------------------------
alter table public.maintenance_reports add column if not exists equipment_name text;
create or replace function public.save_mt(p_id bigint, d date, p_line int, p_equipment text, p_kind text, p_start text, p_end text,
  p_cause text, p_action text, p_parts text) returns bigint
language plpgsql security definer set search_path = public as $$
declare s timestamptz; e timestamptz; rid bigint;
begin
  perform public.need_form('CD', d);
  if p_kind not in ('breakdown','pm','improvement') then raise exception 'Loại công việc không hợp lệ'; end if;
  if coalesce(trim(p_equipment),'') = '' then raise exception 'Nhập tên máy / thiết bị'; end if;
  if p_start !~ '^([01]\d|2[0-3]):[0-5]\d$' then raise exception 'Giờ bắt đầu dạng HH:MM'; end if;
  s := (d::text || ' ' || p_start)::timestamp at time zone 'Asia/Ho_Chi_Minh';
  if coalesce(p_end,'') <> '' then
    if p_end !~ '^([01]\d|2[0-3]):[0-5]\d$' then raise exception 'Giờ kết thúc dạng HH:MM'; end if;
    e := (d::text || ' ' || p_end)::timestamp at time zone 'Asia/Ho_Chi_Minh';
    if e <= s then raise exception 'Giờ kết thúc phải sau giờ bắt đầu'; end if;
  end if;
  if p_kind = 'breakdown' and coalesce(trim(p_cause),'') = '' then raise exception 'Ghi nguyên nhân hỏng'; end if;
  if p_id is null then
    insert into maintenance_reports(report_date, line_id, equipment_name, kind, start_at, end_at, downtime_min, cause, action, parts)
    values (d, p_line, trim(p_equipment), p_kind, s, e, coalesce((extract(epoch from e - s) / 60)::int, 0), p_cause, p_action, p_parts) returning id into rid;
  else
    update maintenance_reports set line_id = p_line, equipment_name = trim(p_equipment), kind = p_kind, start_at = s, end_at = e,
      downtime_min = coalesce((extract(epoch from e - s) / 60)::int, 0), cause = p_cause, action = p_action, parts = p_parts
    where id = p_id and report_date = d returning id into rid;
    if rid is null then raise exception 'Không tìm thấy phiếu'; end if;
  end if;
  return rid;
end $$;
create or replace function public.delete_mt(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
declare d date;
begin select report_date into d from maintenance_reports where id = p_id; if not found then raise exception 'Không tìm thấy'; end if;
  perform public.need_form('CD', d); delete from maintenance_reports where id = p_id; end $$;

-- ---------------------------------------------------------------------
-- 5. FORM D – KHO: TP nhập kho từ SX theo line × mã · LK thiếu vật tư · NG trả về
-- ---------------------------------------------------------------------
create table if not exists public.wh_entries(
  id bigserial primary key, report_date date not null,
  warehouse text not null check (warehouse in ('TP','LK')),
  kind text not null check (kind in ('receipt_sx','shortage','ng_return')),
  line_id smallint references public.production_lines(id), item_code text not null, qty numeric not null check (qty > 0),
  ref text, expected_date date, note text,
  created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
alter table public.wh_entries enable row level security;
revoke all on public.wh_entries from anon;
drop trigger if exists audit on public.wh_entries;
create trigger audit after insert or update or delete on public.wh_entries for each row execute function public.tg_audit();
create or replace function public.save_wh(p_id bigint, d date, p_wh text, p_kind text, p_line int, p_item text, p_qty numeric,
  p_ref text, p_expected date, p_note text) returns bigint
language plpgsql security definer set search_path = public as $$
declare rid bigint;
begin
  perform public.need_form('KHO', d);
  if not ((p_wh = 'TP' and p_kind = 'receipt_sx') or (p_wh = 'LK' and p_kind in ('shortage','ng_return'))) then raise exception 'Loại phiếu không đúng kho'; end if;
  if coalesce(trim(p_item),'') = '' then raise exception 'Nhập mã hàng'; end if;
  if coalesce(p_qty,0) <= 0 then raise exception 'Số lượng phải > 0'; end if;
  if p_kind = 'receipt_sx' then
    if p_line is null then raise exception 'Chọn line giao hàng'; end if;
    if not exists(select 1 from products where code = trim(p_item)) then raise exception 'Mã thành phẩm % không có trong danh mục', p_item; end if;
  end if;
  if p_id is null then
    insert into wh_entries(report_date, warehouse, kind, line_id, item_code, qty, ref, expected_date, note)
    values (d, p_wh, p_kind, p_line, trim(p_item), p_qty, nullif(trim(p_ref),''), p_expected, p_note) returning id into rid;
  else
    update wh_entries set line_id = p_line, item_code = trim(p_item), qty = p_qty, ref = nullif(trim(p_ref),''), expected_date = p_expected, note = p_note
    where id = p_id and report_date = d and warehouse = p_wh and kind = p_kind returning id into rid;
    if rid is null then raise exception 'Không tìm thấy phiếu'; end if;
  end if;
  return rid;
end $$;
create or replace function public.delete_wh(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
declare d date;
begin select report_date into d from wh_entries where id = p_id; if not found then raise exception 'Không tìm thấy'; end if;
  perform public.need_form('KHO', d); delete from wh_entries where id = p_id; end $$;

-- ---------------------------------------------------------------------
-- 6. FORM E – HCNS: nhân lực trong ngày
-- ---------------------------------------------------------------------
create or replace function public.save_hr(d date, p_total int, p_present int, p_new int, p_quits int, p_recruiting int, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.need_form('HCNS', d);
  if coalesce(p_total,0) <= 0 then raise exception 'Nhập tổng định biên'; end if;
  if p_present is null or p_present < 0 or p_present > p_total then raise exception 'Số đi làm phải từ 0 đến tổng định biên'; end if;
  if coalesce(p_new,0) < 0 or coalesce(p_quits,0) < 0 or coalesce(p_recruiting,0) < 0 then raise exception 'Số không được âm'; end if;
  insert into hr_reports(report_date, total, present, absent, new_hires, quits, recruiting, note)
  values (d, p_total, p_present, p_total - p_present, coalesce(p_new,0), coalesce(p_quits,0), coalesce(p_recruiting,0), p_note)
  on conflict (report_date) do update set total = excluded.total, present = excluded.present, absent = excluded.absent,
    new_hires = excluded.new_hires, quits = excluded.quits, recruiting = excluded.recruiting, note = excluded.note;
end $$;

-- ---------------------------------------------------------------------
-- 7. ĐỐI CHIẾU TỰ ĐỘNG (luồng 1 SX→Kho TP · luồng 3 QAC NG↔SX NG · luồng 5 CĐ dừng máy↔SX)
-- ---------------------------------------------------------------------
create or replace function public.recon(d date) returns table(flow text, line_id smallint, item text, label_a text, qty_a numeric, label_b text, qty_b numeric, diff numeric, flagged boolean)
language sql stable security definer set search_path = public as $$
  with r as (select coalesce((select value from app_settings where key = 'rules'), '{}'::jsonb) v),
  sx as (select line_id, product_code, sum(good_qty) good, sum(ng_op) op, sum(ng_sup) sup, sum(downtime_min) dt
         from production_reports where report_date = d group by 1, 2),
  tp as (select line_id, item_code product_code, sum(qty) q from wh_entries where report_date = d and kind = 'receipt_sx' group by 1, 2),
  qc as (select q.line_id, q.product_code, sum(df.qty) filter (where t.source = 'op') op, sum(df.qty) filter (where t.source = 'sup') sup
         from quality_reports q join quality_defects df on df.report_id = q.id join defect_types t on t.id = df.defect_type_id
         where q.report_date = d and q.stage = 'PQC' group by 1, 2),
  mt as (select line_id, sum(downtime_min) dt from maintenance_reports where report_date = d and kind = 'breakdown' and line_id is not null group by 1),
  rows as (
    select 'SX → Kho TP'::text flow, coalesce(sx.line_id, tp.line_id) line_id, coalesce(sx.product_code, tp.product_code) item,
           'SX báo đạt'::text la, coalesce(sx.good,0)::numeric a, 'Kho TP nhận'::text lb, coalesce(tp.q,0)::numeric b, 'qty'::text k
      from sx full join tp on tp.line_id = sx.line_id and tp.product_code = sx.product_code
      where coalesce(sx.good,0) > 0 or coalesce(tp.q,0) > 0
    union all
    select 'NG thao tác: SX ↔ QAC', coalesce(sx.line_id, qc.line_id), coalesce(sx.product_code, qc.product_code), 'SX báo', coalesce(sx.op,0), 'QAC PQC', coalesce(qc.op,0), 'ng'
      from sx full join qc on qc.line_id = sx.line_id and qc.product_code = sx.product_code where coalesce(sx.op,0) + coalesce(qc.op,0) > 0
    union all
    select 'NG NCC: SX ↔ QAC', coalesce(sx.line_id, qc.line_id), coalesce(sx.product_code, qc.product_code), 'SX báo', coalesce(sx.sup,0), 'QAC PQC', coalesce(qc.sup,0), 'ng'
      from sx full join qc on qc.line_id = sx.line_id and qc.product_code = sx.product_code where coalesce(sx.sup,0) + coalesce(qc.sup,0) > 0
    union all
    select 'Dừng máy: SX ↔ Cơ điện', coalesce(s.line_id, mt.line_id), null, 'SX báo (phút)', coalesce(s.dt,0), 'Cơ điện (phút)', coalesce(mt.dt,0), 'dt'
      from (select line_id, sum(dt) dt from sx group by 1) s full join mt on mt.line_id = s.line_id where coalesce(s.dt,0) + coalesce(mt.dt,0) > 0
  )
  select flow, line_id::smallint, item, la, a, lb, b, b - a,
    case k when 'qty' then a <> b
           when 'ng' then abs(b - a) > coalesce((r.v->>'ngDiffQty')::numeric, 5) and abs(b - a) > greatest(a, b) * coalesce((r.v->>'ngDiffPct')::numeric, 10) / 100
           else abs(b - a) > coalesce((r.v->>'dtDiffMin')::numeric, 15) end
  from rows, r
  where public.is_admin() or public.in_dept(public.dept_id_of('SX')) or public.in_dept(public.dept_id_of('QAC'))
     or public.in_dept(public.dept_id_of('KHO')) or public.in_dept(public.dept_id_of('CD')) or public.in_dept(public.dept_id_of('KHSX'))
  order by flow, line_id, item
$$;

-- ---------------------------------------------------------------------
-- 8. RLS: ghi chỉ qua hàm; xem theo bộ phận + GĐNM
-- ---------------------------------------------------------------------
do $$ declare t text; begin
  foreach t in array array['quality_reports','maintenance_reports','hr_reports'] loop
    execute format('drop policy if exists dept_insert on public.%I', t);
    execute format('drop policy if exists dept_update on public.%I', t);
  end loop; end $$;
drop policy if exists defects_all on public.quality_defects;
drop policy if exists defects_read on public.quality_defects;
create policy defects_read on public.quality_defects for select to authenticated using (exists(select 1 from public.quality_reports r where r.id = report_id));
drop policy if exists cross_read on public.quality_reports;
create policy cross_read on public.quality_reports for select to authenticated using (public.in_dept(public.dept_id_of('SX')));
drop policy if exists cross_read on public.maintenance_reports;
create policy cross_read on public.maintenance_reports for select to authenticated using (public.in_dept(public.dept_id_of('SX')));
drop policy if exists dept_read on public.wh_entries;
create policy dept_read on public.wh_entries for select to authenticated using (public.is_admin() or public.in_dept(public.dept_id_of('KHO'))
  or public.in_dept(public.dept_id_of('SX')) or public.in_dept(public.dept_id_of('KHSX')));
drop policy if exists admin_read on public.norm_changes;
create policy admin_read on public.norm_changes for select to authenticated using (public.is_admin());

-- Danh mục SP: định mức đã sửa tay giữ nguyên khi nạp lại file Bravo (xem 03b_products.sql)

revoke execute on function public.set_norms(jsonb,text), public.can_edit_form(text,date), public.need_form(text,date),
  public.save_qc(date,text,int,text,text,text,int,int,jsonb,text), public.delete_qc(bigint),
  public.save_mt(bigint,date,int,text,text,text,text,text,text,text), public.delete_mt(bigint),
  public.save_wh(bigint,date,text,text,int,text,numeric,text,date,text), public.delete_wh(bigint),
  public.save_hr(date,int,int,int,int,int,text), public.recon(date) from anon, public;
grant execute on function public.set_norms(jsonb,text), public.can_edit_form(text,date), public.need_form(text,date),
  public.save_qc(date,text,int,text,text,text,int,int,jsonb,text), public.delete_qc(bigint),
  public.save_mt(bigint,date,int,text,text,text,text,text,text,text), public.delete_mt(bigint),
  public.save_wh(bigint,date,text,text,int,text,numeric,text,date,text), public.delete_wh(bigint),
  public.save_hr(date,int,int,int,int,int,text), public.recon(date) to authenticated;
