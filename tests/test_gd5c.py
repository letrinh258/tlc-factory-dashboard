"""Kiểm thử GĐ5C: 3S."""
import subprocess, uuid, re, datetime, json
D="/var/tmp/tlcpg"
def psql(sql, role=None, uid=None):
    pre=f"set role {role}; select set_config('request.jwt.claim.sub','{uid}',false); " if role else ""
    r=subprocess.run(["psql","-h",D,"-p","5433","-U","postgres","-d","tlc","-At","-v","ON_ERROR_STOP=1","-c",pre+sql],capture_output=True,text=True)
    out=[l for l in r.stdout.strip().split("\n") if l and l!="SET" and l!=uid and not re.match(r"^(UPDATE|DELETE|INSERT) \d+( \d+)?$",l)]
    return r.returncode,out,r.stderr.strip()
res=[]
def check(n,ok,d=""): res.append(ok); print(("PASS " if ok else "FAIL ")+n+("" if ok else f"  [{d}]"))
rc,o,e=psql("delete from public.attachments; delete from public.fives_findings; delete from public.fives_audits; delete from public.wh_entries; delete from public.quality_reports; delete from public.maintenance_reports; delete from public.hr_reports; delete from public.report_unlocks; delete from public.production_reports; delete from public.user_lines; delete from public.item_updates; delete from public.task_updates; delete from public.task_assignments; delete from public.tasks; delete from public.issues; delete from public.daily_reports; update public.positions set status='on',status_from=null,status_to=null,acting_profile_id=null; delete from public.position_history; delete from public.profiles; delete from auth.users;")
assert rc==0,e
U={}
for u,pos,role in [("trinhlh","GDNM","admin"),("ducmv","NV-QAC","staff"),("hungnv","TBP-SX","head"),("tuanlv","TT-SX","staff"),("hapt","TKTP","staff")]:
    i=str(uuid.uuid4());U[u]=i
    rc,o,e=psql(f"insert into auth.users(id,email) values('{i}','{u}@tlc.local'); insert into public.profiles(id,username,full_name,dept_id,position_id,role,must_change_pw) select '{i}','{u}','{u}',dept_id,id,'{role}',false from public.positions where code='{pos}'"); assert rc==0,e
A,Q,H,TT,K=[U[x] for x in ["trinhlh","ducmv","hungnv","tuanlv","hapt"]];AU="authenticated"
rc,o,e=psql("select public.tlc_today()");T=o[0];TD=datetime.date.fromisoformat(T)
SX=psql("select public.dept_id_of('SX')")[2] or psql("select public.dept_id_of('SX')")[1][0];QAC=psql("select public.dept_id_of('QAC')")[1][0]
def add(uid,dept,s,desc="Lỗi",due=None,d=None,area="Line 1"):
    return psql(f"select public.add_3s_finding('{d or T}',{dept},'{area}','{s}','{desc}','{due or T}')",AU,uid)
rc,o,e=add(Q,QAC,"S1");check("QAC KHÔNG tự ghi lỗi BP mình",rc!=0,e)
rc,o,e=add(Q,SX,"S4");check("Chỉ nhận S1/S2/S3",rc!=0,e)
rc,o,e=add(Q,SX,"S1",d=str(TD-datetime.timedelta(8)));check("Ngày quá 7 ngày bị từ chối",rc!=0,e)
rc,o,e=add(Q,SX,"S3",desc="",);check("Thiếu mô tả bị từ chối",rc!=0,e)
rc,o,e=add(Q,SX,"S3","Sàn dính dầu dưới máy ép");f1=o[0] if o else None;check("QAC ghi lỗi Sạch sẽ cho SX",rc==0,e)
rc,o,e=add(Q,SX,"S2","Thùng linh kiện không nhãn");f2=o[0] if o else None
rc,o,e=add(Q,SX,"S2","Lối đi bị lấn",area="Line 2");f3=o[0] if o else None
rc,o,e=add(Q,SX,"S1","Phế liệu chưa dọn");f4=o[0] if o else None
rc,o,e=psql("select count(*) from public.fives_audits");check("Gom phiên theo ngày × BP × khu vực (2 phiên)",o==["2"],o)
rc,o,e=psql(f"insert into public.attachments(entity,entity_id,storage_path,uploaded_by) values('fsb',{f1},'fsb/{f1}/1.jpg','{Q}')",AU,Q);check("Người ghi tải 1 ảnh",rc==0,e)
rc,o,e=psql(f"insert into public.attachments(entity,entity_id,storage_path,uploaded_by) values('fsb',{f1},'fsb/{f1}/2.jpg','{Q}')",AU,Q);check("Ảnh thứ 2 cho 1 lỗi bị từ chối",rc!=0 and "1 ảnh" in e,e)
rc,o,e=psql(f"insert into public.attachments(entity,entity_id,storage_path,uploaded_by) values('fsb',{f2},'fsb/{f2}/1.jpg','{H}')",AU,H);check("BP nhận KHÔNG tải ảnh lỗi",rc!=0,e)
rc,o,e=psql("select count(*) from public.attachments where entity='fsb'",AU,TT);check("BP nhận xem ảnh lỗi",o==["1"],o)
rc,o,e=psql("select count(*) from public.fives_findings",AU,K);check("BP khác KHÔNG xem chi tiết lỗi",o==["0"],o)
rc,o,e=psql(f"select public.update_5s_finding({f1},'counter','','Tuấn',null,null)",AU,TT);check("Đối sách trống bị từ chối",rc!=0,e)
rc,o,e=psql(f"select public.update_5s_finding({f1},'request_close','Đặt khay hứng dầu','Tuấn',null,null)",AU,TT);check("BP nhận đề nghị đóng (không cần ảnh sau)",rc==0,e)
rc,o,e=psql(f"select public.update_5s_finding({f1},'close',null,null,null,'OK')",AU,TT);check("BP nhận KHÔNG tự đóng",rc!=0,e)
rc,o,e=psql(f"select public.update_5s_finding({f1},'reopen',null,null,null,'')",AU,Q);check("Trả lại phải có lý do",rc!=0,e)
rc,o,e=psql(f"select public.update_5s_finding({f1},'close',null,null,null,'Đã kiểm tra')",AU,Q);check("Người ghi xác nhận đóng",rc==0,e)
rc,o,e=psql(f"select public.update_5s_finding({f4},'delete',null,null,null,null)",AU,Q);check("Người ghi xóa lỗi ghi nhầm",rc==0,e)
psql(f"update public.fives_findings set due_date='{TD-datetime.timedelta(1)}' where id={f3}")
rc,o,e=psql(f"select dept_name,s1,s2,s3,total,open_findings,overdue_findings,closed_findings,no_photo from public.fives_board('{TD-datetime.timedelta(6)}','{T}') where total>0",AU,K)
check("Thống kê công khai: SX S1=0 S2=2 S3=1 · 2 mở · 1 quá hạn · 1 đóng · 2 thiếu ảnh",o==["Phòng Sản xuất|0|2|1|3|2|1|1|2"],o)
rc,o,e=psql(f"select count(*) from public.fives_board('{T}','{T}')",AU,K);check("Bảng có đủ 10 BP",o==["10"],o)
rc,o,e=psql(f"insert into public.attachments(entity,entity_id,storage_path,uploaded_by) values('fsb',{f1},'fsb/{f1}/3.jpg','{Q}')",AU,Q);check("Lỗi đã đóng KHÔNG thay ảnh",rc!=0,e)
print(f"\n{sum(res)}/{len(res)} PASS")
