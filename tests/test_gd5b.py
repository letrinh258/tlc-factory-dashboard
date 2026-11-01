"""Kiểm thử GĐ5B: định mức trong Cấu hình, form QAC / Cơ điện / Kho / HCNS, đối chiếu."""
import subprocess, uuid, re, datetime, json
D="/var/tmp/tlcpg"
def psql(sql, role=None, uid=None):
    pre=f"set role {role}; select set_config('request.jwt.claim.sub','{uid}',false); " if role else ""
    r=subprocess.run(["psql","-h",D,"-p","5433","-U","postgres","-d","tlc","-At","-v","ON_ERROR_STOP=1","-c",pre+sql],capture_output=True,text=True)
    out=[l for l in r.stdout.strip().split("\n") if l and l!="SET" and l!=uid and not re.match(r"^(UPDATE|DELETE|INSERT) \d+( \d+)?$",l)]
    return r.returncode,out,r.stderr.strip()
res=[]
def check(n,ok,d=""): res.append(ok); print(("PASS " if ok else "FAIL ")+n+("" if ok else f"  [{d}]"))
rc,o,e=psql("delete from public.norm_changes; update public.products set norm_manual=false; delete from public.wh_entries; delete from public.quality_reports; delete from public.maintenance_reports; delete from public.hr_reports; delete from public.report_unlocks; delete from public.production_reports; delete from public.user_lines; delete from public.attachments; delete from public.item_updates; delete from public.task_updates; delete from public.task_assignments; delete from public.tasks; delete from public.issues; delete from public.daily_reports; update public.positions set status='on',status_from=null,status_to=null,acting_profile_id=null; delete from public.position_history; delete from public.profiles; delete from auth.users;")
assert rc==0,e
U={}
for u,pos,role in [("trinhlh","GDNM","admin"),("hungnv","TBP-SX","head"),("tuanlv","TT-SX","staff"),("ducmv","NV-QAC","staff"),("namcd","NV-CD","staff"),("hapt","TKTP","staff"),("linhns","NV-HCNS","staff"),("sangnt","TBP-KHSX","head")]:
    i=str(uuid.uuid4());U[u]=i
    rc,o,e=psql(f"insert into auth.users(id,email) values('{i}','{u}@tlc.local'); insert into public.profiles(id,username,full_name,dept_id,position_id,role,must_change_pw) select '{i}','{u}','{u}',dept_id,id,'{role}',false from public.positions where code='{pos}'"); assert rc==0,e
A,H,TT,Q,CD,K,NS,KH=[U[x] for x in ["trinhlh","hungnv","tuanlv","ducmv","namcd","hapt","linhns","sangnt"]];AU="authenticated"
rc,o,e=psql("select public.tlc_today()");T=o[0];Y=str(datetime.date.fromisoformat(T)-datetime.timedelta(1))
P1="TLC-AMC-VV-07W-04"
# Định mức
items=json.dumps([{"code":P1,"norm":150},{"code":"KHONG-CO","norm":10},{"code":"TLACB/12W04","norm":-1}]).replace("'","''")
rc,o,e=psql(f"select public.set_norms('{items}','Rà lại theo thực tế')",AU,H);check("TBP SX KHÔNG sửa định mức",rc!=0,e)
rc,o,e=psql(f"select public.set_norms('{items}','Rà lại theo thực tế')",AU,A);r=json.loads(o[0]) if o else {}
check("GĐNM sửa định mức: 1 lưu, 2 báo lỗi",r.get("saved")==1 and len(r.get("errors",[]))==2,o)
rc,o,e=psql(f"select norm_per_hour,norm_manual from public.products where code='{P1}'");check("Định mức mới 150, đánh dấu sửa tay",o==["150|t"],o)
rc,o,e=psql("select old_norm,new_norm,note from public.norm_changes");check("Có lịch sử thay đổi",o==["181|150|Rà lại theo thực tế"],o)
rc,o,e=psql("select count(*) from public.norm_changes",AU,H);check("Chỉ GĐNM xem lịch sử định mức",o==["0"],o)
rc,o,e=psql("select 1",None);rc,o,e=subprocess.run(["psql","-h",D,"-p","5433","-U","postgres","-d","tlc","-q","-v","ON_ERROR_STOP=1","-f","/home/claude/gd5/03b_products.sql"],capture_output=True,text=True).returncode,0,0
rc,o,e=psql(f"select norm_per_hour from public.products where code='{P1}'");check("Nạp lại file Bravo KHÔNG ghi đè định mức sửa tay",o==["150"],o)
items=json.dumps([{"code":P1,"norm":None}])
rc,o,e=psql(f"select public.set_norms('{items}','Xóa')",AU,A);rc,o,e=psql(f"select coalesce(norm_per_hour::text,'null') from public.products where code='{P1}'");check("Xóa định mức → dùng mặc định",o==["null"],o)
psql(f"select public.set_norms('[{{\"code\":\"{P1}\",\"norm\":181}}]','Trả lại')",AU,A)

# SX nền
psql(f"insert into public.user_lines values('{TT}',1)")
psql(f"select public.save_prod_row('{T}',1,'{P1}',1000,950,5,3,1,4,12,8,1,40,'Hỏng máy / thiết bị',null)",AU,TT)
# QAC
df=json.dumps([{"type":1,"qty":5},{"type":4,"qty":1}])
rc,o,e=psql(f"select public.save_qc('{T}','PQC',1,'{P1}',null,null,958,2,'{df}',null)",AU,Q);check("QAC lưu PQC line 1",rc==0,e)
rc,o,e=psql(f"select public.save_qc('{T}','PQC',1,'{P1}',null,null,958,2,'{df}','sửa')",AU,Q);rc,o,e=psql("select count(*),sum((select count(*) from public.quality_defects d where d.report_id=q.id)) from public.quality_reports q");check("Lưu lại = sửa, không nhân đôi",o==["1|2"],o)
rc,o,e=psql(f"select public.save_qc('{T}','PQC',1,'{P1}',null,null,3,0,'{df}',null)",AU,Q);check("Tổng lỗi > số kiểm bị từ chối",rc!=0,e)
rc,o,e=psql(f"select public.save_qc('{T}','IQC',null,null,'',null,100,0,'[]',null)",AU,Q);check("IQC thiếu mã vật tư bị từ chối",rc!=0,e)
rc,o,e=psql(f"select public.save_qc('{T}','IQC',null,null,'D01105101705','NCC Rạng Đông',500,0,'[{{\"type\":5,\"qty\":2}}]',null)",AU,Q);check("QAC lưu IQC vật tư",rc==0,e)
rc,o,e=psql(f"select public.save_qc('{T}','PQC',1,'{P1}',null,null,958,0,'[]',null)",AU,K);check("Kho KHÔNG nhập form QAC",rc!=0,e)
rc,o,e=psql(f"select public.save_qc('{Y}','PQC',1,'{P1}',null,null,958,0,'[]',null)",AU,Q);check("QAC KHÔNG nhập ngày đã khóa",rc!=0,e)
rc,o,e=psql("insert into public.quality_reports(report_date,stage,inspected) values(current_date,'IQC',1)",AU,Q);check("KHÔNG ghi thẳng bảng QAC",rc!=0,e)
# Cơ điện
rc,o,e=psql(f"select public.save_mt(null,'{T}',1,'Máy hàn sóng','breakdown','09:10','09:35','Đứt dây curoa','Thay dây','Dây curoa B42')",AU,CD);check("Cơ điện lưu sự cố line 1",rc==0,e)
rc,o,e=psql("select downtime_min from public.maintenance_reports");check("Tự tính 25 phút dừng máy",o==["25"],o)
rc,o,e=psql(f"select public.save_mt(null,'{T}',1,'Máy hàn','breakdown','10:00','09:00','x',null,null)",AU,CD);check("Giờ kết thúc trước giờ bắt đầu bị từ chối",rc!=0,e)
rc,o,e=psql(f"select public.save_mt(null,'{T}',1,'Máy hàn','breakdown','10:00',null,'',null,null)",AU,CD);check("Sự cố thiếu nguyên nhân bị từ chối",rc!=0,e)
rc,o,e=psql(f"select public.save_mt(null,'{T}',1,'Máy hàn','breakdown','10:00',null,'x',null,null)",AU,TT);check("Tổ trưởng KHÔNG nhập form Cơ điện",rc!=0,e)
# Kho
rc,o,e=psql(f"select public.save_wh(null,'{T}','TP','receipt_sx',1,'{P1}',900,'PNK-001',null,null)",AU,K);check("Kho TP nhận 900 từ line 1",rc==0,e)
rc,o,e=psql(f"select public.save_wh(null,'{T}','TP','receipt_sx',1,'KHONG-CO',9,null,null,null)",AU,K);check("Mã TP không có bị từ chối",rc!=0,e)
rc,o,e=psql(f"select public.save_wh(null,'{T}','LK','shortage',2,'D01105101705',300,'LSX-46',(current_date+2),'NCC giao trễ')",AU,K);check("Kho LK ghi thiếu vật tư",rc==0,e)
rc,o,e=psql(f"select public.save_wh(null,'{T}','TP','shortage',null,'X',1,null,null,null)",AU,K);check("Sai loại phiếu theo kho bị từ chối",rc!=0,e)
rc,o,e=psql("select count(*) from public.wh_entries",AU,KH);check("KHSX xem phiếu kho",o==["2"],o)
rc,o,e=psql("select count(*) from public.wh_entries",AU,NS);check("HCNS KHÔNG xem phiếu kho",o==["0"],o)
# HCNS
rc,o,e=psql(f"select public.save_hr('{T}',320,300,2,1,5,null)",AU,NS);check("HCNS lưu nhân lực",rc==0,e)
rc,o,e=psql("select absent from public.hr_reports");check("Tự tính vắng 20",o==["20"],o)
rc,o,e=psql(f"select public.save_hr('{T}',320,330,0,0,0,null)",AU,NS);check("Đi làm > định biên bị từ chối",rc!=0,e)
rc,o,e=psql(f"select public.save_hr('{T}',320,300,0,0,0,null)",AU,K);check("Kho KHÔNG nhập form HCNS",rc!=0,e)
# Mở khóa form
rc,o,e=psql(f"select public.unlock_report('FORM-KHO','{Y}',2,'Bổ sung phiếu nhập')",AU,A)
rc,o,e=psql(f"select public.save_wh(null,'{Y}','TP','receipt_sx',1,'{P1}',100,null,null,null)",AU,K);check("GĐNM mở khóa form Kho ngày qua → nhập bù được",rc==0,e)
# Đối chiếu
rc,o,e=psql(f"select flow,line_id,qty_a,qty_b,diff,flagged from public.recon('{T}')",AU,H)
dd={x.split("|")[0]:x for x in o}
check("SX 950 ↔ Kho TP 900: lệch -50, cảnh báo",dd.get("SX → Kho TP")=="SX → Kho TP|1|950|900|-50|t",o)
check("NG thao tác SX 5 ↔ QAC 5: khớp",dd.get("NG thao tác: SX ↔ QAC")=="NG thao tác: SX ↔ QAC|1|5|5|0|f",o)
check("NG NCC SX 3 ↔ QAC 1: lệch nhỏ, chưa cảnh báo",dd.get("NG NCC: SX ↔ QAC")=="NG NCC: SX ↔ QAC|1|3|1|-2|f",o)
check("Dừng máy SX 40' ↔ CĐ 25': lệch 15, chưa vượt ngưỡng",dd.get("Dừng máy: SX ↔ Cơ điện","").endswith("|1|40|25|-15|f"),o)
rc,o,e=psql(f"select count(*) from public.recon('{T}')",AU,NS);check("HCNS KHÔNG xem đối chiếu",o==["0"],o)
rc,o,e=psql("select count(*) from public.audit_logs where table_name in ('wh_entries','quality_reports','maintenance_reports','hr_reports')");check("Có nhật ký thay đổi",int(o[0])>=5,o)
print(f"\n{sum(res)}/{len(res)} PASS")
