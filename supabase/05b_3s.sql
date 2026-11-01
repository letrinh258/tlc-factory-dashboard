-- =====================================================================
-- TLC FACTORY OPERATION DASHBOARD · Giai đoạn 5C (chốt 01/11/2026) – 3S
-- Chỉ 3S: S1 Sàng lọc · S2 Sắp xếp · S3 Sạch sẽ. Không chấm điểm: thống kê theo SỐ LỖI của từng S.
-- Mỗi lỗi = 1 ảnh (bắt buộc). BP nhận nhập đối sách → đề nghị đóng; người ghi lỗi / GĐNM xác nhận đóng.
-- Chạy SAU file 05_gd5c.sql. Chạy lại được.
-- =====================================================================
update public.app_settings set value = '{"groups":[
 {"k":"S1","name":"Sàng lọc","hint":"Đồ không cần thiết, hàng NG, phế liệu, hồ sơ cũ chưa loại bỏ"},
 {"k":"S2","name":"Sắp xếp","hint":"Sai vị trí, thiếu nhãn, lấn vạch, lối đi bị chặn, dụng cụ không có chỗ cố định"},
 {"k":"S3","name":"Sạch sẽ","hint":"Sàn, máy, bàn thao tác bẩn; dầu, rác, bụi; nguồn gây bẩn chưa xử lý"}]}'::jsonb
where key = 'fives_criteria';
insert into public.app_settings(key, value) select 'fives_criteria', '{"groups":[{"k":"S1","name":"Sàng lọc"},{"k":"S2","name":"Sắp xếp"},{"k":"S3","name":"Sạch sẽ"}]}'
where not exists(select 1 from public.app_settings where key = 'fives_criteria');

alter table public.fives_findings drop constraint if exists fives_findings_criterion_check;
update public.fives_findings set criterion = left(criterion, 2) where criterion is not null and criterion !~ '^S[123]$' and left(criterion,2) in ('S1','S2','S3');
alter table public.fives_findings add constraint fives_findings_criterion_check check (criterion in ('S1','S2','S3')) not valid;

drop function if exists public.save_5s_audit(bigint,date,int,text,jsonb,text);
drop function if exists public.add_5s_finding(bigint,text,text,date);
drop function if exists public.fives_board(date,date);

-- Ghi 1 lỗi 3S (phiên kiểm tra = ngày × người ghi × BP × khu vực, tự tạo)
create or replace function public.add_3s_finding(d date, p_dept int, p_area text, p_s text, p_desc text, p_due date) returns bigint
language plpgsql security definer set search_path = public as $$
declare aid bigint; rid bigint;
begin
  if not public.is_active_user() then raise exception 'Chưa đăng nhập'; end if;
  if d > public.tlc_today() or d < public.tlc_today() - 6 then raise exception 'Ngày kiểm tra trong 7 ngày gần nhất'; end if;
  if not exists(select 1 from departments where id = p_dept and code <> 'BGD') then raise exception 'Chọn bộ phận được kiểm tra'; end if;
  if not public.is_admin() and public.in_dept(p_dept) then raise exception 'Không tự ghi lỗi 3S cho bộ phận của mình'; end if;
  if p_s not in ('S1','S2','S3') then raise exception 'Chọn Sàng lọc, Sắp xếp hoặc Sạch sẽ'; end if;
  if coalesce(trim(p_area),'') = '' then raise exception 'Nhập khu vực'; end if;
  if coalesce(trim(p_desc),'') = '' then raise exception 'Mô tả lỗi'; end if;
  if p_due is null or p_due < d then raise exception 'Hạn khắc phục phải từ ngày kiểm tra trở đi'; end if;
  select id into aid from fives_audits where audit_date = d and auditor_id = auth.uid() and target_dept_id = p_dept and area = trim(p_area) limit 1;
  if aid is null then
    insert into fives_audits(audit_date, auditor_id, target_dept_id, area, scores, total) values (d, auth.uid(), p_dept, trim(p_area), '{}', null) returning id into aid;
  end if;
  insert into fives_findings(audit_id, criterion, description, due_date, status) values (aid, p_s, trim(p_desc), p_due, 'open') returning id into rid;
  return rid;
end $$;

-- Đối sách / đề nghị đóng (BP nhận) · xác nhận đóng / trả lại (người ghi, GĐNM) · xóa lỗi ghi nhầm
create or replace function public.update_5s_finding(p_id bigint, p_action text, p_counter text, p_owner text, p_due date, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare f fives_findings; a fives_audits;
begin
  select * into f from fives_findings where id = p_id; if not found then raise exception 'Không tìm thấy lỗi'; end if;
  select * into a from fives_audits where id = f.audit_id;
  if p_action in ('counter','request_close') then
    if not (public.is_admin() or public.in_dept(a.target_dept_id)) then raise exception 'Chỉ bộ phận được kiểm tra nhập đối sách'; end if;
    if f.status in ('closed','pending_verify') and p_action = 'request_close' then raise exception 'Lỗi đã đề nghị đóng hoặc đã đóng'; end if;
    if f.status = 'closed' then raise exception 'Lỗi đã đóng'; end if;
    if coalesce(trim(p_counter),'') = '' then raise exception 'Nhập đối sách'; end if;
    if coalesce(trim(p_owner),'') = '' then raise exception 'Nhập người phụ trách'; end if;
    update fives_findings set countermeasure = trim(p_counter), owner_name = trim(p_owner), due_date = coalesce(p_due, due_date),
      status = case when p_action = 'request_close' then 'pending_verify' else 'fixing' end, updated_at = now() where id = p_id;
  elsif p_action in ('close','reopen') then
    if not (public.is_admin() or a.auditor_id = auth.uid()) then raise exception 'Chỉ người ghi lỗi hoặc GĐNM xác nhận'; end if;
    if p_action = 'close' and f.status <> 'pending_verify' and not public.is_admin() then raise exception 'Bộ phận chưa đề nghị đóng'; end if;
    if p_action = 'reopen' and coalesce(trim(p_note),'') = '' then raise exception 'Ghi lý do trả lại'; end if;
    update fives_findings set status = case when p_action = 'close' then 'closed' else 'fixing' end, verify_note = p_note,
      closed_at = case when p_action = 'close' then now() end, updated_at = now() where id = p_id;
  elsif p_action = 'delete' then
    if not (public.is_admin() or (a.auditor_id = auth.uid() and f.status = 'open')) then raise exception 'Chỉ xóa lỗi chưa xử lý, do chính người ghi'; end if;
    delete from attachments where entity = 'fsb' and entity_id = p_id;
    delete from fives_findings where id = p_id;
    delete from fives_audits x where x.id = a.id and not exists(select 1 from fives_findings y where y.audit_id = x.id);
  else raise exception 'Thao tác không hợp lệ'; end if;
end $$;

-- Thống kê 3S theo bộ phận: số lỗi S1 / S2 / S3 trong kỳ (theo ngày kiểm tra) + tình trạng xử lý (công khai)
create or replace function public.fives_board(d_from date, d_to date) returns table(dept_id smallint, dept_name text,
  s1 int, s2 int, s3 int, total int, open_findings int, overdue_findings int, closed_findings int, no_photo int, last_date date)
language sql stable security definer set search_path = public as $$
  select d.id, d.name,
    count(f.id) filter (where f.criterion = 'S1')::int, count(f.id) filter (where f.criterion = 'S2')::int, count(f.id) filter (where f.criterion = 'S3')::int,
    count(f.id)::int,
    count(f.id) filter (where f.status <> 'closed')::int,
    count(f.id) filter (where f.status <> 'closed' and f.due_date < public.tlc_today())::int,
    count(f.id) filter (where f.status = 'closed')::int,
    count(f.id) filter (where not exists(select 1 from attachments t where t.entity = 'fsb' and t.entity_id = f.id))::int,
    max(a.audit_date)
  from departments d
  left join fives_audits a on a.target_dept_id = d.id and a.audit_date between d_from and d_to
  left join fives_findings f on f.audit_id = a.id
  where public.is_active_user() and d.code <> 'BGD'
  group by d.id, d.name, d.sort order by d.sort
$$;

-- 1 ảnh cho 1 lỗi 3S; việc / vấn đề vẫn tối đa 3 ảnh
create or replace function public.tg_max_photos() returns trigger language plpgsql as $$
declare lim int := case when new.entity = 'fsb' then 1 else 3 end;
begin
  if (select count(*) from public.attachments where entity = new.entity and entity_id = new.entity_id) >= lim then
    raise exception '%', case when lim = 1 then 'Mỗi lỗi 3S chỉ 1 ảnh. Xóa ảnh cũ trước khi thay.' else 'Tối đa 3 ảnh cho mỗi việc. Xóa ảnh cũ trước khi thêm.' end;
  end if;
  return new;
end $$;

-- Ảnh lỗi 3S: người ghi lỗi (hoặc GĐNM) tải khi lỗi chưa đóng; bỏ ảnh "sau"
create or replace function public.can_touch_entity(p_entity text, p_id bigint) returns boolean language sql stable security definer set search_path = public as $$
  select case p_entity
    when 'task'  then exists(select 1 from tasks t where t.id = p_id and (public.is_admin() or t.assigner_id = auth.uid() or t.owner_id = auth.uid() or t.report_code = any(public.my_report_codes())))
    when 'issue' then exists(select 1 from issues i where i.id = p_id and (public.is_admin() or i.created_by = auth.uid() or i.report_code = any(public.my_report_codes())))
    when 'plan'  then exists(select 1 from plan_items p where p.id = p_id and (public.is_admin() or p.report_code = any(public.my_report_codes())))
    when 'fsb'   then exists(select 1 from fives_findings f join fives_audits a on a.id = f.audit_id where f.id = p_id and f.status <> 'closed' and (public.is_admin() or a.auditor_id = auth.uid()))
    else false end
$$;

revoke execute on function public.add_3s_finding(date,int,text,text,text,date), public.fives_board(date,date) from anon, public;
grant execute on function public.add_3s_finding(date,int,text,text,text,date), public.fives_board(date,date),
  public.update_5s_finding(bigint,text,text,text,date,text) to authenticated;
