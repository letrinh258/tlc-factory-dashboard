-- =====================================================================
-- TLC FACTORY OPERATION DASHBOARD · Giai đoạn 5A
-- Form A – Báo cáo sản xuất theo line × mã SP × ngày (tổ trưởng nhập)
-- Chạy SAU file 01, 02. Chạy lại được. Danh mục sản phẩm: file 03b_products.sql
-- =====================================================================

-- 1. Tổ trưởng ↔ line (1 người giữ được nhiều line)
create table if not exists public.user_lines(
  profile_id uuid not null references public.profiles(id) on delete cascade,
  line_id smallint not null references public.production_lines(id),
  created_at timestamptz not null default now(),
  primary key(profile_id, line_id)
);
alter table public.user_lines enable row level security;
revoke all on public.user_lines from anon;

-- 2. Báo cáo SX: tách NG thao tác / NG NCC, nguyên nhân dừng máy, người sửa cuối
alter table public.production_reports add column if not exists ng_op int not null default 0;
alter table public.production_reports add column if not exists ng_sup int not null default 0;
alter table public.production_reports add column if not exists defect_op smallint references public.defect_types(id);
alter table public.production_reports add column if not exists defect_sup smallint references public.defect_types(id);
alter table public.production_reports add column if not exists downtime_reason text;
alter table public.production_reports add column if not exists last_edit_by uuid;
alter table public.production_reports drop constraint if exists production_reports_ng_split_check;
alter table public.production_reports add constraint production_reports_ng_split_check
  check (ng_op >= 0 and ng_sup >= 0 and headcount >= 0 and hours >= 0 and ot_hours >= 0 and downtime_min >= 0);

create or replace function public.tg_prod_ng() returns trigger language plpgsql as $$
begin new.ng_qty := coalesce(new.ng_op,0) + coalesce(new.ng_sup,0); return new; end $$;
drop trigger if exists prod_ng on public.production_reports;
create trigger prod_ng before insert or update on public.production_reports for each row execute function public.tg_prod_ng();

-- 3. Cấu hình
insert into public.app_settings(key, value) values
 ('downtime_reasons', '["Hỏng máy / thiết bị","Thiếu vật tư","Chờ kế hoạch / đổi mã","Thiếu người","Mất điện","Chờ QC / xử lý lỗi","Khác"]')
on conflict (key) do nothing;
-- Hạn tổ trưởng nhập: dùng rules.cutoff (Cấu hình → Line & quy tắc), mặc định 17:30

-- 4. Quyền
-- Line người đang đăng nhập được nhập: GĐNM, TBP SX (hoặc người kiêm nhiệm) = mọi line; tổ trưởng = line được gán
create or replace function public.my_lines() returns smallint[] language sql stable security definer set search_path = public as $$
  select case when public.is_admin() or public.is_head_of(public.dept_id_of('SX'))
              then (select coalesce(array_agg(id order by id), '{}') from production_lines where active)
              else (select coalesce(array_agg(ul.line_id order by ul.line_id), '{}') from user_lines ul
                     join profiles p on p.id = ul.profile_id where ul.profile_id = auth.uid() and p.status = 'active') end
$$;
-- Sửa được ngày d: hôm nay, hoặc GĐNM đã mở khóa mã LINE-n cho ngày đó
create or replace function public.can_edit_line(p_line int, d date) returns boolean language sql stable security definer set search_path = public as $$
  select public.is_active_user() and p_line = any(public.my_lines())
     and (d = public.tlc_today()
          or exists(select 1 from report_unlocks u where u.report_code = 'LINE-' || p_line and u.report_date = d and u.until_at > now()))
$$;

-- Lưu 1 dòng (thêm mới hoặc sửa theo ngày + line + mã)
create or replace function public.save_prod_row(d date, p_line int, p_product text, p_plan int, p_good int, p_ng_op int, p_ng_sup int,
  p_defect_op int, p_defect_sup int, p_headcount numeric, p_hours numeric, p_ot numeric, p_downtime int, p_dt_reason text, p_note text)
returns bigint language plpgsql security definer set search_path = public as $$
declare rid bigint; pl int;
begin
  if not public.can_edit_line(p_line, d) then
    raise exception 'Báo cáo Line % ngày % đã khóa (sau 23:59) hoặc bạn không phụ trách line này', p_line, to_char(d,'DD/MM'); end if;
  if not exists(select 1 from products where code = p_product and active) then raise exception 'Mã sản phẩm % không có trong danh mục', p_product; end if;
  if coalesce(p_good,0) < 0 or coalesce(p_ng_op,0) < 0 or coalesce(p_ng_sup,0) < 0 then raise exception 'Số lượng không được âm'; end if;
  if coalesce(p_good,0) + coalesce(p_ng_op,0) + coalesce(p_ng_sup,0) > 0 and coalesce(p_headcount,0) <= 0 then raise exception 'Nhập số người làm'; end if;
  if coalesce(p_hours,0) + coalesce(p_ot,0) > 16 then raise exception 'Tổng giờ hành chính + tăng ca không quá 16'; end if;
  if coalesce(p_ng_op,0) > 0 and p_defect_op is null then raise exception 'Chọn loại lỗi cho NG thao tác'; end if;
  if coalesce(p_ng_sup,0) > 0 and p_defect_sup is null then raise exception 'Chọn loại lỗi cho NG nhà cung cấp'; end if;
  if coalesce(p_downtime,0) > 0 and coalesce(trim(p_dt_reason),'') = '' then raise exception 'Chọn nguyên nhân dừng máy'; end if;
  pl := coalesce(p_plan, (select plan_qty from production_plans where plan_date = d and line_id = p_line and product_code = p_product));
  insert into production_reports(report_date, line_id, product_code, plan_qty, good_qty, ng_op, ng_sup, defect_op, defect_sup,
     headcount, hours, ot_hours, downtime_min, downtime_reason, note, created_by, last_edit_by)
  values (d, p_line, p_product, pl, coalesce(p_good,0), coalesce(p_ng_op,0), coalesce(p_ng_sup,0), p_defect_op, p_defect_sup,
     coalesce(p_headcount,0), coalesce(p_hours,8), coalesce(p_ot,0), coalesce(p_downtime,0), nullif(trim(p_dt_reason),''), p_note, auth.uid(), auth.uid())
  on conflict (report_date, line_id, product_code) do update set plan_qty = excluded.plan_qty, good_qty = excluded.good_qty,
     ng_op = excluded.ng_op, ng_sup = excluded.ng_sup, defect_op = excluded.defect_op, defect_sup = excluded.defect_sup,
     headcount = excluded.headcount, hours = excluded.hours, ot_hours = excluded.ot_hours, downtime_min = excluded.downtime_min,
     downtime_reason = excluded.downtime_reason, note = excluded.note, last_edit_by = auth.uid()
  returning id into rid;
  return rid;
end $$;

create or replace function public.delete_prod_row(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
declare r production_reports;
begin
  select * into r from production_reports where id = p_id;
  if not found then raise exception 'Không tìm thấy dòng'; end if;
  if not public.can_edit_line(r.line_id, r.report_date) then raise exception 'Báo cáo đã khóa hoặc bạn không phụ trách line này'; end if;
  delete from production_reports where id = p_id;
end $$;

-- Tình trạng nhập của 10 line trong ngày d (cho TBP SX, GĐNM, Tổng hợp)
create or replace function public.prod_line_status(d date) returns table(line_id smallint, line_name text, leaders text,
  n_rows int, plan_qty bigint, good_qty bigint, ng_op bigint, ng_sup bigint, man_hours numeric, std_hours numeric, downtime_min bigint,
  missing_norm int, last_edit timestamptz)
language sql stable security definer set search_path = public as $$
  select l.id, l.name,
    (select string_agg(p.full_name, ', ' order by p.full_name) from user_lines ul join profiles p on p.id = ul.profile_id and p.status = 'active' where ul.line_id = l.id),
    count(r.id)::int, sum(r.plan_qty), coalesce(sum(r.good_qty),0), coalesce(sum(r.ng_op),0), coalesce(sum(r.ng_sup),0),
    coalesce(sum(r.headcount * (r.hours + r.ot_hours)),0),
    -- giờ chuẩn = SL đạt ÷ định mức (sp/người/giờ); mã chưa có định mức dùng chuẩn chung trong Cấu hình
    coalesce(sum(r.good_qty / nullif(coalesce(pr.norm_per_hour,
      (select (value->>'stdProd')::numeric from app_settings where key = 'rules'), 32), 0)),0),
    coalesce(sum(r.downtime_min),0), count(r.id) filter (where pr.norm_per_hour is null)::int, max(r.updated_at)
  from production_lines l
  left join production_reports r on r.line_id = l.id and r.report_date = d
  left join products pr on pr.code = r.product_code
  where l.active and (public.is_admin() or public.in_dept(public.dept_id_of('SX')) or public.in_dept(public.dept_id_of('QAC'))
        or public.in_dept(public.dept_id_of('KHSX')) or public.in_dept(public.dept_id_of('KTGT')) or public.in_dept(public.dept_id_of('CD')))
  group by l.id, l.name order by l.id
$$;

-- RLS
drop policy if exists read_all on public.user_lines;
drop policy if exists sx_write on public.user_lines;
create policy read_all on public.user_lines for select to authenticated using (public.is_active_user());
create policy sx_write on public.user_lines for all to authenticated
  using (public.is_admin() or public.is_head_of(public.dept_id_of('SX')))
  with check (public.is_admin() or public.is_head_of(public.dept_id_of('SX')));
-- Báo cáo SX: ghi chỉ qua save_prod_row / delete_prod_row; đọc thêm cho QAC, KHSX, KTGT, Cơ điện (đối chiếu)
drop policy if exists dept_insert on public.production_reports;
drop policy if exists dept_update on public.production_reports;
drop policy if exists cross_read on public.production_reports;
create policy cross_read on public.production_reports for select to authenticated using (
  public.in_dept(public.dept_id_of('QAC')) or public.in_dept(public.dept_id_of('KHSX'))
  or public.in_dept(public.dept_id_of('KTGT')) or public.in_dept(public.dept_id_of('CD')));

revoke execute on function public.my_lines(), public.can_edit_line(int,date), public.save_prod_row(date,int,text,int,int,int,int,int,int,numeric,numeric,numeric,int,text,text),
  public.delete_prod_row(bigint), public.prod_line_status(date) from anon, public;
grant execute on function public.my_lines(), public.can_edit_line(int,date), public.save_prod_row(date,int,text,int,int,int,int,int,int,numeric,numeric,numeric,int,text,text),
  public.delete_prod_row(bigint), public.prod_line_status(date) to authenticated;
