"""Kiểm thử Giai đoạn 4: báo cáo ngày, mục 3, khóa 23:59, giao việc, ảnh, phân quyền."""
import subprocess, uuid, sys, re, datetime
D = "/var/tmp/tlcpg"
def psql(sql, role=None, uid=None):
    pre = ""
    if role:
        pre = f"set role {role}; " + (f"select set_config('request.jwt.claim.sub','{uid}',false); " if uid else "")
    r = subprocess.run(["psql", "-h", D, "-p", "5433", "-U", "postgres", "-d", "tlc", "-At", "-v", "ON_ERROR_STOP=1", "-c", pre + sql], capture_output=True, text=True)
    out = [l for l in r.stdout.strip().split("\n") if l and l != "SET" and not (uid and l == uid) and not re.match(r"^(UPDATE|DELETE|INSERT) \d+( \d+)?$", l)]
    return r.returncode, out, r.stderr.strip()
res = []
def check(name, ok, detail=""):
    res.append((name, ok)); print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"  [{detail}]"))

rc, o, e = psql("delete from public.attachments; delete from public.item_updates; delete from public.report_unlocks; delete from public.support_requests; delete from public.plan_items;"
                "delete from public.task_updates; delete from public.task_assignments; delete from public.tasks; delete from public.issues; delete from public.daily_reports; delete from public.code_counters;"
                "delete from public.inventory_reports; delete from public.production_reports;"
                "update public.positions set status='on',status_from=null,status_to=null,acting_profile_id=null; delete from public.position_history;"
                "delete from public.profiles; delete from auth.users;")
assert rc == 0, e
U = {}
for u, n, pos, role in [("trinhlh","Lê Hùng Trình","GDNM","admin"),("sangnt","Nguyễn Thị Sáng","TBP-KHSX","head"),("hapt","Phạm Thu Hà","TKTP","staff"),
                        ("haipv","Phan Văn Hải","TBP-KHO","head"),("ducmv","Mai Văn Đức","NV-QAC","staff")]:
    i = str(uuid.uuid4()); U[u] = i
    rc, o, e = psql(f"insert into auth.users(id,email) values('{i}','{u}@tlc.local'); insert into public.profiles(id,username,full_name,dept_id,position_id,role,must_change_pw) select '{i}','{u}','{n}',dept_id,id,'{role}',false from public.positions where code='{pos}'")
    assert rc == 0, e
A, S, H, K, M = U["trinhlh"], U["sangnt"], U["hapt"], U["haipv"], U["ducmv"]
AU = "authenticated"; T = datetime.date.today(); Y = T - datetime.timedelta(1)
# tlc_today() theo giờ VN có thể lệch ngày với máy test → lấy từ DB
rc, o, e = psql("select public.tlc_today()"); T = datetime.date.fromisoformat(o[0]); Y = T - datetime.timedelta(1); TM = T + datetime.timedelta(1)
yymmdd = T.strftime("%y%m%d"); ddmm = T.strftime("%d%m")

rc, o, e = psql("select array_to_string(public.my_report_codes(),',')", AU, S); check("TBP KHSX được nhập báo cáo KHSX", o == ["KHSX"], o)
rc, o, e = psql("select array_to_string(public.my_report_codes(),',')", AU, H); check("Thủ kho TP được nhập báo cáo TKTP", o == ["TKTP"], o)
rc, o, e = psql("select coalesce(array_to_string(public.my_report_codes(),','),'')", AU, K); check("Trưởng kho không có báo cáo riêng", o in ([""], []), o)

rc, o, e = psql(f"select public.touch_report('KHSX','{T}') > 0", AU, S); check("Mở báo cáo ngày hôm nay của vị trí mình", o == ["t"], e)
rc, o, e = psql(f"select public.touch_report('KHSX','{T}')", AU, H); check("KHÔNG nhập vào báo cáo của vị trí khác", rc != 0, e)
rc, o, e = psql(f"update public.daily_reports set metrics='{{\"kh_sl\":1920,\"th_nk\":1850}}' where report_code='KHSX' and report_date='{T}' returning id", AU, S)
check("Lưu số liệu mục 1", len(o) == 1, e)

# Mục 2
rc, o, e = psql(f"select public.next_code('KHSX-{yymmdd}-')", AU, S); code1 = o[0] if o else ""
check("Sinh mã vấn đề KHSX-yymmdd-01", code1 == f"KHSX-{yymmdd}-01", o)
rc, o, e = psql(f"insert into public.issues(code,report_code,open_date,description,severity,created_by) values('{code1}','KHSX','{T}','Thiếu nguồn 8-12W','red','{S}')", AU, S)
check("Vấn đề Đỏ thiếu phương án B bị từ chối", rc != 0, e)
rc, o, e = psql(f"insert into public.issues(code,report_code,open_date,description,severity,plan_b,owner_name,due_date,created_by) values('{code1}','KHSX','{T}','Thiếu nguồn 8-12W','red','Dùng mã thay thế','Sáng','{TM}','{S}') returning id", AU, S)
iss = o[0] if o else None; check("Ghi vấn đề Đỏ có phương án B", rc == 0 and iss, e)
rc, o, e = psql("select count(*) from public.issues", AU, H); check("Thủ kho KHÔNG thấy vấn đề của KHSX", o == ["0"], o)
rc, o, e = psql("select count(*) from public.issues", AU, K); check("Trưởng kho (BP khác) KHÔNG thấy vấn đề của KHSX", o == ["0"], o)
rc, o, e = psql("select count(*) from public.issues", AU, A); check("GĐNM thấy vấn đề", o == ["1"], o)

# Mục 4
rc, o, e = psql(f"insert into public.plan_items(code,report_code,report_date,plan_date,content,priority,ready,due_date) values('KHSX-{yymmdd}-K01','KHSX','{T}','{TM}','Ra lệnh SX tuần 46','1-Cao','Thiếu','{TM}') returning id", AU, S)
plan = o[0] if o else None; check("Ghi kế hoạch ngày mai", rc == 0 and plan, e)

# Giao việc
rc, o, e = psql(f"select public.next_code('CĐ{ddmm}-')", AU, A); cd = o[0]
rc, o, e = psql(f"insert into public.tasks(code,kind,source,title,content,objective,report_code,dept_id,assigner_id,due_date) values('{cd}','CĐ','Chỉ đạo Cố vấn','Rà soát định mức 20 mã','Rà soát định mức 20 mã lớn','Báo cáo chênh lệch','KHSX',4,'{A}','{T + datetime.timedelta(2)}') returning id", AU, A)
tk = o[0] if o else None; check(f"GĐNM ra chỉ đạo {cd}", rc == 0 and tk, e)
rc, o, e = psql(f"insert into public.tasks(code,kind,title,report_code,dept_id,assigner_id,due_date) values('GVX','GV','x','TKTP',5,'{H}','{TM}')", AU, H)
check("Nhân viên KHÔNG giao việc được", rc != 0, e)

rc, o, e = psql(f"select entity||':'||code from public.report_section3('KHSX','{T}')", AU, S)
check("Mục 3 hôm nay có chỉ đạo mới (vấn đề hôm nay chưa chuyển)", o == [f"task:{cd}"], o)
rc, o, e = psql(f"select string_agg(entity,',' order by entity) from public.report_section3('KHSX','{TM}')", AU, S)
check("Mục 3 ngày mai tự có: việc + vấn đề mục 2 + kế hoạch mục 4", o == ["issue,plan,task"], o)
rc, o, e = psql(f"select count(*) from public.report_section3('KHSX','{T}')", AU, H)
check("Vị trí khác KHÔNG đọc được mục 3 của KHSX", o == ["0"], o)

rc, o, e = psql(f"select public.save_update('task',{tk},'KHSX','{T}',50,'Đã rà 10 mã',null,'Rà tiếp 10 mã','doing',null)", AU, S)
check("Cập nhật tiến độ chỉ đạo trong ngày", rc == 0, e)
rc, o, e = psql(f"select public.save_update('task',{tk},'KHSX','{T}',60,'x',null,'y','doing',null)", AU, H)
check("Người khác KHÔNG cập nhật được", rc != 0, e)
rc, o, e = psql(f"insert into public.item_updates(entity,entity_id,report_code,update_date,progress) values('task',{tk},'KHSX','{T}',90)", AU, S)
check("KHÔNG ghi thẳng vào bảng cập nhật (phải qua kiểm tra)", rc != 0, e)

# Quá hạn
psql(f"update public.tasks set due_date='{Y}' where id={tk}")
rc, o, e = psql(f"select overdue from public.report_section3('KHSX','{T}') where entity='task'", AU, S)
check("Việc qua hạn tự chuyển QUÁ HẠN ở mục 3", o == ["t"], o)
rc, o, e = psql(f"select public.save_update('task',{tk},'KHSX','{T}',70,'Đã rà 14 mã',null,null,'doing',null)", AU, S)
check("Việc quá hạn: thiếu hạn mới + lý do bị từ chối", rc != 0 and "quá hạn" in e, e)
rc, o, e = psql(f"select public.save_update('task',{tk},'KHSX','{T}',70,'Đã rà 14 mã','{TM}','Chờ số liệu Bravo','doing',null)", AU, S)
rc2, o2, e2 = psql(f"select due_date||'|'||requested_due from public.tasks where id={tk}", AU, A)
check("Xin lùi hạn: hạn chưa đổi, chờ người giao duyệt", rc == 0 and o2 == [f"{Y}|{TM}"], (e, o2))
rc, o, e = psql(f"select public.task_decide({tk},'approve_due',null)", AU, S); check("Người phụ trách KHÔNG tự duyệt hạn", rc != 0, e)
rc, o, e = psql(f"select public.task_decide({tk},'approve_due',null)", AU, A)
rc2, o2, e2 = psql(f"select due_date||'|'||original_due from public.tasks where id={tk}", AU, A)
check("GĐNM duyệt hạn mới, giữ hạn ban đầu", o2 == [f"{TM}|{Y}"], (e, o2))
rc, o, e = psql("select count(*) from public.my_alerts() where kind='approve_due'", AU, A); check("Hết thông báo chờ duyệt hạn", o == ["0"], o)

# Khóa sau 23:59
rc, o, e = psql(f"select public.touch_report('KHSX','{Y}')", AU, S); check("Báo cáo hôm qua đã KHÓA", rc != 0 and "khóa" in e, e)
rc, o, e = psql(f"select public.unlock_report('KHSX','{Y}',2,'x')", AU, A); check("Mở khóa phải ghi lý do", rc != 0, e)
rc, o, e = psql(f"select public.unlock_report('KHSX','{Y}',2,'Bổ sung số liệu')", AU, S); check("TBP KHÔNG tự mở khóa", rc != 0, e)
rc, o, e = psql(f"select public.unlock_report('KHSX','{Y}',2,'Bổ sung số liệu')", AU, A)
rc, o, e = psql(f"select public.touch_report('KHSX','{Y}') > 0", AU, S); check("GĐNM mở khóa → sửa được trong thời hạn", o == ["t"], e)

# Tiếp nhận + đóng việc
rc, o, e = psql(f"select public.next_code('GV{ddmm}-')", AU, A); gv = o[0]
rc, o, e = psql(f"insert into public.tasks(code,kind,title,report_code,dept_id,assigner_id,due_date) values('{gv}','GV','Đối chiếu tồn TP 5 mã','TKTP',5,'{A}','{TM}') returning id", AU, A); tk2 = o[0]
rc, o, e = psql("select count(*) from public.my_alerts() where kind='task_new'", AU, H); check("Thủ kho nhận thông báo việc mới", o == ["1"], o)
rc, o, e = psql(f"select public.accept_task({tk2})", AU, S); check("Người khác KHÔNG tiếp nhận hộ", rc != 0, e)
rc, o, e = psql(f"select public.accept_task({tk2})", AU, H); check("Người nhận tiếp nhận việc", rc == 0, e)
rc, o, e = psql(f"select public.save_update('task',{tk2},'TKTP','{T}',100,'Đã đối chiếu xong 5 mã',null,null,'pending_confirm','{T}')", AU, H)
check("Báo hoàn thành → Đề nghị đóng", rc == 0, e)
rc, o, e = psql(f"select public.task_decide({tk2},'close','ok')", AU, H); check("Người phụ trách KHÔNG tự đóng việc", rc != 0, e)
rc, o, e = psql(f"select public.task_decide({tk2},'close','')", AU, A); check("Đóng việc phải ghi kết quả xác nhận", rc != 0, e)
rc, o, e = psql(f"select public.task_decide({tk2},'close','Khớp Bravo')", AU, A)
rc2, o2, e2 = psql(f"select status from public.tasks where id={tk2}", AU, A); check("GĐNM đóng việc", o2 == ["done"], (e, o2))

# Mục 5
rc, o, e = psql(f"insert into public.support_requests(report_code,report_date,kind,content,proposal) values('KHSX','{T}','Quyết định','Cho tăng ca Line 2','Tăng ca 2h, nếu không trễ đơn ĐH-10/118') returning id", AU, S)
sr = o[0] if o else None; check("Ghi nội dung cần quyết định", rc == 0 and sr, e)
rc, o, e = psql(f"update public.support_requests set decision='Đồng ý', status='Đã quyết định' where id={sr} returning id", AU, S)
check("Người đề xuất KHÔNG tự ghi quyết định", rc != 0 or o == [], (o, e))
rc, o, e = psql(f"update public.support_requests set decision='Đồng ý tăng ca 2h', status='Đã quyết định', decider='GĐNM', decided_date='{T}' where id={sr} returning id", AU, A)
check("GĐNM ghi quyết định", o == [sr], e)
rc, o, e = psql("select count(*) from public.my_alerts() where kind='decided'", AU, S); check("Người đề xuất nhận thông báo đã có quyết định", o == ["1"], o)

# Ảnh: tối đa 3 / việc, xóa ảnh không xóa việc
for k in range(3):
    rc, o, e = psql(f"insert into public.attachments(entity,entity_id,storage_path,uploaded_by) values('task',{tk},'task/{tk}/a{k}.jpg','{S}')", AU, S)
check("Thêm 3 ảnh minh chứng", rc == 0, e)
rc, o, e = psql(f"insert into public.attachments(entity,entity_id,storage_path,uploaded_by) values('task',{tk},'task/{tk}/a4.jpg','{S}')", AU, S)
check("Ảnh thứ 4 bị từ chối", rc != 0 and "3 ảnh" in e, e)
rc, o, e = psql(f"insert into public.attachments(entity,entity_id,storage_path,uploaded_by) values('task',{tk},'task/{tk}/x.jpg','{H}')", AU, H)
check("Người không liên quan KHÔNG thêm ảnh", rc != 0, e)
rc, o, e = psql(f"delete from public.attachments where storage_path='task/{tk}/a0.jpg' returning id", AU, S)
rc2, o2, e2 = psql(f"select count(*) from public.tasks where id={tk}", AU, A)
check("Xóa ảnh, việc vẫn còn nguyên", len(o) == 1 and o2 == ["1"], (o, o2))

# Tổng hợp + kiêm nhiệm
rc, o, e = psql(f"select count(*), sum(case when entered then 1 else 0 end) from public.daily_summary('{T}')", AU, A)
check("Tổng hợp 15 vị trí cho GĐNM, đếm vị trí đã nhập", o == ["15|2"], o)
rc, o, e = psql(f"select string_agg(report_code,',') from public.daily_summary('{T}')", AU, S); check("TBP chỉ thấy vị trí của bộ phận mình (KHSX, KHVT)", o == ["KHSX,KHVT"], o)
psql(f"update public.positions set status='vacant', status_from='{T}', acting_profile_id='{H}' where code='TBP-KHSX'")
rc, o, e = psql("select array_to_string(public.my_report_codes(),',')", AU, H); check("Người kiêm nhiệm nhập thay báo cáo KHSX", sorted(o[0].split(",")) == ["KHSX","TKTP"], o)
rc, o, e = psql("select coalesce(array_to_string(public.my_report_codes(),','),'')", AU, S); check("TBP vắng mất quyền nhập", o in ([""], []), o)
psql("update public.positions set status='on', status_from=null, acting_profile_id=null where code='TBP-KHSX'")

print(f"\n{sum(1 for r in res if r[1])}/{len(res)} PASS")
open("/home/claude/gd4/ket_qua_test_gd4.txt", "w").write("\n".join(("PASS " if r[1] else "FAIL ") + r[0] for r in res) + f"\n\nTổng: {sum(1 for r in res if r[1])}/{len(res)} PASS\n")
sys.exit(0 if all(r[1] for r in res) else 1)
