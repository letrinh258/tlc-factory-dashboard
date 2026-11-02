-- =====================================================================
-- Module "Kỹ thuật" – ECR (Engineering Change Request): phiếu đề xuất
-- thay đổi kỹ thuật/BOM/định mức/mã sản phẩm mới, có luồng duyệt.
-- Khi duyệt loại "norm": tự cập nhật products.norm_per_hour qua đúng cơ
-- chế set_norms() đã có (norm_changes giữ lịch sử sẵn, không cần bảng
-- lịch sử riêng). Khi duyệt loại "new_product": tự tạo dòng mới trong
-- products (NPI).
-- =====================================================================

create table if not exists public.ecr(
  id bigserial primary key, code text unique not null,              -- KT-ddmm-NN
  product_code text references public.products(code),               -- null nếu là "Mã mới"
  change_type text not null check (change_type in ('bom','norm','spec','new_product','other')),
  content text not null,                                             -- nội dung đề xuất (từ → đến)
  reason text,
  new_code text,                                                     -- mã SP mới đề xuất (change_type='new_product')
  new_name text,                                                     -- tên SP mới (change_type='new_product')
  new_norm numeric,                                                  -- định mức mới (change_type='norm' hoặc 'new_product')
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  proposed_by uuid not null default auth.uid() references public.profiles(id),
  proposed_at date not null default (now() at time zone 'Asia/Ho_Chi_Minh')::date,
  decided_by uuid references public.profiles(id), decided_at timestamptz, decide_note text, effective_date date,
  created_at timestamptz not null default now()
);
alter table public.ecr enable row level security;
revoke all on public.ecr from anon;

create policy ecr_read on public.ecr for select to authenticated using (public.is_active_user());
create policy ecr_insert on public.ecr for insert to authenticated with check (public.is_active_user() and proposed_by = auth.uid());

-- GĐNM (hoặc người được giao duyệt sau này) quyết định; áp dụng thay đổi khi duyệt
create or replace function public.ecr_decide(p_id bigint, p_action text, p_note text, p_effective date)
returns void language plpgsql security definer set search_path = public as $$
declare r public.ecr; o numeric;
begin
  if not public.is_admin() then raise exception 'Chỉ GĐNM / người được giao được duyệt ECR'; end if;
  select * into r from public.ecr where id = p_id;
  if not found then raise exception 'Không tìm thấy phiếu ECR'; end if;
  if r.status <> 'pending' then raise exception 'Phiếu đã được quyết định'; end if;
  if p_action = 'approve' then
    if r.change_type = 'norm' then
      if r.product_code is null or r.new_norm is null then raise exception 'Thiếu mã sản phẩm hoặc định mức mới'; end if;
      select norm_per_hour into o from public.products where code = r.product_code;
      update public.products set norm_per_hour = r.new_norm, norm_manual = true, norm_updated_at = now(), norm_updated_by = auth.uid() where code = r.product_code;
      insert into public.norm_changes(product_code, old_norm, new_norm, note) values (r.product_code, o, r.new_norm, 'Duyệt ECR '||r.code||coalesce(': '||p_note,''));
    elsif r.change_type = 'new_product' then
      if coalesce(trim(r.new_code),'') = '' or coalesce(trim(r.new_name),'') = '' then raise exception 'Thiếu mã hoặc tên sản phẩm mới'; end if;
      insert into public.products(code, name, norm_per_hour, source) values (r.new_code, r.new_name, r.new_norm, 'ecr')
      on conflict (code) do update set name = excluded.name, norm_per_hour = coalesce(excluded.norm_per_hour, public.products.norm_per_hour);
    end if;
    update public.ecr set status = 'approved', decided_by = auth.uid(), decided_at = now(), decide_note = p_note, effective_date = coalesce(p_effective, public.tlc_today()) where id = p_id;
  elsif p_action = 'reject' then
    if coalesce(trim(p_note),'') = '' then raise exception 'Ghi lý do từ chối'; end if;
    update public.ecr set status = 'rejected', decided_by = auth.uid(), decided_at = now(), decide_note = p_note where id = p_id;
  else raise exception 'Thao tác không hợp lệ'; end if;
end $$;
revoke execute on function public.ecr_decide(bigint,text,text,date) from anon;
grant execute on function public.ecr_decide(bigint,text,text,date) to authenticated;

-- Kiểm tra sau khi chạy:
-- select count(*) from pg_policies where tablename = 'ecr';
-- select proname from pg_proc where proname = 'ecr_decide';
