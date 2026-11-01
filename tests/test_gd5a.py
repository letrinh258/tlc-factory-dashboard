"""Kiểm thử GĐ5A: Form A báo cáo SX theo line."""
import subprocess, uuid, re, datetime
D = "/var/tmp/tlcpg"
def psql(sql, role=None, uid=None):
    pre = f"set role {role}; select set_config('request.jwt.claim.sub','{uid}',false); " if role else ""
    r = subprocess.run(["psql","-h",D,"-p","5433","-U","postgres","-d","tlc","-At","-v","ON_ERROR_STOP=1","-c",pre+sql],capture_output=True,text=True)
    out=[l for l in r.stdout.strip().split("\n") if l and l!="SET" and l!=uid and not re.match(r"^(UPDATE|DELETE|INSERT) \d+( \d+)?$",l)]
    return r.returncode,out,r.stderr.strip()
res=[]
def check(n,ok,d=""): res.append(ok); print(("PASS " if ok else "FAIL ")+n+("" if ok else f"  [{d}]"))
rc,o,e=psql("delete from public.report_unlocks; delete from public.production_reports; delete from public.user_lines; delete from public.attachments; delete from public.item_updates; delete from public.task_updates; delete from public.task_assignments; delete from public.tasks; delete from public.issues; delete from public.daily_reports; update public.positions set status='on',status_from=null,status_to=null,acting_profile_id=null; delete from public.position_history; delete from public.profiles; delete from auth.users;")
assert rc==0,e
U={}
for u,n,pos,role in [("trinhlh","Lê Hùng Trình","GDNM","admin"),("hungnv","Nguyễn Văn Hùng","TBP-SX","head"),("tuanlv","Lê Văn Tuấn","TT-SX","staff"),
                     ("binhtt","Trần Thị Bình","TT-SX","staff"),("ducmv","Mai Văn Đức","NV-QAC","staff"),("hapt","Phạm Thu Hà","TKTP","staff")]:
    i=str(uuid.uuid4());U[u]=i
    rc,o,e=psql(f"insert into auth.users(id,email) values('{i}','{u}@tlc.local'); insert into public.profiles(id,username,full_name,dept_id,position_id,role,must_change_pw) select '{i}','{u}','{n}',dept_id,id,'{role}',false from public.positions where code='{pos}'"); assert rc==0,e
A,H,T1,T2,Q,K=[U[x] for x in ["trinhlh","hungnv","tuanlv","binhtt","ducmv","hapt"]]; AU="authenticated"
rc,o,e=psql("select public.tlc_today()"); T=o[0]; Y=str(datetime.date.fromisoformat(T)-datetime.timedelta(1))
P1="TLC-AMC-VV-07W-04"   # định mức 181
rc,o,e=psql("select code from public.products where norm_per_hour is null and not is_semi limit 1"); P0=o[0]

rc,o,e=psql(f"insert into public.user_lines values('{T1}',1),('{T1}',2)",AU,T1); check("Tổ trưởng KHÔNG tự gán line",rc!=0,e)
rc,o,e=psql(f"insert into public.user_lines values('{T1}',1),('{T1}',2)",AU,H); check("TBP SX gán line 1,2 cho tổ trưởng",rc==0,e)
rc,o,e=psql(f"insert into public.user_lines values('{T2}',3)",AU,A); check("GĐNM gán line 3",rc==0,e)
rc,o,e=psql("select array_to_string(public.my_lines(),',')",AU,T1); check("Tổ trưởng thấy line 1,2",o==["1,2"],o)
rc,o,e=psql("select cardinality(public.my_lines())",AU,H); check("TBP SX thấy cả 10 line",o==["10"],o)
rc,o,e=psql("select coalesce(array_to_string(public.my_lines(),','),'')",AU,Q); check("QAC không nhập line nào",o in ([""],[]),o)

def save(uid,d,line,prod,good=100,op=0,sup=0,dop="null",dsup="null",hc=10,h=8,ot=0,dt=0,dr="null"):
    return psql(f"select public.save_prod_row('{d}',{line},'{prod}',null,{good},{op},{sup},{dop},{dsup},{hc},{h},{ot},{dt},{dr},null)",AU,uid)
rc,o,e=save(T1,T,1,P1,good=900,op=5,dop=1,sup=3,dsup=4,hc=12,h=8,ot=1,dt=20,dr="'Thiếu vật tư'"); check("Tổ trưởng lưu dòng line 1",rc==0,e)
rc,o,e=psql(f"select ng_qty,ng_op,ng_sup from public.production_reports where line_id=1"); check("NG tổng = thao tác + NCC",o==["8|5|3"],o)
rc,o,e=save(T1,T,1,P1,good=950,op=5,dop=1,sup=3,dsup=4,hc=12,h=8,ot=1); check("Lưu lại cùng mã = sửa, không nhân đôi",rc==0,e)
rc,o,e=psql("select count(*),max(good_qty) from public.production_reports"); check("Vẫn 1 dòng, SL 950",o==["1|950"],o)
rc,o,e=save(T1,T,3,P1); check("Tổ trưởng KHÔNG nhập line người khác",rc!=0,e)
rc,o,e=save(T1,Y,1,P1); check("KHÔNG nhập ngày hôm qua (đã khóa 23:59)",rc!=0,e)
rc,o,e=save(T1,T,2,P1,op=4); check("NG thao tác thiếu loại lỗi bị từ chối",rc!=0 and "loại lỗi" in e,e)
rc,o,e=save(T1,T,2,P1,dt=15); check("Dừng máy thiếu nguyên nhân bị từ chối",rc!=0 and "dừng máy" in e,e)
rc,o,e=save(T1,T,2,P1,hc=0); check("Có sản lượng mà 0 người bị từ chối",rc!=0,e)
rc,o,e=save(T1,T,2,"KHONG-CO-MA"); check("Mã không có trong danh mục bị từ chối",rc!=0,e)
rc,o,e=save(T1,T,2,P0,good=300,hc=10,h=8); check("Lưu mã chưa có định mức",rc==0,e)
rc,o,e=psql(f"insert into public.production_reports(report_date,line_id,product_code,good_qty) values('{T}',3,'{P1}',1)",AU,T1); check("KHÔNG ghi thẳng vào bảng (chỉ qua form)",rc!=0,e)
rc,o,e=psql("update public.production_reports set good_qty=99999",AU,H); check("TBP cũng KHÔNG sửa thẳng bảng",o in ([],["UPDATE 0"]) or rc!=0,(rc,o,e))
rc,o,e=psql("select max(good_qty) from public.production_reports where line_id=1"); check("Số liệu không bị sửa ngoài form",o==["950"],o)
rc,o,e=save(H,T,5,P1,good=400,hc=6); check("TBP SX nhập thay line 5",rc==0,e)
rc,o,e=psql("select count(*) from public.production_reports",AU,Q); check("QAC xem được báo cáo SX (đối chiếu NG)",o==["3"],o)
rc,o,e=psql("select count(*) from public.production_reports",AU,K); check("Thủ kho TP KHÔNG xem báo cáo SX",o==["0"],o)
rc,o,e=psql(f"select line_id,n_rows,good_qty,ng_op,ng_sup,man_hours,round(std_hours,2),missing_norm,leaders from public.prod_line_status('{T}') where line_id in (1,2,4)",AU,H)
check("Tổng hợp line 1",o[0]=="1|1|950|5|3|108|5.25|0|Lê Văn Tuấn",o)
check("Line 2 đánh dấu mã thiếu định mức (dùng 32)",o[1]=="2|1|300|0|0|80|9.38|1|Lê Văn Tuấn",o)
check("Line 4 chưa nhập",o[2].startswith("4|0|0"),o)
rc,o,e=psql(f"select count(*) from public.prod_line_status('{T}')",AU,K); check("Thủ kho TP KHÔNG xem tình trạng line",o==["0"],o)
rc,o,e=psql(f"select id from public.production_reports where line_id=5"); rid=o[0]
rc,o,e=psql(f"select public.delete_prod_row({rid})",AU,T1); check("Tổ trưởng KHÔNG xóa dòng line khác",rc!=0,e)
rc,o,e=psql(f"select public.unlock_report('LINE-1','{Y}',2,'Tổ trưởng quên nhập')",AU,A); check("GĐNM mở khóa Line 1 ngày hôm qua",rc==0,e)
rc,o,e=save(T1,Y,1,P1,good=800); check("Sau mở khóa: nhập bù ngày hôm qua",rc==0,e)
rc,o,e=save(T1,Y,2,P1,good=800); check("Line 2 ngày hôm qua vẫn khóa",rc!=0,e)
rc,o,e=psql(f"update public.profiles set status='locked' where id='{T1}'"); rc,o,e=save(T1,T,1,P1); check("Tài khoản bị khóa không nhập được",rc!=0,e)
rc,o,e=psql("select count(*) from public.audit_logs where table_name='production_reports'"); check("Có nhật ký thay đổi",int(o[0])>=4,o)
print(f"\n{sum(res)}/{len(res)} PASS")
