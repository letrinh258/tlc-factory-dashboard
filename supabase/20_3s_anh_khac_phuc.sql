-- =====================================================================
-- 3S: thêm lại ẢNH KHẮC PHỤC (entity 'fsa') song song ảnh lỗi (entity
-- 'fsb'), theo yêu cầu của anh 02/11 — người tải ảnh khắc phục là BỘ
-- PHẬN MẮC LỖI (target_dept_id), không phải người ghi lỗi. Bảng
-- attachments và policy đọc 'fsb'/'fsa' đã có sẵn từ 05_gd5c.sql
-- (att_read_5s); chỉ cần mở lại quyền GHI cho 'fsa' và bắt buộc có ảnh
-- khắc phục trước khi BP nhận đề nghị đóng lỗi.
-- Chạy SAU 05b_3s.sql. Chạy lại được.
-- =====================================================================

-- Ảnh lỗi 3S (fsb): người ghi lỗi/GĐNM, khi chưa đóng.
-- Ảnh khắc phục 3S (fsa): bộ phận mắc lỗi (target_dept_id)/GĐNM, khi đang mở/đang khắc phục.
create or replace function public.can_touch_entity(p_entity text, p_id bigint) returns boolean language sql stable security definer set search_path = public as $$
  select case p_entity
    when 'task'  then exists(select 1 from tasks t where t.id = p_id and (public.is_admin() or t.assigner_id = auth.uid() or t.owner_id = auth.uid() or t.report_code = any(public.my_report_codes())))
    when 'issue' then exists(select 1 from issues i where i.id = p_id and (public.is_admin() or i.created_by = auth.uid() or i.report_code = any(public.my_report_codes())))
    when 'plan'  then exists(select 1 from plan_items p where p.id = p_id and (public.is_admin() or p.report_code = any(public.my_report_codes())))
    when 'fsb'   then exists(select 1 from fives_findings f join fives_audits a on a.id = f.audit_id where f.id = p_id and f.status <> 'closed' and (public.is_admin() or a.auditor_id = auth.uid()))
    when 'fsa'   then exists(select 1 from fives_findings f join fives_audits a on a.id = f.audit_id where f.id = p_id and f.status in ('open','fixing') and (public.is_admin() or public.in_dept(a.target_dept_id)))
    else false end
$$;

-- 1 ảnh cho fsb và fsa (ảnh lỗi + ảnh khắc phục); việc/vấn đề vẫn tối đa 3 ảnh
create or replace function public.tg_max_photos() returns trigger language plpgsql as $$
declare lim int := case when new.entity in ('fsb','fsa') then 1 else 3 end;
begin
  if (select count(*) from public.attachments where entity = new.entity and entity_id = new.entity_id) >= lim then
    raise exception '%', case when lim = 1 then 'Mỗi lỗi 3S chỉ 1 ảnh cho mục này. Xóa ảnh cũ trước khi thay.' else 'Tối đa 3 ảnh cho mỗi việc. Xóa ảnh cũ trước khi thêm.' end;
  end if;
  return new;
end $$;

-- Đối sách / đề nghị đóng (BP nhận, phải có ảnh khắc phục) · xác nhận đóng / trả lại (người ghi, GĐNM) · xóa lỗi ghi nhầm
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
    if p_action = 'request_close' and not exists(select 1 from attachments where entity = 'fsa' and entity_id = p_id) then
      raise exception 'Tải ảnh khắc phục trước khi đề nghị đóng'; end if;
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
    delete from attachments where entity in ('fsb','fsa') and entity_id = p_id;
    delete from fives_findings where id = p_id;
    delete from fives_audits x where x.id = a.id and not exists(select 1 from fives_findings y where y.audit_id = x.id);
  else raise exception 'Thao tác không hợp lệ'; end if;
end $$;

-- att_read_5s (đọc fsb/fsa) đã được tạo đúng từ 05_gd5c.sql, không cần tạo lại.

-- Kiểm tra sau khi chạy:
-- select proname from pg_proc where proname in ('can_touch_entity','tg_max_photos','update_5s_finding');
-- select policyname from pg_policies where tablename = 'attachments' and policyname = 'att_read_5s';
