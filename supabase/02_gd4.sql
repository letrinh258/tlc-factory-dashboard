-- =====================================================================
-- TLC FACTORY OPERATION DASHBOARD · Giai đoạn 4
-- Giao việc + Báo cáo ngày 14 vị trí (5 mục theo form BCN), ảnh minh chứng, khóa sau 23:59
-- Chạy SAU file 01. Chạy lại được.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Bổ sung cột cho bảng có sẵn
-- ---------------------------------------------------------------------
-- Báo cáo ngày: 1 báo cáo / vị trí / ngày; không có bước nộp – nhập tới đâu tổng hợp tới đó
alter table public.daily_reports add column if not exists metrics jsonb not null default '{}';
alter table public.daily_reports add column if not exists last_edit_at timestamptz;
alter table public.daily_reports add column if not exists last_edit_by uuid;
alter table public.daily_reports alter column profile_id drop not null;
alter table public.daily_reports drop constraint if exists daily_reports_report_date_profile_id_key;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'daily_reports_date_code_key') then
    alter table public.daily_reports add constraint daily_reports_date_code_key unique (report_date, report_code);
  end if; end $$;

-- Việc / chỉ đạo
alter table public.tasks add column if not exists kind text not null default 'GV';         -- CĐ = chỉ đạo, GV = việc giao thêm
alter table public.tasks add column if not exists source text not null default 'Việc giao thêm';
alter table public.tasks add column if not exists report_code text;                         -- vị trí nhận (1 trong 14 mã)
alter table public.tasks add column if not exists original_due date;
alter table public.tasks add column if not exists requested_due date;                       -- hạn mới người phụ trách xin
alter table public.tasks add column if not exists requested_reason text;
alter table public.tasks add column if not exists done_date date;
alter table public.tasks add column if not exists close_note text;
alter table public.tasks drop constraint if exists tasks_kind_check;
alter table public.tasks add constraint tasks_kind_check check (kind in ('CĐ','GV'));

-- Vấn đề (mục 2): theo đúng cột form BCN
alter table public.issues add column if not exists report_code text;
alter table public.issues add column if not exists impact text;
alter table public.issues add column if not exists cross_dept boolean not null default false;
alter table public.issues add column if not exists owner_name text;
alter table public.issues add column if not exists result_target text;
alter table public.issues alter column dept_id drop not null;
alter table public.issues drop constraint if exists issues_severity_check;
alter table public.issues add constraint issues_severity_check check (severity in ('red','yellow','green'));
alter table public.issues drop constraint if exists issues_status_check;
alter table public.issues add constraint issues_status_check check (status in ('open','processing','waiting','resolved','pending_verify','closed'));

-- ---------------------------------------------------------------------
-- 2. Bảng mới
-- ---------------------------------------------------------------------
-- Mục 4 – Kế hoạch ngày mai (chưa xong tự hiện ở mục 3 các ngày sau)
create table if not exists public.plan_items(
  id bigserial primary key, code text unique not null,                 -- [mã vị trí]-yymmdd-Knn
  report_code text not null, report_date date not null, plan_date date not null,
  slot text, content text not null, target_qty numeric, uom text,
  priority text check (priority in ('1-Cao','2-Trung bình','3-Thấp')),
  dep_dept text, owner_name text, due_date date,
  ready text check (ready in ('Đủ','Thiếu')), missing text, result_target text, risk text,
  status text not null default 'doing' check (status in ('doing','waiting','pending_confirm','closed')),
  done_date date,
  created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
-- Mục 5 – Nội dung cần hỗ trợ / ra quyết định
create table if not exists public.support_requests(
  id bigserial primary key, report_code text not null, report_date date not null,
  kind text not null check (kind in ('Hỗ trợ','Quyết định')),
  content text not null, urgency text, need_who text, respond_by date, dept text, proposer text,
  proposal text,                                                          -- phương án đề xuất & ảnh hưởng nếu không xử lý
  status text not null default 'Chờ phản hồi' check (status in ('Chờ phản hồi','Đã quyết định','Đã hỗ trợ','Đã đóng')),
  decision text, decider text, decided_date date, decided_by uuid,
  created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
-- Mục 3 – Cập nhật tiến độ mỗi ngày cho từng việc / vấn đề / kế hoạch đang mở
create table if not exists public.item_updates(
  id bigserial primary key,
  entity text not null check (entity in ('task','issue','plan')), entity_id bigint not null,
  report_code text, update_date date not null,
  progress numeric check (progress between 0 and 100),
  note text,                       -- tiến độ xử lý đến hôm nay (đã làm gì – kết quả)
  new_due date, next_action text,  -- hạn mới (nếu lùi) · lý do chưa xong & hành động tiếp theo
  status text, done_date date,
  profile_id uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(entity, entity_id, update_date)
);
-- Mở khóa báo cáo đã qua 23:59 (chỉ GĐNM), có hạn
create table if not exists public.report_unlocks(
  id bigserial primary key, report_code text not null, report_date date not null,
  until_at timestamptz not null, reason text, unlocked_by uuid default auth.uid(), created_at timestamptz not null default now()
);
-- Bộ đếm mã: GV0111-01, CĐ0111-01, KHSX-261101-01…
create table if not exists public.code_counters(prefix text primary key, n int not null default 0);
-- Chỉ số mục 1 theo vị trí (GĐNM sửa được)
insert into public.app_settings(key, value) values ('report_metrics', '{}') on conflict (key) do nothing;
insert into public.app_settings(key, value) values ('holidays', '[]') on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- 3. Hàm nghiệp vụ
-- ---------------------------------------------------------------------
create or replace function public.next_code(p_prefix text) returns text language plpgsql security definer set search_path = public as $$
declare v int;
begin
  if not public.is_active_user() then raise exception 'Chưa đăng nhập'; end if;
  insert into code_counters(prefix, n) values (p_prefix, 1)
    on conflict (prefix) do update set n = code_counters.n + 1 returning n into v;
  return p_prefix || lpad(v::text, 2, '0');
end $$;

-- Các mã báo cáo người đang đăng nhập được nhập: vị trí mình giữ + vị trí TBP mình đang kiêm nhiệm hôm nay
create or replace function public.my_report_codes() returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct c), '{}') from (
    select ps.report_code c from profiles p join positions ps on ps.id = p.position_id
      where p.id = auth.uid() and p.status = 'active' and ps.report_code is not null
        and not (ps.kind = 'head' and public.position_absent(ps))      -- TBP đang vắng thì quyền nhập chuyển cho người kiêm nhiệm
    union
    select ps.report_code from positions ps
      where ps.kind = 'head' and ps.report_code is not null and ps.acting_profile_id = auth.uid()
        and public.position_absent(ps)
  ) x
$$;
create or replace function public.dept_of_code(p_code text) returns int language sql stable security definer set search_path = public as
$$ select dept_id::int from positions where report_code = p_code limit 1 $$;

-- Ai được XEM báo cáo của 1 vị trí: GĐNM, người nhập vị trí đó, TBP/kiêm nhiệm của bộ phận đó
create or replace function public.can_read_code(p_code text) returns boolean language sql stable security definer set search_path = public as
$$ select public.is_admin() or p_code = any(public.my_report_codes()) or public.is_head_of(public.dept_of_code(p_code)) $$;

-- Ai được SỬA báo cáo ngày d của vị trí: người nhập vị trí đó, khi d là hôm nay hoặc đang được mở khóa
create or replace function public.can_edit_code(p_code text, d date) returns boolean language sql stable security definer set search_path = public as $$
  select public.is_active_user() and (p_code = any(public.my_report_codes()) or public.is_admin())
     and (d = public.tlc_today()
          or exists(select 1 from report_unlocks u where u.report_code = p_code and u.report_date = d and u.until_at > now()))
$$;

-- GĐNM mở khóa báo cáo ngày cũ trong N giờ
create or replace function public.unlock_report(p_code text, p_date date, p_hours int, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Chỉ GĐNM được mở khóa báo cáo'; end if;
  if p_reason is null or length(trim(p_reason)) < 3 then raise exception 'Ghi lý do mở khóa'; end if;
  insert into report_unlocks(report_code, report_date, until_at, reason) values (p_code, p_date, now() + make_interval(hours => greatest(1, least(p_hours, 48))), p_reason);
end $$;

-- Ghi nhận báo cáo ngày có nhập (tạo dòng nếu chưa có) – gọi mỗi khi người dùng lưu bất cứ mục nào
create or replace function public.touch_report(p_code text, p_date date) returns bigint language plpgsql security definer set search_path = public as $$
declare rid bigint;
begin
  if not public.can_edit_code(p_code, p_date) then raise exception 'Báo cáo ngày % của % đã khóa hoặc bạn không có quyền', to_char(p_date,'DD/MM'), p_code; end if;
  insert into daily_reports(report_date, report_code, profile_id, position_id, status, last_edit_at, last_edit_by)
  values (p_date, p_code, auth.uid(), (select id from positions where report_code = p_code limit 1), 'draft', now(), auth.uid())
  on conflict (report_date, report_code) do update set last_edit_at = now(), last_edit_by = auth.uid()
  returning id into rid;
  return rid;
end $$;

-- Mục 3 của báo cáo ngày d: mọi việc / vấn đề / kế hoạch đang mở của vị trí, kèm cập nhật hôm đó
create or replace function public.report_section3(p_code text, d date) returns table(
  entity text, id bigint, code text, content text, source text, giver text, start_date date, days_open int,
  owner text, due_original date, due_effective date, requested_due date, result_target text, status text, overdue boolean,
  u_progress numeric, u_note text, u_new_due date, u_next text, u_status text, u_done date, photos int)
language sql stable security definer set search_path = public as $$
  with t as (
    select 'task'::text entity, k.id, k.code, coalesce(k.content, k.title) content, k.source,
           (select full_name from profiles where id = k.assigner_id) giver, k.assigned_date start_date,
           (select full_name from profiles where id = k.owner_id) owner_name,
           coalesce(k.original_due, k.due_date) due_original, k.due_date due_eff, k.requested_due, k.objective result_target,
           k.status, k.done_date
    from tasks k where k.report_code = p_code and k.assigned_date <= d
      and (k.status not in ('done','cancelled') or k.done_date >= d)
    union all
    select 'issue', i.id, i.code, i.description, 'Chuyển từ mục 2', null, i.open_date, i.owner_name,
           i.due_date, i.due_date, null, i.result_target, i.status, null
    from issues i where i.report_code = p_code and i.open_date < d and (i.status <> 'closed' or i.closed_at::date >= d)
    union all
    select 'plan', p.id, p.code, p.content, 'Chuyển từ mục 4', null, p.report_date, p.owner_name,
           p.due_date, p.due_date, null, p.result_target, p.status, p.done_date
    from plan_items p where p.report_code = p_code and p.report_date < d and p.plan_date <= d and (p.status <> 'closed' or p.done_date >= d)
  )
  select t.entity, t.id, t.code, t.content, t.source, t.giver, t.start_date, (d - t.start_date)::int, t.owner_name,
         t.due_original, coalesce(u.new_due, t.due_eff), t.requested_due, t.result_target, t.status,
         (t.status not in ('done','closed','cancelled') and coalesce(u.new_due, t.due_eff) is not null and d > coalesce(u.new_due, t.due_eff)),
         coalesce(u.progress, (select progress from item_updates x where x.entity = t.entity and x.entity_id = t.id and x.update_date < d order by update_date desc limit 1)),
         u.note, u.new_due, u.next_action, u.status, u.done_date,
         (select count(*)::int from attachments a where a.entity = t.entity and a.entity_id = t.id)
  from t left join item_updates u on u.entity = t.entity and u.entity_id = t.id and u.update_date = d
  where public.can_read_code(p_code)
  order by 15 desc, t.start_date, t.code
$$;

-- Cập nhật mục 3 (upsert theo ngày). Việc của GĐNM: người phụ trách chỉ được "Đề nghị đóng", xin lùi hạn chờ duyệt.
create or replace function public.save_update(p_entity text, p_id bigint, p_code text, d date, p_progress numeric, p_note text,
  p_new_due date, p_next text, p_status text, p_done date) returns void language plpgsql security definer set search_path = public as $$
declare cur_due date; st text;
begin
  if not public.can_edit_code(p_code, d) then raise exception 'Báo cáo ngày % đã khóa (sau 23:59) hoặc bạn không có quyền', to_char(d,'DD/MM'); end if;
  if p_progress is not null and (p_progress < 0 or p_progress > 100) then raise exception '%% tiến độ phải từ 0 đến 100'; end if;
  if p_entity = 'task' then
    select due_date into cur_due from tasks where id = p_id and report_code = p_code;
    if not found then raise exception 'Không tìm thấy việc'; end if;
    -- quá hạn: bắt buộc lý do + hạn mới + hành động
    if cur_due < d and coalesce(p_status,'') not in ('pending_confirm') and (p_new_due is null or coalesce(trim(p_next),'') = '') then
      raise exception 'Việc đã quá hạn: bắt buộc ghi Hạn mới và Lý do / hành động tiếp theo';
    end if;
    st := case when p_status in ('doing','blocked','pending_confirm') then p_status else 'doing' end;
    update tasks set progress = coalesce(p_progress, progress), status = st,
      requested_due = case when p_new_due is not null and p_new_due <> due_date then p_new_due else requested_due end,
      requested_reason = case when p_new_due is not null and p_new_due <> due_date then p_next else requested_reason end,
      result = coalesce(nullif(trim(p_note),''), result), updated_at = now()
    where id = p_id;
  elsif p_entity = 'issue' then
    update issues set status = case when p_status in ('open','processing','waiting','resolved') then p_status else status end,
      due_date = coalesce(p_new_due, due_date), updated_at = now() where id = p_id and report_code = p_code;
    if not found then raise exception 'Không tìm thấy vấn đề'; end if;
  elsif p_entity = 'plan' then
    update plan_items set status = case when p_status in ('doing','waiting','pending_confirm') then p_status else status end,
      due_date = coalesce(p_new_due, due_date), done_date = p_done, updated_at = now() where id = p_id and report_code = p_code;
    if not found then raise exception 'Không tìm thấy kế hoạch'; end if;
  else raise exception 'Loại không hợp lệ'; end if;
  insert into item_updates(entity, entity_id, report_code, update_date, progress, note, new_due, next_action, status, done_date, profile_id)
  values (p_entity, p_id, p_code, d, p_progress, p_note, p_new_due, p_next, p_status, p_done, auth.uid())
  on conflict (entity, entity_id, update_date) do update set progress = excluded.progress, note = excluded.note, new_due = excluded.new_due,
    next_action = excluded.next_action, status = excluded.status, done_date = excluded.done_date, profile_id = auth.uid(), updated_at = now();
  perform public.touch_report(p_code, d);
end $$;

-- GĐNM / người giao: đóng việc, trả lại, duyệt hạn mới
create or replace function public.task_decide(p_id bigint, p_action text, p_note text) returns void language plpgsql security definer set search_path = public as $$
declare t tasks;
begin
  select * into t from tasks where id = p_id;
  if not found then raise exception 'Không tìm thấy việc'; end if;
  if not (public.is_admin() or t.assigner_id = auth.uid() or (t.dept_id is not null and public.is_head_of(t.dept_id) and t.assigner_id = auth.uid())) then
    raise exception 'Chỉ người giao việc hoặc GĐNM được quyết định';
  end if;
  if p_action = 'close' then
    if coalesce(trim(p_note),'') = '' then raise exception 'Ghi kết quả xác nhận khi đóng việc'; end if;
    update tasks set status = 'done', done_date = public.tlc_today(), close_note = p_note, approved_by = auth.uid(), approved_at = now(), progress = 100 where id = p_id;
  elsif p_action = 'reopen' then
    update tasks set status = 'doing', close_note = p_note where id = p_id;
  elsif p_action = 'approve_due' then
    if t.requested_due is null then raise exception 'Không có hạn mới chờ duyệt'; end if;
    update tasks set original_due = coalesce(original_due, due_date), due_date = requested_due, requested_due = null, requested_reason = null where id = p_id;
  elsif p_action = 'reject_due' then
    update tasks set requested_due = null, requested_reason = null where id = p_id;
  elsif p_action = 'cancel' then
    update tasks set status = 'cancelled', close_note = p_note where id = p_id;
  else raise exception 'Thao tác không hợp lệ'; end if;
  insert into task_updates(task_id, profile_id, status_from, status_to, note) values (p_id, auth.uid(), t.status, p_action, p_note);
end $$;

-- GĐNM đóng vấn đề / kế hoạch (người báo cáo chỉ đến "Đã xử lý" / "Đề nghị đóng")
create or replace function public.close_item(p_entity text, p_id bigint, p_note text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Chỉ GĐNM / Cố vấn được đóng'; end if;
  if coalesce(trim(p_note),'') = '' then raise exception 'Ghi kết quả xác nhận khi đóng'; end if;
  if p_entity = 'issue' then update issues set status = 'closed', verify_result = p_note, closed_at = now(), closed_by = auth.uid() where id = p_id;
  elsif p_entity = 'plan' then update plan_items set status = 'closed', done_date = coalesce(done_date, public.tlc_today()) where id = p_id;
  else raise exception 'Loại không hợp lệ'; end if;
end $$;

-- Tổng hợp ngày cho GĐNM: tình trạng nhập của 14 vị trí + số đếm
create or replace function public.daily_summary(d date) returns table(report_code text, position_name text, dept_name text, entered boolean, last_edit_at timestamptz,
  editor text, red_open int, yellow_open int, overdue int, waiting_decision int, day_closed boolean)
language sql stable security definer set search_path = public as $$
  select ps.report_code, ps.name, dp.name, r.id is not null, r.last_edit_at,
    (select full_name from profiles where id = r.last_edit_by),
    (select count(*)::int from issues i where i.report_code = ps.report_code and i.severity = 'red' and i.status not in ('resolved','closed') and i.open_date <= d),
    (select count(*)::int from issues i where i.report_code = ps.report_code and i.severity = 'yellow' and i.status not in ('resolved','closed') and i.open_date <= d),
    (select count(*)::int from report_section3(ps.report_code, d) s where s.overdue),
    (select count(*)::int from support_requests s where s.report_code = ps.report_code and s.status = 'Chờ phản hồi' and s.report_date <= d),
    d < public.tlc_today()
  from positions ps join departments dp on dp.id = ps.dept_id
  left join daily_reports r on r.report_code = ps.report_code and r.report_date = d
  where ps.report_code is not null and public.can_read_code(ps.report_code)
  order by dp.sort, ps.id
$$;

-- Thông báo trong ứng dụng (tính tại chỗ, không cần bảng)
create or replace function public.my_alerts() returns table(kind text, title text, detail text, ref text) language sql stable security definer set search_path = public as $$
  select 'task_new', 'Việc mới được giao: ' || code, title, code from tasks
    where report_code = any(public.my_report_codes()) and status = 'new'
  union all
  select 'task_due', 'Sắp đến hạn (' || to_char(due_date,'DD/MM') || '): ' || code, title, code from tasks
    where report_code = any(public.my_report_codes()) and status not in ('done','cancelled') and due_date = public.tlc_today() + 1
  union all
  select 'task_over', 'QUÁ HẠN: ' || code, title, code from tasks
    where report_code = any(public.my_report_codes()) and status not in ('done','cancelled') and due_date < public.tlc_today()
  union all
  select 'decided', 'Đã có quyết định: ' || left(content, 60), coalesce(decision,''), id::text from support_requests
    where report_code = any(public.my_report_codes()) and status in ('Đã quyết định','Đã hỗ trợ') and decided_date >= public.tlc_today() - 1
  union all
  select 'approve_close', 'Chờ đóng việc: ' || code, title, code from tasks
    where status = 'pending_confirm' and (public.is_admin() or assigner_id = auth.uid())
  union all
  select 'approve_due', 'Xin lùi hạn ' || to_char(requested_due,'DD/MM') || ': ' || code, coalesce(requested_reason,''), code from tasks
    where requested_due is not null and (public.is_admin() or assigner_id = auth.uid())
  union all
  select 'decide', 'Chờ quyết định (' || report_code || '): ' || left(content, 60), coalesce(proposal,''), id::text from support_requests
    where status = 'Chờ phản hồi' and public.is_admin()
  union all
  select 'missing', 'Chưa báo cáo ngày ' || to_char(public.tlc_today() - 1,'DD/MM') || ': ' || ps.report_code, ps.name, ps.report_code
    from positions ps where public.is_admin() and ps.report_code is not null and extract(dow from public.tlc_today() - 1) <> 0
      and not exists(select 1 from daily_reports r where r.report_code = ps.report_code and r.report_date = public.tlc_today() - 1)
$$;

-- ---------------------------------------------------------------------
-- 4. Trigger: giới hạn 3 ảnh / việc; khóa sửa trực tiếp sau 23:59
-- ---------------------------------------------------------------------
create or replace function public.tg_max_photos() returns trigger language plpgsql as $$
begin
  if (select count(*) from public.attachments where entity = new.entity and entity_id = new.entity_id) >= 3 then
    raise exception 'Tối đa 3 ảnh cho mỗi việc. Xóa ảnh cũ trước khi thêm.';
  end if;
  return new;
end $$;
drop trigger if exists max_photos on public.attachments;
create trigger max_photos before insert on public.attachments for each row execute function public.tg_max_photos();

do $$ declare t text; begin
  foreach t in array array['plan_items','support_requests','item_updates'] loop
    execute format('drop trigger if exists touch on public.%I; create trigger touch before update on public.%I for each row execute function public.tg_touch()', t, t);
    execute format('drop trigger if exists audit on public.%I; create trigger audit after insert or update or delete on public.%I for each row execute function public.tg_audit()', t, t);
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
  foreach t in array array['report_unlocks','code_counters'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 5. RLS
-- ---------------------------------------------------------------------
do $$ declare p record; begin
  for p in select policyname, tablename from pg_policies where schemaname = 'public'
    and tablename in ('daily_reports','daily_report_items','issues','plan_items','support_requests','item_updates','report_unlocks','code_counters','attachments','tasks') loop
    execute format('drop policy %I on public.%I', p.policyname, p.tablename);
  end loop; end $$;

-- Báo cáo ngày
create policy dr_read on public.daily_reports for select to authenticated using (public.can_read_code(report_code));
create policy dr_write on public.daily_reports for update to authenticated using (public.can_edit_code(report_code, report_date)) with check (public.can_edit_code(report_code, report_date));
-- (thêm mới qua touch_report)

-- Mục 2 – vấn đề: người nhập vị trí, TBP, GĐNM; BP phối hợp xem được vấn đề liên phòng ban
create policy issue_read on public.issues for select to authenticated
  using (public.is_admin() or (report_code is not null and public.can_read_code(report_code)) or created_by = auth.uid()
         or (cross_dept and public.my_dept() = any(coop_dept_ids)) or owner_id = auth.uid());
create policy issue_insert on public.issues for insert to authenticated
  with check (created_by = auth.uid() and (report_code is null or public.can_edit_code(report_code, open_date)));
create policy issue_update on public.issues for update to authenticated
  using (public.is_admin() or (report_code is not null and public.can_edit_code(report_code, public.tlc_today()) and status <> 'closed'))
  with check (public.is_admin() or status <> 'closed');

-- Mục 4, mục 5
create policy plan_read on public.plan_items for select to authenticated using (public.can_read_code(report_code));
create policy plan_insert on public.plan_items for insert to authenticated with check (public.can_edit_code(report_code, report_date));
create policy plan_update on public.plan_items for update to authenticated
  using (public.is_admin() or (public.can_edit_code(report_code, report_date) and status <> 'closed'))
  with check (public.is_admin() or status <> 'closed');
create policy plan_delete on public.plan_items for delete to authenticated using (public.can_edit_code(report_code, report_date) and status <> 'closed');

create policy sr_read on public.support_requests for select to authenticated using (public.can_read_code(report_code));
create policy sr_insert on public.support_requests for insert to authenticated with check (public.can_edit_code(report_code, report_date));
create policy sr_update on public.support_requests for update to authenticated
  using (public.is_admin() or public.can_edit_code(report_code, report_date))
  with check (public.is_admin() or (public.can_edit_code(report_code, report_date) and decision is null and status = 'Chờ phản hồi'));
create policy sr_delete on public.support_requests for delete to authenticated using (public.can_edit_code(report_code, report_date) and status = 'Chờ phản hồi');

-- Mục 3 – cập nhật: chỉ đọc trực tiếp; ghi qua save_update (kiểm tra khóa 23:59, quá hạn)
create policy iu_read on public.item_updates for select to authenticated using (report_code is null or public.can_read_code(report_code));
create policy unlock_read on public.report_unlocks for select to authenticated using (public.can_read_code(report_code));
-- code_counters: không có policy → chỉ qua next_code()

-- Việc
create or replace function public.can_see_task(t public.tasks) returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or t.assigner_id = auth.uid() or t.owner_id = auth.uid()
      or (t.report_code is not null and public.can_read_code(t.report_code))
      or exists(select 1 from task_assignments a where a.task_id = t.id and a.profile_id = auth.uid())
      or (t.dept_id is not null and public.is_head_of(t.dept_id))
      or (t.scope = 'factory' and public.is_active_user())
$$;
create policy task_read on public.tasks for select to authenticated using (public.can_see_task(tasks));
create policy task_insert on public.tasks for insert to authenticated
  with check (assigner_id = auth.uid() and (public.is_admin() or (dept_id is not null and public.is_head_of(dept_id))));
-- Sửa việc: người giao / GĐNM sửa nội dung; người phụ trách cập nhật qua save_update / tiếp nhận qua accept_task
create policy task_update on public.tasks for update to authenticated
  using (public.is_admin() or assigner_id = auth.uid()) with check (public.is_admin() or assigner_id = auth.uid());

create or replace function public.accept_task(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
begin
  update tasks set status = 'accepted', updated_at = now()
   where id = p_id and status = 'new' and (report_code = any(public.my_report_codes()) or owner_id = auth.uid());
  if not found then raise exception 'Không tiếp nhận được việc này'; end if;
  insert into task_updates(task_id, profile_id, status_from, status_to, note) values (p_id, auth.uid(), 'new', 'accepted', 'Đã tiếp nhận');
end $$;

-- Ảnh minh chứng (bảng attachments): xem theo quyền của việc; thêm/xóa bởi người liên quan. Xóa ảnh KHÔNG xóa việc.
create or replace function public.can_touch_entity(p_entity text, p_id bigint) returns boolean language sql stable security definer set search_path = public as $$
  select case p_entity
    when 'task'  then exists(select 1 from tasks t where t.id = p_id and (public.is_admin() or t.assigner_id = auth.uid() or t.owner_id = auth.uid() or t.report_code = any(public.my_report_codes())))
    when 'issue' then exists(select 1 from issues i where i.id = p_id and (public.is_admin() or i.created_by = auth.uid() or i.report_code = any(public.my_report_codes())))
    when 'plan'  then exists(select 1 from plan_items p where p.id = p_id and (public.is_admin() or p.report_code = any(public.my_report_codes())))
    else false end
$$;
create policy att_read on public.attachments for select to authenticated using (public.can_touch_entity(entity, entity_id) or public.is_admin()
  or (entity = 'task' and exists(select 1 from tasks t where t.id = entity_id and public.can_see_task(t))));
create policy att_insert on public.attachments for insert to authenticated with check (uploaded_by = auth.uid() and public.can_touch_entity(entity, entity_id));
create policy att_delete on public.attachments for delete to authenticated using (public.can_touch_entity(entity, entity_id));

grant execute on function public.next_code(text), public.my_report_codes(), public.dept_of_code(text), public.can_read_code(text),
  public.can_edit_code(text,date), public.unlock_report(text,date,int,text), public.touch_report(text,date),
  public.report_section3(text,date), public.save_update(text,bigint,text,date,numeric,text,date,text,text,date),
  public.task_decide(bigint,text,text), public.close_item(text,bigint,text), public.daily_summary(date), public.my_alerts(),
  public.accept_task(bigint), public.can_touch_entity(text,bigint), public.can_see_task(public.tasks) to authenticated;

-- ---------------------------------------------------------------------
-- 6. Kho ảnh (Supabase Storage): bucket riêng tư "evidence", tối đa 1 MB/ảnh (trang web tự nén ~300 KB)
-- ---------------------------------------------------------------------
do $$ begin
  if exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'buckets') then
    insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
    values ('evidence', 'evidence', false, 1048576, array['image/jpeg','image/png','image/webp'])
    on conflict (id) do update set public = false, file_size_limit = 1048576, allowed_mime_types = array['image/jpeg','image/png','image/webp'];
    execute 'drop policy if exists tlc_evidence_read on storage.objects';
    execute 'drop policy if exists tlc_evidence_insert on storage.objects';
    execute 'drop policy if exists tlc_evidence_delete on storage.objects';
    -- đường dẫn: <entity>/<id>/<tên file>
    execute $p$create policy tlc_evidence_read on storage.objects for select to authenticated
      using (bucket_id = 'evidence' and exists(select 1 from public.attachments a where a.storage_path = name))$p$;
    execute $p$create policy tlc_evidence_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'evidence' and public.can_touch_entity(split_part(name,'/',1), nullif(split_part(name,'/',2),'')::bigint))$p$;
    execute $p$create policy tlc_evidence_delete on storage.objects for delete to authenticated
      using (bucket_id = 'evidence' and public.can_touch_entity(split_part(name,'/',1), nullif(split_part(name,'/',2),'')::bigint))$p$;
  end if;
end $$;

-- Chỉ số mục 1 mặc định cho 14 vị trí (GĐNM sửa trong Cấu hình)
update public.app_settings set value = '{
 "KHSX":[["kh_sl","KH sản lượng hôm nay","sp"],["th_nk","Thực hiện nhập kho","sp"],["don_3n","Đơn đến hạn giao trong 3 ngày","đơn"],["don_nguy_co","Đơn có nguy cơ trễ","đơn"],["vt_thieu","Mã vật tư thiếu (3 ngày tới)","mã"],["thay_doi_kh","Thay đổi kế hoạch trong ngày","lần"]],
 "TKLK":[["nhap","Phiếu nhập linh kiện","phiếu"],["xuat","Phiếu xuất cho sản xuất","phiếu"],["cap_sai_kh","Cấp không đúng kế hoạch","dòng"],["ng_tra_ve","Hàng NG sản xuất trả về","sp"],["ma_thieu","Mã thiếu theo lệnh tuần","mã"]],
 "KTKLK":[["ct_xu_ly","Chứng từ đã xử lý","chứng từ"],["ct_treo","Chứng từ treo","chứng từ"],["lech_ton","Mã lệch tồn so với Bravo","mã"]],
 "TKTP":[["nhap_tp","Nhập kho thành phẩm","sp"],["xuat_tp","Xuất kho thành phẩm","sp"],["lech_sx","Lệch so với sản xuất báo","sp"],["ton_tp","Tồn thành phẩm cuối ngày","sp"]],
 "KTKTP":[["ct_xu_ly","Chứng từ đã xử lý","chứng từ"],["ct_treo","Chứng từ treo","chứng từ"],["lech_ton","Mã lệch tồn so với Bravo","mã"]],
 "QAC":[["iqc","Số lô IQC","lô"],["pqc_kt","PQC kiểm tra","sp"],["ng_op","NG thao tác","sp"],["ng_sup","NG nhà cung cấp","sp"],["oqc","OQC kiểm tra","sp"],["capa_mo","CAPA đang mở","việc"]],
 "BHN":[["ca_moi","Ca bảo hành mới","ca"],["ca_xong","Ca hoàn thành","ca"],["ca_qua_han","Ca quá cam kết","ca"],["chi_phi","Chi phí bảo hành","nghìn đ"]],
 "BHM":[["sp_nhan","Sản phẩm bảo hành nhận về","sp"],["sp_xong","Sản phẩm xử lý xong","sp"],["sp_ton","Tồn chờ xử lý","sp"]],
 "SX":[["kh_sl","Kế hoạch sản lượng","sp"],["sl_dat","Sản lượng đạt","sp"],["ng","Sản lượng NG","sp"],["nhan_luc","Nhân lực có mặt","người"],["gio_tc","Giờ tăng ca","giờ"],["dung_may","Dừng máy","phút"]],
 "KTGT":[["cp_nvl","Chi phí NVL","triệu đ"],["cp_nc","Chi phí nhân công","triệu đ"],["gia_tri_loi","Giá trị hàng lỗi","triệu đ"]],
 "HCNS":[["tong","Tổng nhân sự","người"],["co_mat","Có mặt","người"],["nghi","Nghỉ","người"],["moi","Tuyển mới","người"],["nghi_viec","Nghỉ việc","người"]],
 "KTSX":[["loi_kt","Lỗi kỹ thuật xử lý","việc"],["cai_tien","Cải tiến công đoạn","việc"]],
 "KTSP":[["doi_bom","Thay đổi BOM","mã"],["thu_nghiem","Thử nghiệm hoàn thành","mẫu"]],
 "CĐ":[["su_co","Sự cố thiết bị","lần"],["dung_may","Thời gian dừng máy","phút"],["pm_ht","Bảo trì định kỳ hoàn thành","việc"],["pm_tre","Bảo trì định kỳ trễ","việc"]]
}' where key = 'report_metrics' and value = '{}';

-- Vị trí bổ sung 01/11/2026: Nhân viên kế hoạch vật tư (báo cáo ngày, mã KHVT, thuộc Phòng KHSX)
insert into public.positions(code, name, dept_id, kind, report_code) values ('KHVT','Nhân viên kế hoạch vật tư',4,'staff','KHVT')
on conflict (code) do update set name = excluded.name, dept_id = excluded.dept_id, kind = excluded.kind, report_code = excluded.report_code;
update public.app_settings set value = value || '{"KHVT":[["vt_thieu","Mã vật tư thiếu theo lệnh SX tuần","mã"],["pr_moi","Đề nghị mua mới phát sinh","phiếu"],["po_dat","Đơn mua (PO) đã đặt","PO"],["hang_ve","Lô hàng về theo kế hoạch","lô"],["hang_tre","Lô hàng về trễ so với cam kết","lô"],["duoi_min","Mã dưới tồn tối thiểu (MIN)","mã"]]}'::jsonb
 where key = 'report_metrics' and not (value ? 'KHVT');
