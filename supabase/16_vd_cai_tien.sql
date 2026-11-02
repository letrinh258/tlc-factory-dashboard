-- =====================================================================
-- Module "Vấn đề và cải tiến" (Tab A: Vấn đề/CAPA tổng hợp từ issues +
-- corrective_actions đã có; Tab B: Dự án cải tiến từ improvement_projects
-- đã có). KHÔNG tạo bảng mới. Chỉ mở quyền ghi improvement_projects cho
-- TBP (is_head_of dept mình) và người tạo, không chỉ GĐNM như cũ — đúng
-- yêu cầu "GĐNM/TBP tạo và theo dõi dự án cải tiến".
-- =====================================================================

drop policy if exists proj_write on public.improvement_projects;
create policy proj_write on public.improvement_projects for all to authenticated
  using (public.is_admin() or (dept_id is not null and public.is_head_of(dept_id)) or created_by = auth.uid())
  with check (public.is_admin() or (dept_id is not null and public.is_head_of(dept_id)) or created_by = auth.uid());

-- Kiểm tra sau khi chạy:
-- select policyname, cmd from pg_policies where tablename = 'improvement_projects';
