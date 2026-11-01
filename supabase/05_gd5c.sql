-- =====================================================================
-- TLC FACTORY OPERATION DASHBOARD · Giai đoạn 5C – Đánh giá 5S
-- 5 nhóm × 5 tiêu chí × thang 1–5 → %, hằng tuần. Người đánh giá nhập bằng tài khoản mình, chọn BP nhận.
-- Lỗi phát hiện có ảnh trước; BP nhận nhập đối sách + ảnh sau; người đánh giá / GĐNM xác nhận đóng.
-- Chạy SAU file 01–04. Chạy lại được.
-- =====================================================================
alter table public.fives_findings add column if not exists criterion text;
alter table public.fives_findings add column if not exists owner_name text;
alter table public.fives_findings add column if not exists verify_note text;
alter table public.fives_findings add column if not exists closed_at timestamptz;
alter table public.fives_findings add column if not exists created_at timestamptz not null default now();
alter table public.fives_audits add column if not exists note text;
alter table public.fives_audits drop constraint if exists fives_audits_total_check;
alter table public.fives_audits add constraint fives_audits_total_check check (total is null or (total >= 0 and total <= 100));

insert into public.app_settings(key, value) values ('fives_criteria', '{"target":80,"groups":[
 {"k":"S1","name":"Sàng lọc","items":["Không có vật tư, dụng cụ không cần thiết tại khu vực","Hàng NG, phế liệu được tách riêng, có nhãn","Không có hồ sơ, giấy tờ cũ không dùng","Máy móc, thiết bị không dùng đã được đưa đi hoặc dán nhãn","Có khu vực tạm chứa đồ chờ xử lý, có thời hạn"]},
 {"k":"S2","name":"Sắp xếp","items":["Vạch kẻ khu vực, lối đi rõ ràng, không bị lấn chiếm","Vật tư, bán thành phẩm đặt đúng vị trí, có nhãn mã","Dụng cụ có vị trí cố định, có hình bóng hoặc nhãn","Bảng biểu, hướng dẫn công việc đặt đúng chỗ, dễ thấy","Thùng, kệ có nhãn tên, mã, số lượng tối đa"]},
 {"k":"S3","name":"Sạch sẽ","items":["Sàn, lối đi sạch, không rác, không dầu","Máy móc, thiết bị sạch, không bụi bám","Bàn thao tác, đồ gá sạch","Có lịch vệ sinh và người phụ trách","Nguồn gây bẩn đã được xử lý tận gốc"]},
 {"k":"S4","name":"Săn sóc","items":["Có tiêu chuẩn 5S khu vực bằng hình ảnh","Có checklist 5S hằng ngày và được ghi đầy đủ","Lỗi lần trước đã được khắc phục","Trưởng khu vực kiểm tra định kỳ","Kết quả 5S được công bố tại khu vực"]},
 {"k":"S5","name":"Sẵn sàng","items":["Công nhân mặc đồng phục, đeo bảo hộ đúng quy định","Công nhân trả lời được tiêu chuẩn 5S khu vực","Tuân thủ quy định an toàn, PCCC","Không có hành vi vi phạm kỷ luật tại khu vực","Tham gia cải tiến, góp ý 5S"]}]}')
on conflict (key) do nothing;

-- Tổng điểm % từ scores {"S1-1":4,...}
create or replace function public.fives_total(p_scores jsonb) returns numeric language sql immutable as $$
  select round(sum(v::numeric) / (count(*) * 5) * 100, 1) from jsonb_each_text(p_scores) e(k, v)
$$;

create or replace function public.save_5s_audit(p_id bigint, d date, p_dept int, p_area text, p_scores jsonb, p_note text) returns bigint
language plpgsql security definer set search_path = public as $$
declare rid bigint; a fives_audits; n int; k text; v text; crit jsonb;
begin
  if not public.is_active_user() then raise exception 'Chưa đăng nhập'; end if;
  if d > public.tlc_today() or d < public.tlc_today() - 6 then raise exception 'Ngày đánh giá trong 7 ngày gần nhất'; end if;
  if not exists(select 1 from departments where id = p_dept) then raise exception 'Chọn bộ phận được đánh giá'; end if;
  if not public.is_admin() and public.in_dept(p_dept) then raise exception 'Không tự đánh giá bộ phận của mình'; end if;
  if coalesce(trim(p_area),'') = '' then raise exception 'Nhập khu vực đánh giá'; end if;
  select value into crit from app_settings where key = 'fives_criteria';
  n := (select sum(jsonb_array_length(g->'items')) from jsonb_array_elements(crit->'groups') g);
  if (select count(*) from jsonb_object_keys(p_scores)) <> n then raise exception 'Chấm đủ % tiêu chí', n; end if;
  for k, v in select * from jsonb_each_text(p_scores) loop
    if v !~ '^[1-5]$' then raise exception 'Điểm tiêu chí % phải từ 1 đến 5', k; end if;
  end loop;
  if p_id is null then
    insert into fives_audits(audit_date, auditor_id, target_dept_id, area, scores, total, note)
    values (d, auth.uid(), p_dept, trim(p_area), p_scores, public.fives_total(p_scores), p_note) returning id into rid;
  else
    select * into a from fives_audits where id = p_id;
    if not found then raise exception 'Không tìm thấy phiếu'; end if;
    if not (public.is_admin() or (a.auditor_id = auth.uid() and a.audit_date = public.tlc_today())) then
      raise exception 'Chỉ người đánh giá sửa trong ngày, hoặc GĐNM'; end if;
    update fives_audits set audit_date = d, target_dept_id = p_dept, area = trim(p_area), scores = p_scores, total = public.fives_total(p_scores), note = p_note
    where id = p_id returning id into rid;
  end if;
  return rid;
end $$;

create or replace function public.add_5s_finding(p_audit bigint, p_criterion text, p_desc text, p_due date) returns bigint
language plpgsql security definer set search_path = public as $$
declare a fives_audits; rid bigint;
begin
  select * into a from fives_audits where id = p_audit;
  if not found then raise exception 'Không tìm thấy phiếu'; end if;
  if not (public.is_admin() or a.auditor_id = auth.uid()) then raise exception 'Chỉ người đánh giá ghi lỗi'; end if;
  if coalesce(trim(p_desc),'') = '' then raise exception 'Mô tả lỗi'; end if;
  if p_due is null or p_due < a.audit_date then raise exception 'Hạn khắc phục phải từ ngày đánh giá trở đi'; end if;
  insert into fives_findings(audit_id, criterion, description, due_date, status) values (p_audit, p_criterion, trim(p_desc), p_due, 'open') returning id into rid;
  return rid;
end $$;

-- BP nhận: nhập đối sách / người phụ trách / đề nghị đóng (phải có ảnh sau) · Người đánh giá / GĐNM: đóng hoặc trả lại · xóa lỗi ghi nhầm
create or replace function public.update_5s_finding(p_id bigint, p_action text, p_counter text, p_owner text, p_due date, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare f fives_findings; a fives_audits;
begin
  select * into f from fives_findings where id = p_id; if not found then raise exception 'Không tìm thấy lỗi'; end if;
  select * into a from fives_audits where id = f.audit_id;
  if p_action in ('counter','request_close') then
    if not (public.is_admin() or public.in_dept(a.target_dept_id)) then raise exception 'Chỉ bộ phận được đánh giá nhập đối sách'; end if;
    if f.status = 'closed' then raise exception 'Lỗi đã đóng'; end if;
    if coalesce(trim(p_counter),'') = '' then raise exception 'Nhập đối sách'; end if;
    if coalesce(trim(p_owner),'') = '' then raise exception 'Nhập người phụ trách'; end if;
    if p_action = 'request_close' and not exists(select 1 from attachments where entity = 'fsa' and entity_id = p_id) then
      raise exception 'Tải ít nhất 1 ảnh sau khắc phục trước khi đề nghị đóng'; end if;
    update fives_findings set countermeasure = trim(p_counter), owner_name = trim(p_owner),
      due_date = coalesce(p_due, due_date), status = case when p_action = 'request_close' then 'pending_verify' else 'fixing' end, updated_at = now()
    where id = p_id;
  elsif p_action in ('close','reopen') then
    if not (public.is_admin() or a.auditor_id = auth.uid()) then raise exception 'Chỉ người đánh giá hoặc GĐNM xác nhận'; end if;
    if p_action = 'close' and f.status <> 'pending_verify' and not public.is_admin() then raise exception 'BP chưa đề nghị đóng'; end if;
    if p_action = 'reopen' and coalesce(trim(p_note),'') = '' then raise exception 'Ghi lý do trả lại'; end if;
    update fives_findings set status = case when p_action = 'close' then 'closed' else 'fixing' end, verify_note = p_note,
      closed_at = case when p_action = 'close' then now() end, updated_at = now() where id = p_id;
  elsif p_action = 'delete' then
    if not (public.is_admin() or (a.auditor_id = auth.uid() and f.status = 'open')) then raise exception 'Chỉ xóa lỗi chưa xử lý, do người đánh giá ghi'; end if;
    delete from attachments where entity in ('fsb','fsa') and entity_id = p_id;
    delete from fives_findings where id = p_id;
  else raise exception 'Thao tác không hợp lệ'; end if;
end $$;

-- Bảng điểm 5S (công khai cho mọi người đang làm việc): theo BP trong khoảng ngày
create or replace function public.fives_board(d_from date, d_to date) returns table(dept_id smallint, dept_name text, audits int, last_date date,
  last_total numeric, avg_total numeric, open_findings int, overdue_findings int, closed_findings int, by_group jsonb)
language sql stable security definer set search_path = public as $$
  select d.id, d.name, count(a.id)::int, max(a.audit_date),
    (select total from fives_audits x where x.target_dept_id = d.id and x.audit_date between d_from and d_to order by audit_date desc, id desc limit 1),
    round(avg(a.total), 1),
    (select count(*)::int from fives_findings f join fives_audits x on x.id = f.audit_id where x.target_dept_id = d.id and f.status <> 'closed'),
    (select count(*)::int from fives_findings f join fives_audits x on x.id = f.audit_id where x.target_dept_id = d.id and f.status <> 'closed' and f.due_date < public.tlc_today()),
    (select count(*)::int from fives_findings f join fives_audits x on x.id = f.audit_id where x.target_dept_id = d.id and f.status = 'closed' and x.audit_date between d_from and d_to),
    (select jsonb_object_agg(g, v) from (select left(e.key, 2) g, round(avg(e.value::numeric) / 5 * 100, 0) v
       from fives_audits x, jsonb_each_text(x.scores) e where x.target_dept_id = d.id and x.audit_date between d_from and d_to group by 1) s)
  from departments d left join fives_audits a on a.target_dept_id = d.id and a.audit_date between d_from and d_to
  where public.is_active_user() and d.code <> 'BGD'
  group by d.id, d.name, d.sort order by d.sort
$$;

-- Ảnh 5S: fsb = ảnh trước (người đánh giá), fsa = ảnh sau (BP nhận). Giữ nguyên các loại cũ.
create or replace function public.can_touch_entity(p_entity text, p_id bigint) returns boolean language sql stable security definer set search_path = public as $$
  select case p_entity
    when 'task'  then exists(select 1 from tasks t where t.id = p_id and (public.is_admin() or t.assigner_id = auth.uid() or t.owner_id = auth.uid() or t.report_code = any(public.my_report_codes())))
    when 'issue' then exists(select 1 from issues i where i.id = p_id and (public.is_admin() or i.created_by = auth.uid() or i.report_code = any(public.my_report_codes())))
    when 'plan'  then exists(select 1 from plan_items p where p.id = p_id and (public.is_admin() or p.report_code = any(public.my_report_codes())))
    when 'fsb'   then exists(select 1 from fives_findings f join fives_audits a on a.id = f.audit_id where f.id = p_id and f.status <> 'closed' and (public.is_admin() or a.auditor_id = auth.uid()))
    when 'fsa'   then exists(select 1 from fives_findings f join fives_audits a on a.id = f.audit_id where f.id = p_id and f.status in ('open','fixing') and (public.is_admin() or public.in_dept(a.target_dept_id)))
    else false end
$$;
drop policy if exists att_read_5s on public.attachments;
create policy att_read_5s on public.attachments for select to authenticated using (entity in ('fsb','fsa') and exists(
  select 1 from public.fives_findings f join public.fives_audits a on a.id = f.audit_id
  where f.id = entity_id and (public.is_admin() or a.auditor_id = auth.uid() or public.in_dept(a.target_dept_id))));

-- RLS: ghi chỉ qua hàm
drop policy if exists audit_insert on public.fives_audits;
drop policy if exists audit_update on public.fives_audits;
drop policy if exists finding_write on public.fives_findings;

revoke execute on function public.save_5s_audit(bigint,date,int,text,jsonb,text), public.add_5s_finding(bigint,text,text,date),
  public.update_5s_finding(bigint,text,text,text,date,text), public.fives_board(date,date), public.fives_total(jsonb) from anon, public;
grant execute on function public.save_5s_audit(bigint,date,int,text,jsonb,text), public.add_5s_finding(bigint,text,text,date),
  public.update_5s_finding(bigint,text,text,text,date,text), public.fives_board(date,date), public.fives_total(jsonb) to authenticated;
