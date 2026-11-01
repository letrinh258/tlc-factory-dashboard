import asyncio, json, base64, time, datetime
from urllib.parse import urlparse
from playwright.async_api import async_playwright
UMD=open('/tmp/claude-0/sbjs/node_modules/@supabase/supabase-js/dist/umd/supabase.js').read()
def b64(o): return base64.urlsafe_b64encode(json.dumps(o).encode()).decode().rstrip("=")
UID="11111111-1111-1111-1111-111111111111"
JWT=b64({"alg":"HS256","typ":"JWT"})+"."+b64({"sub":UID,"exp":int(time.time())+3600,"role":"authenticated","aud":"authenticated","session_id":"s1"})+".sig"
T=datetime.date.today().isoformat()
ROLE={"v":"admin"}
ALERTS={"v":[]}
def me():
    if ROLE["v"]=="admin": return {"id":UID,"username":"trinhlh","full_name":"Lê Hùng Trình","role":"admin","status":"active","must_change_pw":False,"dept_id":1,"dept_name":"Ban giám đốc","dept_code":"BGD","position_id":1,"position_name":"Giám đốc nhà máy","position_kind":"director","report_code":None,"approves_depts":[],"overview":True,"today":T}
    return {"id":UID,"username":"hungnv","full_name":"Nguyễn Văn Hùng","role":"head","status":"active","must_change_pw":False,"dept_id":3,"dept_name":"Phòng Sản xuất","dept_code":"SX","position_id":55,"position_name":"Trưởng phòng Sản xuất","position_kind":"head","report_code":"TBP-SX","approves_depts":[3],"overview":False,"today":T}
async def handle(route):
    r=route.request;u=r.url;p=urlparse(u).path
    H={"access-control-allow-origin":"*","access-control-allow-headers":"*","access-control-allow-methods":"*"}
    J=lambda o,st=200: route.fulfill(status=st,content_type="application/json",body=json.dumps(o),headers=H)
    if r.method=="OPTIONS": return await route.fulfill(status=200,headers=H)
    if p.endswith("/auth/v1/token"): return await J({"access_token":JWT,"token_type":"bearer","expires_in":3600,"expires_at":int(time.time())+3600,"refresh_token":"rt","user":{"id":UID,"aud":"authenticated","role":"authenticated"}})
    rp=p.split("/rest/v1/")[-1]
    if rp=="rpc/me": return await J(me())
    if rp=="rpc/my_alerts": return await J(ALERTS["v"])
    if rp=="rpc/dash_summary": return await J({})
    if rp=="rpc/daily_summary": return await J([])
    if rp=="rpc/my_report_codes": return await J([])
    if rp=="rpc/dept_approvers": return await J([])
    if rp=="maintenance_reports": return await J([])
    if rp=="production_lines": return await J([{"id":i,"name":f"Line {i}","active":True} for i in range(1,11)])
    if rp=="departments": return await J([{"id":1,"code":"BGD","name":"Ban giám đốc","sort":1},{"id":3,"code":"SX","name":"Phòng Sản xuất","sort":3},{"id":5,"code":"KHO","name":"Kho","sort":5},{"id":7,"code":"CD","name":"Phòng Cơ điện","sort":7}])
    if rp=="positions": return await J([{"id":1,"code":"GDNM","name":"Giám đốc nhà máy","dept_id":1,"kind":"director","report_code":None},{"id":55,"code":"TBP-SX","name":"Trưởng phòng Sản xuất","dept_id":3,"kind":"head","report_code":"TBP-SX"}])
    if rp=="app_settings": return await J([{"key":"rules","value":{"cutoff":"17:30","stdProd":32}}])
    if rp=="profiles": return await J([{"id":UID,"username":ROLE["v"],"full_name":"x","dept_id":3,"position_id":55,"role":"head" if ROLE["v"]!="admin" else "admin","status":"active","must_change_pw":False}])
    return await J([])
async def login(b,role):
    ROLE["v"]=role;pg=await b.new_page(timezone_id='Asia/Ho_Chi_Minh',viewport={"width":1300,"height":900});pg.on("pageerror",lambda e:print("PE",e))
    await pg.route("https://cdn.jsdelivr.net/**",lambda r:r.fulfill(status=200,content_type="application/javascript",body=UMD))
    await pg.route("https://ujlpvnqsunchykmtdtqt.supabase.co/**",handle)
    await pg.goto("file:///home/claude/index.html");await pg.wait_for_timeout(400)
    await pg.fill("#lUser","trinhlh" if role=="admin" else "hungnv");await pg.fill("#lPass","x12345678");await pg.click("#lBtn");await pg.wait_for_timeout(1200);return pg
async def main():
  async with async_playwright() as p:
    b=await p.chromium.launch()
    # ---- TEST A: chuông hiện số lượng + nội dung cảnh báo vận hành, bấm vào thì điều hướng ----
    ALERTS["v"]=[{"kind":"cd_open","title":"1 sự cố máy chưa xử lý xong","detail":"Phiếu Cơ điện chưa có giờ kết thúc","ref":T,"mod":"bt"},
                 {"kind":"task_over","title":"QUÁ HẠN: V-01","detail":"Việc test","ref":"V-01","mod":"task"}]
    a=await login(b,"admin")
    n=await a.inner_text("#bellN");print("A badge:",n)
    assert n=="2",n
    await a.click("#bell");await a.wait_for_timeout(200)
    txt=await a.inner_text("#notif");print("A notif has cd_open:", "sự cố máy" in txt)
    assert "sự cố máy" in txt
    await a.click("#notif [data-goto=bt]");await a.wait_for_timeout(500)
    print("A screen after click:", ST:=await a.evaluate("ST.screen"))
    assert ST=="bt"
    print("A notif closed:", hid:=await a.get_attribute("#notif","hidden"));assert hid is not None

    # ---- TEST B: không có cảnh báo -> badge ẩn ----
    ALERTS["v"]=[]
    await a.evaluate("loadAlertsLive()");await a.wait_for_timeout(300)
    hidden=await a.get_attribute("#bellN","hidden");print("B badge hidden:",hidden is not None);assert hidden is not None

    # ---- TEST C: TBP (role=head, dept SX) thấy cảnh báo scoped của mình, bấm vào "sx" điều hướng đúng và có trong allowedMods ----
    ALERTS["v"]=[{"kind":"line_missing","title":"10 line chưa nhập báo cáo SX hôm nay","detail":"","ref":T,"mod":"sx"}]
    cpage=await login(b,"head")
    n=await cpage.inner_text("#bellN");print("C badge:",n);assert n=="1"
    await cpage.click("#bell");await cpage.wait_for_timeout(200)
    await cpage.click("#notif [data-goto=sx]");await cpage.wait_for_timeout(500)
    scr=await cpage.evaluate("ST.screen");print("C screen:",scr);assert scr=="sx"

    print("ALL OK")
    await b.close()
asyncio.run(main())
