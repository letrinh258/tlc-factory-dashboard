"""Kiểm thử quyền xem Tổng quan."""
import subprocess, re, json
D="/var/tmp/tlcpg"
def psql(sql, uid=None):
    pre=f"set role authenticated; select set_config('request.jwt.claim.sub','{uid}',false); " if uid else ""
    r=subprocess.run(["psql","-h",D,"-p","5433","-U","postgres","-d","tlc","-At","-v","ON_ERROR_STOP=1","-c",pre+sql],capture_output=True,text=True)
    return r.returncode,[l for l in r.stdout.strip().split("\n") if l and l!="SET" and l!=uid and not re.match(r"^(UPDATE|DELETE|INSERT) \d+",l)],r.stderr.strip()
res=[]
def check(n,ok,d=""): res.append(ok); print(("PASS " if ok else "FAIL ")+n+("" if ok else f"  [{d}]"))
U={r.split("|")[0]:r.split("|")[1] for r in psql("select username,id from profiles")[1]}
dep=lambda c: psql(f"select public.dept_id_of('{c}')")[1][0]
A,H,TT,Q,CD,K,NS,KH=[U[x] for x in ["trinhlh","hungnv","tuanlv","ducmv","namcd","hapt","linhns","sangnt"]]
psql("delete from public.user_roles where module='overview'")
psql(f"insert into public.tasks(code,kind,source,title,content,report_code,dept_id,assigner_id,due_date,status) values('GV9999-01','GV','Việc giao thêm','t','t','SX',{dep('SX')},'{A}',current_date-3,'doing'),('GV9999-02','GV','Việc giao thêm','t','t','KHSX',{dep('KHSX')},'{A}',current_date-3,'doing')")
def dash(uid,dept="null"):
    rc,o,e=psql(f"select public.dash_summary(public.tlc_today()-6,public.tlc_today(),null,{dept})",uid);return rc,(json.loads(o[0]) if rc==0 and o else None),e
rc,j,e=dash(A);check("GĐNM xem toàn nhà máy",rc==0 and j["mode"]=="full" and "prod" in j and "hr" in j and j["tasks"]["overdue"]>=2,(e,j and j.get("tasks")))
rc,j,e=dash(TT);check("Nhân viên chưa được tích: KHÔNG xem",rc!=0 and "quyền" in e,e)
rc,j,e=dash(Q,dep("QAC"));check("NV QAC (không phải TBP) chưa tích: KHÔNG xem số BP",rc!=0,e)
rc,o,e=psql(f"insert into public.user_roles(profile_id,module,can_view) values('{TT}','overview',true)",H);check("TBP KHÔNG tự cấp quyền xem",rc!=0,e)
rc,o,e=psql(f"insert into public.user_roles(profile_id,module,can_view) values('{TT}','overview',true)",A);check("GĐNM tích quyền cho nhân viên",rc==0,e)
rc,j,e=dash(TT);check("Nhân viên đã tích: xem toàn nhà máy",rc==0 and j["mode"]=="full" and "hr" in j and "wh" in j,e)
rc,j,e=dash(H,dep("SX"));check("TBP SX: chỉ số SX, không có nhân sự/kho/QAC",rc==0 and j["mode"]=="dept" and "prod" in j and "lines" in j and "hr" not in j and "wh" not in j and "qc" not in j,(e,j and list(j)))
check("TBP SX: chỉ việc của BP SX",j and j["tasks"]["overdue"]==1,j and j["tasks"])
rc,j,e=dash(H,dep("KHO"));check("TBP SX KHÔNG xem số BP khác",rc!=0,e)
rc,j,e=dash(KH,dep("KHSX"));check("TBP KHSX: có sản lượng, không có nhân sự",rc==0 and "prod" in j and "hr" not in j,(e,j and list(j)))
psql(f"update public.positions set status='vacant',status_from=current_date,acting_profile_id='{K}' where code='TBP-HCNS'")
rc,j,e=dash(K,dep("HCNS"));check("Người kiêm nhiệm TBP HCNS: xem số HCNS",rc==0 and "hr" in j and "prod" not in j and "wh" not in j,(e,j and list(j)))
psql("update public.positions set status='on',status_from=null,acting_profile_id=null where code='TBP-HCNS'")
rc,j,e=dash(K,dep("HCNS"));check("Hết kiêm nhiệm: mất quyền xem",rc!=0,e)
rc,j,e=dash(A,dep("KHO"));check("GĐNM lọc theo 1 BP",rc==0 and j["mode"]=="full",e)
psql("delete from public.tasks where code like 'GV9999%'")
print(f"\n{sum(res)}/{len(res)} PASS")
