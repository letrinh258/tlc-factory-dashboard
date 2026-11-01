-- =====================================================================
-- TLC FACTORY OPERATION DASHBOARD · Giai đoạn 3
-- Tạo toàn bộ cơ sở dữ liệu, hàm phân quyền, RLS và dữ liệu gốc.
-- Chạy 1 lần trong Supabase → SQL Editor → New query → dán toàn bộ → Run.
-- Chạy lại được: các lệnh dùng IF NOT EXISTS / ON CONFLICT.
-- =====================================================================
set check_function_bodies = off;
create schema if not exists extensions;
create extension if not exists unaccent with schema extensions;

-- ---------------------------------------------------------------------
-- 1. TỔ CHỨC & TÀI KHOẢN
-- ---------------------------------------------------------------------
create table if not exists public.departments(
  id smallint primary key,
  code text unique not null,
  name text not null,
  sort smallint not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.positions(
  id serial primary key,
  code text unique not null,                       -- vd: TBP-KHO, TKTP, NV-QAC
  name text not null,
  dept_id smallint not null references public.departments(id),
  kind text not null check (kind in ('director','head','staff')),
  report_code text unique,                         -- 1 trong 14 mã báo cáo ngày (nếu vị trí này nộp)
  status text not null default 'on' check (status in ('on','leave','vacant')),
  status_from date, status_to date,                -- hiệu lực của tình trạng nghỉ
  acting_profile_id uuid,                          -- người kiêm nhiệm khi vắng
  active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check (status <> 'leave' or (status_from is not null and status_to is not null and status_to >= status_from))
);
create unique index if not exists positions_one_head_per_dept on public.positions(dept_id) where kind = 'head';

create table if not exists public.profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null check (username ~ '^[a-z0-9]+$'),
  full_name text not null,
  dept_id smallint not null references public.departments(id),
  position_id int not null references public.positions(id),
  manager_id uuid references public.profiles(id),
  role text not null default 'staff' check (role in ('admin','head','staff')),
  status text not null default 'active' check (status in ('active','locked')),
  must_change_pw boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid
);
alter table public.positions drop constraint if exists positions_acting_fk;
alter table public.positions add constraint positions_acting_fk foreign key (acting_profile_id) references public.profiles(id) on delete set null;

-- quyền bổ sung ngoài vai trò (vd: cho 1 nhân viên xem module của bộ phận khác)
create table if not exists public.user_roles(
  profile_id uuid references public.profiles(id) on delete cascade,
  module text not null,
  can_view boolean not null default true,
  can_edit boolean not null default false,
  created_at timestamptz not null default now(), created_by uuid,
  primary key(profile_id, module)
);

create table if not exists public.position_history(
  id bigserial primary key,
  position_id int not null references public.positions(id),
  status text not null, status_from date, status_to date,
  acting_profile_id uuid,
  note text,
  changed_by uuid, changed_at timestamptz not null default now()
);

create table if not exists public.app_settings(
  key text primary key,
  value jsonb not null,
  updated_by uuid, updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. DANH MỤC (đồng bộ từ Bravo ở GĐ5)
-- ---------------------------------------------------------------------
create table if not exists public.production_lines(
  id smallint primary key, name text not null, active boolean not null default true,
  updated_at timestamptz not null default now()
);
create table if not exists public.products(
  code text primary key, name text not null,
  family text,                                     -- nhóm sản phẩm (tỷ lệ lỗi bảo hành)
  norm_per_hour numeric,                           -- định mức năng suất sp/người/giờ (Bravo)
  is_semi boolean not null default false,          -- bán thành phẩm LK-/BTP-/PK-
  active boolean not null default true,
  source text not null default 'bravo',
  synced_at timestamptz, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.materials(
  code text primary key, name text not null, uom text,
  min_qty numeric, active boolean not null default true,
  source text not null default 'bravo', synced_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.bom_items(
  product_code text references public.products(code) on delete cascade,
  material_code text not null,
  qty_per_unit numeric not null check (qty_per_unit >= 0),
  primary key(product_code, material_code)
);
create table if not exists public.equipment(
  id serial primary key, code text unique not null, name text not null,
  line_id smallint references public.production_lines(id), active boolean not null default true
);
create table if not exists public.defect_types(
  id smallint primary key, name text not null, stage text not null,
  source text not null check (source in ('op','sup')),   -- op = NG thao tác, sup = NG nhà cung cấp
  component_group text, active boolean not null default true
);

-- ---------------------------------------------------------------------
-- 3. KẾ HOẠCH & ĐƠN HÀNG (KHSX / Bravo)
-- ---------------------------------------------------------------------
create table if not exists public.orders(
  id bigserial primary key, code text unique not null, channel text,
  product_code text references public.products(code), qty int not null check (qty > 0),
  start_date date, due_date date not null, completed_date date,
  status text not null default 'open' check (status in ('open','producing','done','cancelled')),
  source text not null default 'manual',
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), created_by uuid
);
create table if not exists public.production_plans(
  id bigserial primary key, plan_date date not null,
  line_id smallint not null references public.production_lines(id),
  product_code text not null references public.products(code),
  order_id bigint references public.orders(id),
  plan_qty int not null check (plan_qty >= 0),
  source text not null default 'manual',
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), created_by uuid,
  unique(plan_date, line_id, product_code)
);

-- ---------------------------------------------------------------------
-- 4. BÁO CÁO CHUYÊN MÔN (mỗi bảng thuộc 1 bộ phận; trạng thái draft→submitted→confirmed→approved)
-- ---------------------------------------------------------------------
create table if not exists public.production_reports(
  id bigserial primary key, report_date date not null,
  line_id smallint not null references public.production_lines(id),
  product_code text not null references public.products(code),
  plan_qty int, good_qty int not null default 0 check (good_qty >= 0), ng_qty int not null default 0 check (ng_qty >= 0),
  headcount numeric not null default 0, hours numeric not null default 8, ot_hours numeric not null default 0,
  downtime_min int not null default 0, note text,
  status text not null default 'draft' check (status in ('draft','submitted','confirmed','approved')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), created_by uuid default auth.uid(),
  unique(report_date, line_id, product_code)
);
create table if not exists public.quality_reports(
  id bigserial primary key, report_date date not null,
  stage text not null check (stage in ('IQC','PQC','OQC')),
  line_id smallint references public.production_lines(id),
  product_code text references public.products(code), material_code text, supplier text,
  inspected int not null default 0 check (inspected >= 0), rework int not null default 0,
  note text,
  status text not null default 'draft' check (status in ('draft','submitted','confirmed','approved')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), created_by uuid default auth.uid()
);
create table if not exists public.quality_defects(
  id bigserial primary key,
  report_id bigint not null references public.quality_reports(id) on delete cascade,
  defect_type_id smallint not null references public.defect_types(id),
  qty int not null check (qty > 0), cause text, action text
);
create table if not exists public.inventory_reports(
  id bigserial primary key, report_date date not null,
  warehouse text not null check (warehouse in ('LK','TP')),
  status text not null default 'draft' check (status in ('draft','submitted','confirmed','approved')),
  note text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), created_by uuid default auth.uid(),
  unique(report_date, warehouse)
);
create table if not exists public.inventory_report_lines(
  id bigserial primary key,
  report_id bigint not null references public.inventory_reports(id) on delete cascade,
  item_code text not null, kind text not null default 'stock'
    check (kind in ('stock','shortage','ng_return','ng_pending','count_diff','wrong_issue')),
  opening numeric, received numeric, issued numeric, closing numeric,
  ref_qty numeric,                                 -- số tham chiếu từ BP khác (vd SX báo nhập kho)
  diff_reason text, note text
);
create table if not exists public.maintenance_reports(
  id bigserial primary key, report_date date not null,
  line_id smallint references public.production_lines(id), equipment_id int references public.equipment(id),
  kind text not null default 'breakdown' check (kind in ('breakdown','pm','improvement')),
  start_at timestamptz, end_at timestamptz, downtime_min int not null default 0 check (downtime_min >= 0),
  cause text, parts text, action text,
  status text not null default 'draft' check (status in ('draft','submitted','confirmed','approved')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), created_by uuid default auth.uid()
);
create table if not exists public.cost_reports(
  id bigserial primary key, period_start date not null, period_end date not null,
  material_cost numeric, labor_cost numeric, overhead_cost numeric,
  unit_cost_plan numeric, unit_cost_actual numeric, cogs_pct numeric,
  defect_cost numeric, material_variance_pct numeric, note text,
  status text not null default 'draft' check (status in ('draft','submitted','confirmed','approved')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), created_by uuid default auth.uid(),
  check (period_end >= period_start)
);
-- Tỷ lệ lỗi bảo hành: KTGT cập nhật theo nhóm sản phẩm, SL bảo hành / SL bán ra cùng kỳ
create table if not exists public.warranty_rates(
  id bigserial primary key, period_start date not null, period_end date not null,
  family text not null, sold_qty int not null check (sold_qty >= 0), warranty_qty int not null check (warranty_qty >= 0),
  note text,
  status text not null default 'draft' check (status in ('draft','submitted','confirmed','approved')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), created_by uuid default auth.uid(),
  unique(period_start, period_end, family), check (period_end >= period_start)
);
create table if not exists public.warranty_reports(
  id bigserial primary key,
  channel text not null check (channel in ('BHN','BHM')),       -- bảo hành tại nhà / tại nhà máy
  received_date date not null, customer text, product_code text references public.products(code),
  defect text, cause text, qty int not null default 1 check (qty > 0),
  solution text, closed_date date, cost numeric,
  status text not null default 'open' check (status in ('open','processing','closed')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), created_by uuid default auth.uid()
);
create table if not exists public.hr_reports(
  id bigserial primary key, report_date date not null unique,
  total int, present int, absent int, new_hires int, quits int,
  recruiting int, training_done_pct numeric, note text,
  status text not null default 'draft' check (status in ('draft','submitted','confirmed','approved')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), created_by uuid default auth.uid()
);

-- ---------------------------------------------------------------------
-- 5. BÁO CÁO NGÀY 14 VỊ TRÍ
-- ---------------------------------------------------------------------
create table if not exists public.daily_reports(
  id bigserial primary key, report_date date not null,
  profile_id uuid not null references public.profiles(id), position_id int references public.positions(id),
  report_code text,
  status text not null default 'draft' check (status in ('draft','submitted','returned','confirmed','approved')),
  submitted_at timestamptz, confirmed_by uuid, confirmed_at timestamptz, approved_by uuid, approved_at timestamptz,
  next_plan text, note text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(report_date, profile_id)
);
create table if not exists public.daily_report_items(
  id bigserial primary key,
  report_id bigint not null references public.daily_reports(id) on delete cascade,
  section smallint not null check (section between 1 and 5),
  task_id bigint, directive_id bigint,
  content text not null, result text, actual_value numeric, progress numeric check (progress between 0 and 100),
  issue text, cause text, action text, need_help_dept smallint references public.departments(id)
);

-- ---------------------------------------------------------------------
-- 6. VIỆC & CHỈ ĐẠO
-- ---------------------------------------------------------------------
create table if not exists public.management_directives(
  id bigserial primary key, code text unique not null,          -- CĐddmm-NN
  kind text not null default 'directive' check (kind in ('goal','directive','decision','project','commitment','improvement','strategic')),
  content text not null, dept_id smallint references public.departments(id), owner_id uuid references public.profiles(id),
  due_date date, status text not null default 'open' check (status in ('open','done','cancelled')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), created_by uuid default auth.uid()
);
create table if not exists public.tasks(
  id bigserial primary key, code text unique not null,          -- GVddmm-NN
  title text not null, content text, objective text,
  scope text not null default 'person' check (scope in ('factory','dept','person','group')),
  dept_id smallint references public.departments(id),
  assigner_id uuid not null default auth.uid() references public.profiles(id),
  owner_id uuid references public.profiles(id),
  directive_id bigint references public.management_directives(id),
  assigned_date date not null default (now() at time zone 'Asia/Ho_Chi_Minh')::date,
  due_date date not null,
  priority text not null default 'normal' check (priority in ('low','normal','high','urgent')),
  status text not null default 'new' check (status in ('new','accepted','doing','blocked','pending_confirm','done','overdue','paused','cancelled')),
  progress numeric not null default 0 check (progress between 0 and 100),
  result text, late_reason text, recovery_plan text,
  head_confirmed_by uuid, head_confirmed_at timestamptz, approved_by uuid, approved_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.task_assignments(
  task_id bigint references public.tasks(id) on delete cascade,
  profile_id uuid references public.profiles(id),
  primary key(task_id, profile_id)
);
create table if not exists public.task_updates(
  id bigserial primary key, task_id bigint not null references public.tasks(id) on delete cascade,
  profile_id uuid default auth.uid(), at timestamptz not null default now(),
  status_from text, status_to text, progress numeric, note text
);

-- ---------------------------------------------------------------------
-- 7. VẤN ĐỀ, KHẮC PHỤC, 5S
-- ---------------------------------------------------------------------
create table if not exists public.issues(
  id bigserial primary key, code text unique not null,          -- VĐ-ddmm-NN
  open_date date not null default (now() at time zone 'Asia/Ho_Chi_Minh')::date,
  dept_id smallint not null references public.departments(id),
  description text not null,
  severity text not null check (severity in ('red','yellow')),
  initial_cause text, owner_id uuid references public.profiles(id),
  coop_dept_ids smallint[] not null default '{}',
  temp_action text, root_fix text, plan_b text,
  due_date date, verify_result text,
  status text not null default 'open' check (status in ('open','processing','pending_verify','closed')),
  closed_at timestamptz, closed_by uuid,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), created_by uuid default auth.uid(),
  check (severity <> 'red' or plan_b is not null),                -- vấn đề Đỏ bắt buộc có phương án B
  check (status <> 'closed' or verify_result is not null)          -- không đóng khi chưa có kết quả xác nhận
);
create table if not exists public.corrective_actions(
  id bigserial primary key, issue_id bigint not null references public.issues(id) on delete cascade,
  action text not null, owner_id uuid references public.profiles(id), due_date date, done_date date, evidence text,
  created_at timestamptz not null default now(), created_by uuid default auth.uid()
);
create table if not exists public.fives_audits(
  id bigserial primary key, audit_date date not null,
  auditor_id uuid not null default auth.uid() references public.profiles(id),
  target_dept_id smallint not null references public.departments(id),
  area text not null, scores jsonb not null default '{}', total numeric,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.fives_findings(
  id bigserial primary key, audit_id bigint not null references public.fives_audits(id) on delete cascade,
  description text not null, photo_before text,
  countermeasure text, owner_id uuid references public.profiles(id), due_date date, photo_after text,
  status text not null default 'open' check (status in ('open','fixing','pending_verify','closed')),
  updated_at timestamptz not null default now()
);
create table if not exists public.improvement_projects(
  id bigserial primary key, name text not null, dept_id smallint references public.departments(id),
  owner_id uuid references public.profiles(id), start_date date, end_date date, target text, status text default 'open',
  created_at timestamptz not null default now(), created_by uuid default auth.uid()
);

-- ---------------------------------------------------------------------
-- 8. KPI 3 CẤP
-- ---------------------------------------------------------------------
create table if not exists public.kpi_definitions(
  code text primary key, name text not null,
  level text not null check (level in ('factory','dept','position')),
  dept_id smallint references public.departments(id), position_id int references public.positions(id),
  unit text, formula text, source text, frequency text default 'daily',
  direction smallint not null default 1 check (direction in (1,-1)),
  weight numeric default 0, active boolean not null default true,
  updated_at timestamptz not null default now()
);
create table if not exists public.kpi_targets(
  id bigserial primary key, kpi_code text not null references public.kpi_definitions(code),
  period_start date not null, period_end date not null,
  target numeric not null, green_pct numeric not null default 100, yellow_pct numeric not null default 95,
  unique(kpi_code, period_start, period_end)
);
create table if not exists public.kpi_results(
  id bigserial primary key, kpi_code text not null references public.kpi_definitions(code),
  period_start date not null, period_end date not null, dept_id smallint, profile_id uuid,
  value numeric, score numeric, status text check (status in ('green','yellow','red','nodata')),
  computed_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 9. HỆ THỐNG
-- ---------------------------------------------------------------------
create table if not exists public.reconciliations(
  id bigserial primary key, flow smallint not null check (flow between 1 and 6),
  ref_date date not null, ref_key text not null,
  source_qty numeric, target_qty numeric, diff numeric generated always as (coalesce(target_qty,0) - coalesce(source_qty,0)) stored,
  reason text, status text not null default 'open' check (status in ('open','explained','resolved')),
  dept_ids smallint[] not null default '{}',
  created_at timestamptz not null default now(), resolved_by uuid, resolved_at timestamptz,
  unique(flow, ref_date, ref_key)
);
create table if not exists public.notifications(
  id bigserial primary key, profile_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null, title text not null, body text, link text,
  created_at timestamptz not null default now(), read_at timestamptz
);
create table if not exists public.attachments(
  id bigserial primary key, entity text not null, entity_id bigint not null,
  storage_path text not null, file_name text, uploaded_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create table if not exists public.audit_logs(
  id bigserial primary key, at timestamptz not null default now(),
  actor uuid, table_name text not null, row_id text, action text not null,
  old_data jsonb, new_data jsonb
);
create table if not exists public.export_jobs(
  id bigserial primary key, kind text not null, run_at timestamptz not null default now(),
  status text not null, detail text
);
create table if not exists public.bravo_sync_logs(
  id bigserial primary key, entity text not null, started_at timestamptz not null default now(),
  finished_at timestamptz, rows_in int, rows_err int, status text not null, detail text
);

-- =====================================================================
-- HÀM PHÂN QUYỀN (SECURITY DEFINER, đọc bảng không qua RLS để tránh vòng lặp)
-- =====================================================================
drop function if exists public.dept_approver(smallint,date) cascade;
drop function if exists public.is_head_of(smallint) cascade;
drop function if exists public.in_dept(smallint) cascade;
create or replace function public.tlc_today() returns date language sql stable as
$$ select (now() at time zone 'Asia/Ho_Chi_Minh')::date $$;

create or replace function public.is_admin() returns boolean language sql stable security definer set search_path = public as
$$ select exists(select 1 from profiles where id = auth.uid() and role = 'admin' and status = 'active') $$;

create or replace function public.is_active_user() returns boolean language sql stable security definer set search_path = public as
$$ select exists(select 1 from profiles where id = auth.uid() and status = 'active') $$;

create or replace function public.my_dept() returns smallint language sql stable security definer set search_path = public as
$$ select dept_id from profiles where id = auth.uid() and status = 'active' $$;

create or replace function public.dept_id_of(p_code text) returns smallint language sql stable security definer set search_path = public as
$$ select id from departments where code = p_code $$;

-- Vị trí đang vắng hôm nay? (nghỉ tạm trong khoảng từ–đến, hoặc nghỉ việc/chưa tuyển từ ngày hiệu lực)
create or replace function public.position_absent(p public.positions, d date default null) returns boolean language sql stable as
$$ select p.status <> 'on'
      and (p.status_from is null or coalesce(d, public.tlc_today()) >= p.status_from)
      and (p.status <> 'leave' or p.status_to is null or coalesce(d, public.tlc_today()) <= p.status_to) $$;

-- Người đang nắm quyền TBP của bộ phận hôm nay: TBP nếu có mặt → người kiêm nhiệm → NULL (= GĐNM duyệt thẳng)
create or replace function public.dept_approver(p_dept int, d date default null) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare pos positions; who uuid;
begin
  select * into pos from positions where dept_id = p_dept and kind = 'head' and active;
  if not found then return null; end if;
  if not position_absent(pos, d) then
    select id into who from profiles where position_id = pos.id and status = 'active' order by created_at limit 1;
    if who is not null then return who; end if;
  end if;
  if pos.acting_profile_id is not null and exists(select 1 from profiles where id = pos.acting_profile_id and status = 'active') then
    return pos.acting_profile_id;
  end if;
  return null;
end $$;

create or replace function public.is_head_of(p_dept int) returns boolean language sql stable security definer set search_path = public as
$$ select auth.uid() is not null and public.dept_approver(p_dept) = auth.uid() $$;

create or replace function public.in_dept(p_dept int) returns boolean language sql stable security definer set search_path = public as
$$ select public.my_dept() = p_dept $$;

-- Thông tin người đang đăng nhập (dùng cho giao diện)
create or replace function public.me() returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', p.id, 'username', p.username, 'full_name', p.full_name, 'role', p.role, 'status', p.status,
    'must_change_pw', p.must_change_pw, 'dept_id', p.dept_id, 'dept_name', d.name, 'dept_code', d.code,
    'position_id', p.position_id, 'position_name', ps.name, 'position_kind', ps.kind, 'report_code', ps.report_code,
    'approves_depts', (select coalesce(json_agg(x.id), '[]') from departments x where public.dept_approver(x.id) = p.id),
    'today', public.tlc_today())
  from profiles p join departments d on d.id = p.dept_id join positions ps on ps.id = p.position_id
  where p.id = auth.uid()
$$;

-- Bảng tình trạng TBP / người xác nhận theo bộ phận (cho Cấu hình và Dashboard)
create or replace function public.dept_approvers() returns table(dept_id smallint, dept_name text, head_position_id int, head_name text,
  status text, status_from date, status_to date, acting_profile_id uuid, acting_name text, absent_today boolean, approver_id uuid, approver_name text)
language sql stable security definer set search_path = public as $$
  select d.id, d.name, ps.id,
         (select full_name from profiles where position_id = ps.id and status = 'active' order by created_at limit 1),
         ps.status, ps.status_from, ps.status_to, ps.acting_profile_id,
         (select full_name from profiles where id = ps.acting_profile_id),
         public.position_absent(ps), public.dept_approver(d.id),
         (select full_name from profiles where id = public.dept_approver(d.id))
  from departments d join positions ps on ps.dept_id = d.id and ps.kind = 'head'
  where public.is_active_user()
  order by d.sort
$$;

-- Sinh tên đăng nhập: tên + chữ đầu họ và đệm, thường, không dấu. Nguyễn Thị Sáng → sangnt; trùng → sangnt2
create or replace function public.tlc_make_username(p_full_name text) returns text language plpgsql stable security definer set search_path = public as $$
declare parts text[]; base text; cand text; n int := 1; clean text;
begin
  clean := lower(extensions.unaccent(replace(replace(trim(p_full_name), 'Đ', 'D'), 'đ', 'd')));
  clean := regexp_replace(clean, '[^a-z ]', '', 'g');
  parts := regexp_split_to_array(trim(regexp_replace(clean, '\s+', ' ', 'g')), ' ');
  if array_length(parts, 1) is null or parts[1] = '' then raise exception 'Họ tên không hợp lệ'; end if;
  base := parts[array_length(parts, 1)];
  for i in 1 .. array_length(parts, 1) - 1 loop base := base || left(parts[i], 1); end loop;
  cand := base;
  while exists(select 1 from profiles where username = cand) loop n := n + 1; cand := base || n; end loop;
  return cand;
end $$;

-- Đổi tình trạng vị trí (chỉ GĐNM) + ghi lịch sử
create or replace function public.set_position_status(p_position int, p_status text, p_from date, p_to date, p_acting uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Chỉ GĐNM được thay đổi tình trạng vị trí'; end if;
  if p_status not in ('on','leave','vacant') then raise exception 'Tình trạng không hợp lệ'; end if;
  if p_status <> 'on' and p_from is null then raise exception 'Cần nhập Từ ngày'; end if;
  if p_status = 'leave' and (p_to is null or p_to < p_from) then raise exception 'Nghỉ tạm thời cần Đến ngày ≥ Từ ngày'; end if;
  if p_acting is not null and not exists(select 1 from profiles where id = p_acting and status = 'active') then raise exception 'Người kiêm nhiệm không hợp lệ'; end if;
  update positions set status = p_status,
         status_from = case when p_status = 'on' then null else p_from end,
         status_to = case when p_status = 'leave' then p_to else null end,
         acting_profile_id = case when p_status = 'on' then null else p_acting end,
         updated_at = now()
   where id = p_position;
  if not found then raise exception 'Không tìm thấy vị trí'; end if;
  insert into position_history(position_id, status, status_from, status_to, acting_profile_id, note, changed_by)
  values (p_position, p_status, p_from, case when p_status = 'leave' then p_to end, case when p_status = 'on' then null else p_acting end, p_note, auth.uid());
end $$;

-- Người dùng tự xác nhận đã đổi mật khẩu lần đầu
create or replace function public.mark_password_changed() returns void language sql security definer set search_path = public as
$$ update profiles set must_change_pw = false, updated_at = now() where id = auth.uid() $$;

-- Tạo GĐNM đầu tiên (chạy 1 lần trong SQL Editor sau khi tạo user trong Authentication)
create or replace function public.tlc_bootstrap_admin(p_email text, p_full_name text) returns text
language plpgsql security definer set search_path = public as $$
declare uid uuid; uname text;
begin
  if exists(select 1 from profiles where role = 'admin') then raise exception 'Đã có tài khoản GĐNM. Tạo thêm tài khoản trong màn hình Quản lý tài khoản.'; end if;
  select id into uid from auth.users where lower(email) = lower(p_email);
  if uid is null then raise exception 'Chưa có user % trong Authentication → Users', p_email; end if;
  uname := split_part(lower(p_email), '@', 1);
  insert into profiles(id, username, full_name, dept_id, position_id, role, status, must_change_pw)
  values (uid, uname, p_full_name, 1, (select id from positions where code = 'GDNM'), 'admin', 'active', false);
  return 'Đã tạo GĐNM: ' || uname;
end $$;

-- =====================================================================
-- TRIGGER: updated_at + nhật ký thay đổi (audit_logs)
-- =====================================================================
create or replace function public.tg_touch() returns trigger language plpgsql as
$$ begin new.updated_at := now(); return new; end $$;

create or replace function public.tg_audit() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into audit_logs(actor, table_name, row_id, action, old_data, new_data)
  values (auth.uid(), tg_table_name,
          coalesce((case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end)->>'id',
                   (case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end)->>'code',
                   (case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end)->>'key'),
          tg_op, case when tg_op <> 'INSERT' then to_jsonb(old) end, case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

-- Chặn sửa báo cáo đã được GĐNM duyệt (trừ GĐNM)
create or replace function public.tg_lock_approved() returns trigger language plpgsql as $$
begin
  if old.status = 'approved' and not public.is_admin() then raise exception 'Báo cáo đã duyệt, không sửa được'; end if;
  if new.status in ('confirmed') and old.status is distinct from new.status and not (public.is_admin() or public.is_head_of(public.my_dept())) then
    raise exception 'Chỉ TBP/người kiêm nhiệm xác nhận được'; end if;
  if new.status = 'approved' and old.status is distinct from 'approved' and not public.is_admin() then raise exception 'Chỉ GĐNM duyệt được'; end if;
  return new;
end $$;

-- Người dùng không tự đổi vai trò, bộ phận, vị trí, trạng thái của mình
create or replace function public.tg_profile_guard() returns trigger language plpgsql as $$
begin
  if not public.is_admin() and auth.uid() is not null then
    if new.role is distinct from old.role or new.dept_id is distinct from old.dept_id or new.position_id is distinct from old.position_id
       or new.status is distinct from old.status or new.username is distinct from old.username then
      raise exception 'Không có quyền thay đổi thông tin này';
    end if;
  end if;
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['departments','positions','profiles','app_settings','production_lines','products','materials','orders','production_plans',
    'production_reports','quality_reports','inventory_reports','maintenance_reports','cost_reports','warranty_rates','warranty_reports','hr_reports',
    'daily_reports','management_directives','tasks','issues','fives_audits','fives_findings','kpi_definitions'] loop
    if exists(select 1 from information_schema.columns where table_schema='public' and table_name=t and column_name='updated_at') then
      execute format('drop trigger if exists touch on public.%I; create trigger touch before update on public.%I for each row execute function public.tg_touch()', t, t);
    end if;
  end loop;
  foreach t in array array['positions','profiles','app_settings','user_roles','production_reports','quality_reports','inventory_reports','maintenance_reports',
    'cost_reports','warranty_rates','warranty_reports','hr_reports','daily_reports','management_directives','tasks','issues','fives_findings','kpi_targets'] loop
    execute format('drop trigger if exists audit on public.%I; create trigger audit after insert or update or delete on public.%I for each row execute function public.tg_audit()', t, t);
  end loop;
  foreach t in array array['production_reports','quality_reports','inventory_reports','maintenance_reports','cost_reports','warranty_rates','hr_reports'] loop
    execute format('drop trigger if exists lock_approved on public.%I; create trigger lock_approved before update on public.%I for each row execute function public.tg_lock_approved()', t, t);
  end loop;
end $$;
drop trigger if exists profile_guard on public.profiles;
create trigger profile_guard before update on public.profiles for each row execute function public.tg_profile_guard();

-- =====================================================================
-- RLS – BẬT CHO MỌI BẢNG, KHÓA VAI TRÒ anon
-- =====================================================================
do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t.tablename);
    execute format('revoke all on public.%I from anon', t.tablename);
  end loop;
end $$;
revoke execute on all functions in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;

-- Xóa policy cũ (để chạy lại file an toàn)
do $$ declare p record; begin
  for p in select policyname, tablename from pg_policies where schemaname = 'public' loop
    execute format('drop policy %I on public.%I', p.policyname, p.tablename);
  end loop; end $$;

-- 1) Danh mục dùng chung: ai đăng nhập (đang hoạt động) cũng xem; chỉ GĐNM sửa
do $$ declare t text; begin
  foreach t in array array['departments','positions','production_lines','products','materials','bom_items','equipment','defect_types','app_settings','kpi_definitions','kpi_targets'] loop
    execute format('create policy read_all on public.%I for select to authenticated using (public.is_active_user())', t);
    execute format('create policy admin_write on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t);
  end loop; end $$;

-- 2) Hồ sơ người dùng: mọi người xem danh bạ (tên, bộ phận); chỉ GĐNM sửa; tạo/khóa qua Edge Function
create policy read_all on public.profiles for select to authenticated using (public.is_active_user());
create policy admin_write on public.profiles for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy self_read_roles on public.user_roles for select to authenticated using (profile_id = auth.uid() or public.is_admin());
create policy admin_write on public.user_roles for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy admin_read on public.position_history for select to authenticated using (public.is_admin());

-- 3) Báo cáo chuyên môn: thành viên BP sở hữu xem/nhập; người tạo sửa khi chưa xác nhận; TBP/kiêm nhiệm xác nhận; GĐNM xem/duyệt tất cả
do $$ declare r record; begin
  for r in select * from (values
      ('production_reports','SX'),('quality_reports','QAC'),('maintenance_reports','CD'),('cost_reports','KTGT'),
      ('warranty_rates','KTGT'),('hr_reports','HCNS'),('orders','KHSX'),('production_plans','KHSX')) v(tbl, dept) loop
    execute format('create policy dept_read on public.%I for select to authenticated using (public.is_admin() or public.in_dept(public.dept_id_of(%L)) or exists(select 1 from public.user_roles ur where ur.profile_id = auth.uid() and ur.module = %L and ur.can_view))', r.tbl, r.dept, r.tbl);
    execute format('create policy dept_insert on public.%I for insert to authenticated with check (public.is_admin() or public.in_dept(public.dept_id_of(%L)))', r.tbl, r.dept);
    if r.tbl in ('orders','production_plans') then
      execute format('create policy dept_update on public.%I for update to authenticated using (public.is_admin() or public.in_dept(public.dept_id_of(%L))) with check (public.is_admin() or public.in_dept(public.dept_id_of(%L)))', r.tbl, r.dept, r.dept);
    else
      execute format('create policy dept_update on public.%I for update to authenticated using (public.is_admin() or public.is_head_of(public.dept_id_of(%L)) or (created_by = auth.uid() and status in (''draft'',''submitted''))) with check (public.is_admin() or public.in_dept(public.dept_id_of(%L)))', r.tbl, r.dept, r.dept);
    end if;
    execute format('create policy admin_delete on public.%I for delete to authenticated using (public.is_admin())', r.tbl);
  end loop; end $$;

-- Kho: báo cáo + dòng chi tiết
create policy dept_read on public.inventory_reports for select to authenticated using (public.is_admin() or public.in_dept(public.dept_id_of('KHO')));
create policy dept_insert on public.inventory_reports for insert to authenticated with check (public.is_admin() or public.in_dept(public.dept_id_of('KHO')));
create policy dept_update on public.inventory_reports for update to authenticated
  using (public.is_admin() or public.is_head_of(public.dept_id_of('KHO')) or (created_by = auth.uid() and status in ('draft','submitted')))
  with check (public.is_admin() or public.in_dept(public.dept_id_of('KHO')));
create policy lines_all on public.inventory_report_lines for all to authenticated
  using (exists(select 1 from public.inventory_reports r where r.id = report_id))
  with check (exists(select 1 from public.inventory_reports r where r.id = report_id and r.status in ('draft','submitted') and (public.in_dept(public.dept_id_of('KHO')) or public.is_admin())));
create policy defects_all on public.quality_defects for all to authenticated
  using (exists(select 1 from public.quality_reports r where r.id = report_id))
  with check (exists(select 1 from public.quality_reports r where r.id = report_id and r.status in ('draft','submitted') and (public.in_dept(public.dept_id_of('QAC')) or public.is_admin())));

-- Bảo hành: 2 bộ phận BHN, BHM
create policy dept_read on public.warranty_reports for select to authenticated
  using (public.is_admin() or public.in_dept(public.dept_id_of(channel)) or public.in_dept(public.dept_id_of('QAC')) or public.in_dept(public.dept_id_of('KT')));
create policy dept_insert on public.warranty_reports for insert to authenticated with check (public.is_admin() or public.in_dept(public.dept_id_of(channel)));
create policy dept_update on public.warranty_reports for update to authenticated
  using (public.is_admin() or public.in_dept(public.dept_id_of(channel))) with check (public.is_admin() or public.in_dept(public.dept_id_of(channel)));

-- 4) Báo cáo ngày: chủ báo cáo, TBP/kiêm nhiệm của BP người nộp, GĐNM
create policy own_or_head_read on public.daily_reports for select to authenticated
  using (profile_id = auth.uid() or public.is_admin() or public.is_head_of((select dept_id from public.profiles x where x.id = profile_id)));
create policy own_insert on public.daily_reports for insert to authenticated with check (profile_id = auth.uid() and public.is_active_user());
create policy own_or_head_update on public.daily_reports for update to authenticated
  using ((profile_id = auth.uid() and status in ('draft','returned','submitted')) or public.is_admin()
         or public.is_head_of((select dept_id from public.profiles x where x.id = profile_id)))
  with check (profile_id = auth.uid() or public.is_admin() or public.is_head_of((select dept_id from public.profiles x where x.id = profile_id)));
create policy items_all on public.daily_report_items for all to authenticated
  using (exists(select 1 from public.daily_reports r where r.id = report_id))
  with check (exists(select 1 from public.daily_reports r where r.id = report_id and r.profile_id = auth.uid() and r.status in ('draft','returned')));

-- 5) Việc: người giao, người phụ trách, người phối hợp, TBP của BP, GĐNM
create or replace function public.can_see_task(t public.tasks) returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or t.assigner_id = auth.uid() or t.owner_id = auth.uid()
      or exists(select 1 from task_assignments a where a.task_id = t.id and a.profile_id = auth.uid())
      or (t.dept_id is not null and public.is_head_of(t.dept_id))
      or (t.scope = 'factory' and public.is_active_user())
$$;
create policy task_read on public.tasks for select to authenticated using (public.can_see_task(tasks));
create policy task_insert on public.tasks for insert to authenticated
  with check (public.is_admin() or (dept_id is not null and public.is_head_of(dept_id) and assigner_id = auth.uid()));
create policy task_update on public.tasks for update to authenticated
  using (public.is_admin() or owner_id = auth.uid() or (dept_id is not null and public.is_head_of(dept_id)))
  with check (public.is_admin() or owner_id = auth.uid() or (dept_id is not null and public.is_head_of(dept_id)));
create policy assign_read on public.task_assignments for select to authenticated
  using (exists(select 1 from public.tasks t where t.id = task_id));
create policy assign_write on public.task_assignments for all to authenticated
  using (public.is_admin() or exists(select 1 from public.tasks t where t.id = task_id and t.dept_id is not null and public.is_head_of(t.dept_id)))
  with check (public.is_admin() or exists(select 1 from public.tasks t where t.id = task_id and t.dept_id is not null and public.is_head_of(t.dept_id)));
create policy upd_read on public.task_updates for select to authenticated using (exists(select 1 from public.tasks t where t.id = task_id));
create policy upd_insert on public.task_updates for insert to authenticated
  with check (profile_id = auth.uid() and exists(select 1 from public.tasks t where t.id = task_id));
-- task_updates: không có policy UPDATE/DELETE → lịch sử không sửa, không xóa được

create policy dir_read on public.management_directives for select to authenticated
  using (public.is_admin() or owner_id = auth.uid() or (dept_id is not null and public.is_head_of(dept_id)));
create policy dir_write on public.management_directives for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- 6) Vấn đề: ai cũng tạo được; xem: người tạo, người xử lý, BP phát sinh, BP phối hợp, GĐNM
create policy issue_read on public.issues for select to authenticated
  using (public.is_admin() or created_by = auth.uid() or owner_id = auth.uid() or public.in_dept(dept_id) or public.my_dept() = any(coop_dept_ids));
create policy issue_insert on public.issues for insert to authenticated with check (public.is_active_user() and created_by = auth.uid());
create policy issue_update on public.issues for update to authenticated
  using (public.is_admin() or owner_id = auth.uid() or public.is_head_of(dept_id) or created_by = auth.uid())
  with check (public.is_admin() or owner_id = auth.uid() or public.is_head_of(dept_id) or created_by = auth.uid());
create policy ca_all on public.corrective_actions for all to authenticated
  using (exists(select 1 from public.issues i where i.id = issue_id))
  with check (exists(select 1 from public.issues i where i.id = issue_id));

-- 7) 5S: người chấm nhập; BP nhận xem và nhập đối sách
create policy audit_read on public.fives_audits for select to authenticated
  using (public.is_admin() or auditor_id = auth.uid() or public.in_dept(target_dept_id));
create policy audit_insert on public.fives_audits for insert to authenticated with check (auditor_id = auth.uid() and public.is_active_user());
create policy audit_update on public.fives_audits for update to authenticated using (auditor_id = auth.uid() or public.is_admin());
create policy finding_read on public.fives_findings for select to authenticated using (exists(select 1 from public.fives_audits a where a.id = audit_id));
create policy finding_write on public.fives_findings for all to authenticated
  using (exists(select 1 from public.fives_audits a where a.id = audit_id and (a.auditor_id = auth.uid() or public.in_dept(a.target_dept_id) or public.is_admin())))
  with check (exists(select 1 from public.fives_audits a where a.id = audit_id and (a.auditor_id = auth.uid() or public.in_dept(a.target_dept_id) or public.is_admin())));
create policy proj_read on public.improvement_projects for select to authenticated using (public.is_active_user());
create policy proj_write on public.improvement_projects for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- 8) KPI kết quả: GĐNM tất cả; BP xem KPI BP mình; cá nhân xem KPI của mình
create policy kpi_read on public.kpi_results for select to authenticated
  using (public.is_admin() or profile_id = auth.uid() or (dept_id is not null and public.in_dept(dept_id)) or (dept_id is null and profile_id is null and public.is_active_user()));
create policy kpi_write on public.kpi_results for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- 9) Hệ thống
create policy recon_read on public.reconciliations for select to authenticated using (public.is_admin() or public.my_dept() = any(dept_ids));
create policy recon_update on public.reconciliations for update to authenticated using (public.is_admin() or public.my_dept() = any(dept_ids));
create policy notif_own on public.notifications for select to authenticated using (profile_id = auth.uid());
create policy notif_mark on public.notifications for update to authenticated using (profile_id = auth.uid()) with check (profile_id = auth.uid());
create policy att_read on public.attachments for select to authenticated using (public.is_active_user());
create policy att_insert on public.attachments for insert to authenticated with check (uploaded_by = auth.uid() and public.is_active_user());
create policy audit_admin on public.audit_logs for select to authenticated using (public.is_admin());
create policy export_admin on public.export_jobs for select to authenticated using (public.is_admin());
create policy bravo_admin on public.bravo_sync_logs for select to authenticated using (public.is_admin());
-- audit_logs / export_jobs / bravo_sync_logs: không có policy ghi → chỉ trigger hoặc server ghi được

-- Hàm chỉ cho người đã đăng nhập gọi
grant execute on function public.me(), public.dept_approvers(), public.set_position_status(int,text,date,date,uuid,text),
  public.mark_password_changed(), public.is_admin(), public.is_head_of(int), public.in_dept(int),
  public.my_dept(), public.dept_id_of(text), public.dept_approver(int,date), public.is_active_user(), public.tlc_today(),
  public.position_absent(public.positions,date), public.can_see_task(public.tasks) to authenticated;
revoke execute on function public.tlc_bootstrap_admin(text,text) from authenticated, anon, public;
revoke execute on function public.tlc_make_username(text) from authenticated, anon, public;
grant execute on function public.tlc_make_username(text) to service_role;

-- =====================================================================
-- DỮ LIỆU GỐC
-- =====================================================================
insert into public.departments(id, code, name, sort) values
 (1,'BGD','Ban giám đốc',1),(2,'QAC','Phòng QAC',2),(3,'SX','Phòng Sản xuất',3),(4,'KHSX','Phòng KHSX',4),(5,'KHO','Kho',5),
 (6,'KT','Phòng Kỹ thuật',6),(7,'CD','Phòng Cơ điện',7),(8,'KTGT','Kế toán giá thành',8),(9,'BHM','Bảo hành nhà máy',9),
 (10,'BHN','Bảo hành tại nhà',10),(11,'HCNS','HCNS',11)
on conflict (id) do update set code = excluded.code, name = excluded.name, sort = excluded.sort;

insert into public.positions(code, name, dept_id, kind, report_code) values
 ('GDNM','Giám đốc nhà máy',1,'director',null),
 ('TBP-QAC','Trưởng phòng QAC',2,'head','QAC'),
 ('TBP-SX','Trưởng phòng Sản xuất',3,'head','SX'),
 ('TBP-KHSX','Trưởng phòng KHSX',4,'head','KHSX'),
 ('TBP-KHO','Trưởng kho',5,'head',null),
 ('TBP-KT','Trưởng phòng Kỹ thuật',6,'head',null),
 ('TBP-CD','Trưởng phòng Cơ điện',7,'head','CĐ'),
 ('TBP-KTGT','Trưởng KT giá thành',8,'head','KTGT'),
 ('TBP-BHM','Trưởng BH nhà máy',9,'head','BHM'),
 ('TBP-BHN','Trưởng BH tại nhà',10,'head','BHN'),
 ('TBP-HCNS','Trưởng phòng HCNS',11,'head','HCNS'),
 ('TKLK','Thủ kho linh kiện',5,'staff','TKLK'),
 ('KTKLK','Kế toán kho linh kiện',5,'staff','KTKLK'),
 ('TKTP','Thủ kho thành phẩm',5,'staff','TKTP'),
 ('KTKTP','Kế toán kho thành phẩm',5,'staff','KTKTP'),
 ('KTSX','Kỹ thuật sản xuất',6,'staff','KTSX'),
 ('KTSP','Kỹ thuật sản phẩm',6,'staff','KTSP'),
 ('NV-QAC','Nhân viên QAC',2,'staff',null),
 ('TT-SX','Tổ trưởng sản xuất',3,'staff',null),
 ('NV-KHSX','Nhân viên KHSX',4,'staff',null),
 ('NV-CD','Nhân viên cơ điện',7,'staff',null),
 ('NV-KTGT','Nhân viên KT giá thành',8,'staff',null),
 ('NV-BHM','Nhân viên BH nhà máy',9,'staff',null),
 ('KTV-BHN','Kỹ thuật viên BH tại nhà',10,'staff',null),
 ('NV-HCNS','Nhân viên HCNS',11,'staff',null),
 ('NV-BGD','Trợ lý GĐNM',1,'staff',null)
on conflict (code) do update set name = excluded.name, dept_id = excluded.dept_id, kind = excluded.kind, report_code = excluded.report_code;

insert into public.production_lines(id, name) select g, 'Line ' || g from generate_series(1,10) g on conflict (id) do nothing;

insert into public.defect_types(id, name, stage, source, component_group) values
 (1,'Hàn chân LED / dây','SMT/Hàn','op',null),(2,'Lắp sai, thiếu linh kiện','Lắp ráp','op',null),(3,'Trầy xước, va đập','Đóng gói','op',null),
 (4,'Nguồn (driver) lỗi','Test điện','sup','Nguồn'),(5,'Mắt LED / bản mạch lỗi','Test quang','sup','Mắt LED, bản mạch'),(6,'Vỏ, mặt, phụ kiện lỗi','Lắp ráp','sup','Vỏ, mặt, phụ kiện')
on conflict (id) do nothing;

insert into public.app_settings(key, value) values
 ('thresholds', '{"out":{"tgt":100,"g":100,"y":95},"def":{"tgt":0.8,"g":100,"y":80},"defOp":{"tgt":0.5,"g":100,"y":80},"defSup":{"tgt":0.3,"g":100,"y":80},
   "prod":{"tgt":100,"g":100,"y":95},"otd":{"tgt":95,"g":100,"y":95},"inv":{"tgt":16,"g":100,"y":90},"cogs":{"tgt":55,"g":100,"y":95},
   "dt":{"tgt":60,"g":100,"y":70},"fpy":{"tgt":98,"g":100,"y":98},"hr":{"tgt":100,"g":100,"y":95},"war":{"tgt":3,"g":100,"y":70},"warRate":{"tgt":1.0,"g":100,"y":80}}'),
 ('rules', '{"cutoff":"17:30","stdProd":32,"ngDiffPct":5,"ngDiffQty":10,"dtDiffMin":15,"warrantyCycle":"month","driveExport":"20:00"}')
on conflict (key) do nothing;

-- Kết thúc. Kiểm tra: select count(*) from pg_policies where schemaname='public';
