"""Kiểm thử GĐ5C: 5S."""
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
sc={f"S{g}-{i}":4 for g in range(1,6) for i in range(1,6)};sc["S3-1"]=2;sc["S1-1"]=5
S=json.dumps(sc)
rc,o,e=psql(f"select public.save_5s_audit(null,'{T}',{QAC},'Khu kiểm hàng','{S}',null)",AU,Q);check("QAC KHÔNG tự đánh giá BP mình",rc!=0,e)
bad=dict(sc);bad.pop("S5-5")
rc,o,e=psql(f"select public.save_5s_audit(null,'{T}',{SX},'Line 1','{json.dumps(bad)}',null)",AU,Q);check("Chấm thiếu tiêu chí bị từ chối",rc!=0 and "25" in e,e)
bad=dict(sc);bad["S5-5"]=6
rc,o,e=psql(f"select public.save_5s_audit(null,'{T}',{SX},'Line 1','{json.dumps(bad)}',null)",AU,Q);check("Điểm ngoài 1–5 bị từ chối",rc!=0,e)
rc,o,e=psql(f"select public.save_5s_audit(null,'{TD-datetime.timedelta(8)}',{SX},'Line 1','{S}',null)",AU,Q);check("Ngày quá 7 ngày bị từ chối",rc!=0,e)
rc,o,e=psql(f"select public.save_5s_audit(null,'{T}',{SX},'Line 1 – khu lắp ráp','{S}',null)",AU,Q);aid=o[0] if o else None;check("QAC đánh giá 5S Phòng SX",rc==0,e)
rc,o,e=psql(f"select total from public.fives_audits where id={aid}");check("Tổng điểm % đúng (99/125=79,2%)",o==["79.2"],o)
rc,o,e=psql(f"select public.save_5s_audit({aid},'{T}',{SX},'Line 1 – khu lắp ráp','{S}','sửa')",AU,H);check("Người khác KHÔNG sửa phiếu",rc!=0,e)
rc,o,e=psql(f"select public.add_5s_finding({aid},'S3-1','Sàn dính dầu dưới máy ép','{T}')",AU,Q);fid=o[0] if o else None;check("Người đánh giá ghi lỗi",rc==0,e)
rc,o,e=psql(f"select public.add_5s_finding({aid},'S3-1','x','{T}')",AU,H);check("BP nhận KHÔNG tự ghi lỗi",rc!=0,e)
rc,o,e=psql(f"insert into public.attachments(entity,entity_id,storage_path,uploaded_by) values('fsb',{fid},'fsb/{fid}/1.jpg','{Q}')",AU,Q);check("Người đánh giá tải ảnh trước",rc==0,e)
rc,o,e=psql(f"insert into public.attachments(entity,entity_id,storage_path,uploaded_by) values('fsb',{fid},'fsb/{fid}/2.jpg','{H}')",AU,H);check("BP nhận KHÔNG tải ảnh trước",rc!=0,e)
rc,o,e=psql("select count(*) from public.attachments where entity='fsb'",AU,TT);check("Tổ trưởng SX (BP nhận) xem ảnh trước",o==["1"],o)
rc,o,e=psql("select count(*) from public.attachments where entity='fsb'",AU,K);check("Kho (BP khác) KHÔNG xem ảnh",o==["0"],o)
rc,o,e=psql("select count(*) from public.fives_findings",AU,K);check("Kho KHÔNG xem lỗi 5S của SX",o==["0"],o)
rc,o,e=psql(f"select public.update_5s_finding({fid},'counter','','Tuấn',null,null)",AU,TT);check("Đối sách trống bị từ chối",rc!=0,e)
rc,o,e=psql(f"select public.update_5s_finding({fid},'counter','Thay gioăng, đặt khay hứng dầu','Tuấn',null,null)",AU,TT);check("BP nhận nhập đối sách",rc==0,e)
rc,o,e=psql(f"select public.update_5s_finding({fid},'counter','x','y',null,null)",AU,K);check("BP khác KHÔNG nhập đối sách",rc!=0,e)
rc,o,e=psql(f"select public.update_5s_finding({fid},'request_close','Thay gioăng','Tuấn',null,null)",AU,TT);check("Đề nghị đóng khi chưa có ảnh sau bị từ chối",rc!=0 and "ảnh" in e,e)
rc,o,e=psql(f"insert into public.attachments(entity,entity_id,storage_path,uploaded_by) values('fsa',{fid},'fsa/{fid}/1.jpg','{TT}')",AU,TT);check("BP nhận tải ảnh sau",rc==0,e)
rc,o,e=psql(f"select public.update_5s_finding({fid},'request_close','Thay gioăng','Tuấn',null,null)",AU,TT);check("Đề nghị đóng",rc==0,e)
rc,o,e=psql(f"select public.update_5s_finding({fid},'close',null,null,null,'OK')",AU,TT);check("BP nhận KHÔNG tự đóng",rc!=0,e)
rc,o,e=psql(f"select public.update_5s_finding({fid},'reopen',null,null,null,'')",AU,Q);check("Trả lại phải có lý do",rc!=0,e)
rc,o,e=psql(f"select public.update_5s_finding({fid},'close',null,null,null,'Đã kiểm tra')",AU,Q);check("Người đánh giá xác nhận đóng",rc==0,e)
rc,o,e=psql(f"select status from public.fives_findings where id={fid}");check("Trạng thái Đã đóng",o==["closed"],o)
rc,o,e=psql(f"insert into public.attachments(entity,entity_id,storage_path,uploaded_by) values('fsa',{fid},'fsa/{fid}/2.jpg','{TT}')",AU,TT);check("Lỗi đã đóng KHÔNG thêm ảnh",rc!=0,e)
rc,o,e=psql(f"select public.add_5s_finding({aid},'S2-1','Lối đi bị lấn','{TD-datetime.timedelta(1)}')",AU,Q);check("Hạn trước ngày đánh giá bị từ chối",rc!=0,e)
psql(f"update public.fives_audits set audit_date='{TD-datetime.timedelta(3)}' where id={aid}")
rc,o,e=psql(f"select public.add_5s_finding({aid},'S2-1','Lối đi bị lấn','{TD-datetime.timedelta(1)}')",AU,Q);check("Ghi lỗi thứ 2",rc==0,e)
rc,o,e=psql(f"select dept_name,audits,last_total,open_findings,overdue_findings,closed_findings,by_group->>'S3' from public.fives_board('{TD-datetime.timedelta(6)}','{T}') where audits>0",AU,K)
check("Bảng điểm công khai: SX 79,2% · 1 lỗi mở quá hạn · 1 đóng · S3=72%",o==["Phòng Sản xuất|1|79.2|1|1|1|72"],o)
rc,o,e=psql(f"select count(*) from public.fives_board('{T}','{T}')",AU,K);check("Bảng điểm có đủ 10 BP",o==["10"],o)
print(f"\n{sum(res)}/{len(res)} PASS")
