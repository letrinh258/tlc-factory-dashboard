# Hướng dẫn sử dụng — TLC Factory Operation Dashboard (bản nháp)

> Tài liệu này mô tả **20 module đã triển khai** (theo mảng `BUILT` trong code, dòng ~3225 của `index.html`). Module **"Giá thành" (gt)** chưa có trong `BUILT` → **chưa được xây**, không có hướng dẫn chi tiết, tạm bỏ qua trong tài liệu này.

## Cấu trúc menu bên trái (4 nhóm)

Hệ thống nhóm các module trong menu trái theo đúng logic hàm `grp()` bên trong `renderSide()` (index.html, dòng ~3241):

| Nhóm | Module thuộc nhóm |
|---|---|
| **Điều hành** | Tổng quan nhà máy, Tổng hợp báo cáo ngày, Bộ phận của tôi, Giao việc, Công việc của tôi, Báo cáo hằng ngày |
| **Quản trị** | Quản lý tài khoản, Cấu hình hệ thống |
| **Theo dõi** | KPI riêng, Lịch điều hành, Vấn đề và cải tiến, 3S |
| **Bộ phận** | Tất cả module gắn với 1 phòng ban cụ thể: Sản xuất, Chất lượng, Bảo trì – Cơ điện, Kho, Nhân sự – HCNS, Bảo hành, Kế hoạch, Kỹ thuật |

**Ai thấy nhóm nào** (theo hàm `allowedMods()`, dòng ~3226):
- **GĐNM (admin):** thấy toàn bộ module trừ "Bộ phận của tôi" (vì admin không thuộc 1 bộ phận riêng).
- **Trưởng bộ phận (head) / người kiêm nhiệm xác nhận:** thấy nhóm Điều hành đầy đủ, module phòng ban mình phụ trách (1 hoặc nhiều, nếu kiêm nhiệm), và các module trong nhóm Theo dõi (KPI, Lịch điều hành, Vấn đề và cải tiến, 3S).
- **Nhân viên (staff):** thấy "Công việc của tôi", "Báo cáo hằng ngày", module phòng ban mình, và nhóm Theo dõi.
- **Khách (guest):** chỉ thấy nhóm Điều hành cơ bản (Tổng quan, Tổng hợp, Giao việc, Công việc của tôi, Báo cáo hằng ngày) **nếu** được cấp quyền "Xem Tổng quan" (checkbox trong Quản lý tài khoản); nếu không được cấp, không thấy module nào.

---

# NHÓM ĐIỀU HÀNH

## Tổng quan nhà máy

### Mục đích
Màn hình điều hành tổng hợp số liệu thật từ các Form A–E, 3S, Giao việc và Báo cáo ngày, giúp GĐNM/TBP nắm nhanh tình hình nhà máy theo ngày/tuần/tháng mà không cần vào từng module.

### Ai dùng
GĐNM (xem toàn nhà máy), TBP/người kiêm nhiệm (xem theo phạm vi phụ trách), Khách được cấp quyền "Xem Tổng quan".

### Cách dùng
- Chọn **kỳ xem** (ngày/tuần/tháng), **ngày**, và **phạm vi** (toàn nhà máy hoặc theo bộ phận — tùy quyền).
- Các ô KPI dạng thẻ (tile) hiển thị số liệu kèm trạng thái màu (Xanh/Vàng/Đỏ); bấm vào một thẻ có gắn module nguồn sẽ **chuyển thẳng** sang module đó (`data-goto`).
- Hệ thống tự sinh **cảnh báo** khi số liệu vượt ngưỡng cấu hình.
- Bảng "Báo cáo ngày" cho biết vị trí nào đã nộp/chưa nộp báo cáo trong ngày.
- Bảng "Theo line" hiển thị tình hình từng line sản xuất.
- Biểu đồ cột xu hướng theo ngày ở cuối trang.

### Lưu ý
- Các ngưỡng Xanh/Vàng/Đỏ lấy từ tab "KPI" trong Cấu hình hệ thống (ngưỡng chung, khác với module "KPI riêng").
- Số liệu phụ thuộc dữ liệu đã nhập ở các module nguồn — nhập chưa đủ thì Tổng quan sẽ thiếu/lệch.

## Tổng hợp báo cáo ngày

### Mục đích
Tổng hợp trạng thái nộp Báo cáo hằng ngày của tất cả vị trí/mã báo cáo trong ngày đang xem — ai đã nộp, ai chưa.

### Ai dùng
GĐNM, TBP (xem theo bộ phận mình quản lý).

### Cách dùng
- Xem danh sách mã báo cáo (`report_code`) theo vị trí/bộ phận kèm trạng thái đã nộp/chưa nộp trong ngày.
- Dùng cùng dữ liệu nền với Báo cáo hằng ngày (`daily_summary`).

### Lưu ý
- Đây là màn **chỉ xem tổng hợp**, việc nhập liệu thực hiện ở module "Báo cáo hằng ngày".

## Bộ phận của tôi

### Mục đích
Cho TBP/người kiêm nhiệm xem nhanh thông tin bộ phận mình phụ trách: danh sách tài khoản, người xác nhận hôm nay, trạng thái TBP (đang làm/vắng/nghỉ).

### Ai dùng
TBP và người được giao kiêm nhiệm xác nhận (không hiển thị cho admin, vì admin không gắn 1 bộ phận riêng).

### Cách dùng
- Mỗi bộ phận mình phụ trách hiển thị 1 thẻ (card) riêng, gồm số tài khoản và dòng "Người xác nhận hôm nay" (tên + trạng thái: Xanh = đang hoạt động, Vàng = đang kiêm nhiệm do TBP vắng, Đỏ = chưa có ai xác nhận → GĐNM duyệt thẳng).
- Nếu chính mình là người xác nhận, hệ thống ghi rõ "Bạn là người xác nhận" hoặc "Bạn đang kiêm nhiệm quyền TBP".
- Bảng danh sách tài khoản của bộ phận: Họ tên, Tên đăng nhập, Vị trí, Mã báo cáo ngày, Trạng thái (Hoạt động/Đã khóa).

### Lưu ý
- Phần "Việc của bộ phận, báo cáo chờ xác nhận và KPI bộ phận" ghi rõ trong code là **sẽ xây ở Giai đoạn 4 và 6** — hiện tại màn này chỉ hiển thị thông tin tài khoản/người xác nhận, chưa có việc/báo cáo chờ xác nhận ngay tại đây.

## Giao việc

### Mục đích
Giao và theo dõi công việc/chỉ đạo cho cá nhân hoặc bộ phận, liên kết với mã việc tự sinh.

### Ai dùng
GĐNM, TBP/người được quyền giao việc.

### Cách dùng
- Tạo việc mới: chọn phạm vi giao (cá nhân `person` hoặc bộ phận `dept`), nhập nội dung, chọn người/bộ phận phụ trách, hạn hoàn thành.
- Mã việc được sinh tự động theo mẫu `GV<ddmm>-<số thứ tự>` (hàm `next_code`).
- Trạng thái việc theo danh sách `taskTT`: **Mới giao → Đã tiếp nhận → Đang làm → (Chờ BP khác) → Đề nghị đóng → Đã đóng**, hoặc **Đã hủy**.
- Việc tạo ra từ Lịch điều hành (mục "Quyết định") cũng xuất hiện tại đây, có gắn `meeting_session_id`.

### Lưu ý
- Việc ở trạng thái "Đề nghị đóng" cần người giao xác nhận mới chuyển sang "Đã đóng" (xem thêm phần `decideTask` ở Báo cáo hằng ngày/Giao việc).

## Công việc của tôi

### Mục đích
Trang cá nhân: xem nhanh thông tin tài khoản và nhắc 4 câu hỏi tự đánh giá công việc hằng ngày.

### Ai dùng
Tất cả tài khoản (admin/head/staff).

### Cách dùng
- Thẻ "Thông tin tài khoản": Họ tên, Tên đăng nhập, Bộ phận, Vị trí, Mã báo cáo ngày, Vai trò (GĐNM/Trưởng bộ phận/Nhân viên).
- Nút **"Đổi mật khẩu"** để tự đổi mật khẩu đăng nhập.
- Thẻ "4 câu hỏi mỗi ngày": *Hôm nay tôi phải làm gì? / Tôi đã làm được gì? / Kết quả thực tế ra sao? / Tôi vướng gì, cần ai hỗ trợ?* — dùng để tự nhắc trước khi vào Báo cáo hằng ngày.

### Lưu ý
- Danh sách việc được giao và cập nhật tiến độ thực hiện ở module "Giao việc" và "Báo cáo hằng ngày", không nằm trực tiếp ở màn này.

## Báo cáo hằng ngày

### Mục đích
Module trung tâm để từng vị trí nộp báo cáo ngày theo đúng 5 mục của mẫu BCN: Vấn đề/Sự cố, Cảnh báo S3, Kế hoạch ngày tiếp theo, Đề nghị hỗ trợ/quyết định, và ảnh minh chứng.

### Ai dùng
Tất cả vị trí có mã báo cáo (`report_code`); GĐNM/TBP xem thêm quyền duyệt, mở khóa.

### Cách dùng
- Chọn **mã báo cáo** (nếu phụ trách nhiều mã) và **ngày** cần nhập/xem.
- **Mục Vấn đề/Sự cố:** thêm dòng vấn đề với Mức độ (Đỏ/Vàng/Xanh theo `L4.muc`), Mảng ảnh hưởng (Giao hàng/Chất lượng/Chi phí/An toàn/Năng suất/Nhân sự/Khác), mô tả, người phụ trách, hạn xử lý; theo dõi trạng thái theo `vdTT` (Mới → Đang xử lý → Chờ BP khác → Đã xử lý → Đã đóng).
- **Mục Cảnh báo S3:** ghi nhận cảnh báo an toàn/sự cố phát sinh trong ngày.
- **Mục Kế hoạch ngày tiếp theo:** nhập kế hoạch công việc, Ưu tiên (1-Cao/2-Trung bình/3-Thấp), Sẵn sàng (Đủ/Thiếu nguồn lực); trạng thái theo `planTT` (Đang làm → Chờ BP khác → Đề nghị đóng → Đã đóng).
- **Mục Đề nghị hỗ trợ/quyết định (SR):** chọn Loại (Hỗ trợ/Quyết định), Mức khẩn (Khẩn trong ngày / 2-3 ngày / Trong tuần / Không gấp), Gửi tới (PGĐNM/Cố vấn/CEO-Tập đoàn/BP khác); trạng thái theo `srTT` (Chờ phản hồi → Đã quyết định/Đã hỗ trợ → Đã đóng).
- **Ảnh minh chứng:** tải ảnh lên (ảnh được nén qua `compressImage` trước khi lưu), xem lại qua `openPhotos`.
- Có khu vực riêng cho **admin xử lý nhanh** (`adminActs`) — ví dụ xác nhận/đóng đề nghị, duyệt chỉ đạo trực tiếp trên màn.

### Lưu ý
- Mỗi mã báo cáo/ngày **tự khóa sau 23:59** — admin có thể mở khóa lại cho ngày đó nếu cần sửa trễ hạn.
- Dữ liệu các mục này là nguồn cho module "Tổng hợp báo cáo ngày", "Tổng quan nhà máy" và phần "Vấn đề Đỏ/Vàng đang mở" của Lịch điều hành.

---

# NHÓM BỘ PHẬN

## Sản xuất (Form A)

### Mục đích
Ghi nhận sản lượng, nhân công, giờ công và dừng máy theo từng line sản xuất mỗi ngày — nguồn số liệu chính cho Tổng quan nhà máy, OEE/hiệu suất.

### Ai dùng
Tổ trưởng/TBP phụ trách line sản xuất (SX), GĐNM xem/sửa toàn bộ.

### Cách dùng
- Chọn **ngày**, **line**, nhập từng dòng theo **mã sản phẩm** (không còn chặn nhập trùng mã trong cùng line/ngày — một mã có thể tách thành nhiều dòng riêng nếu sản xuất nhiều lần trong ngày).
- Nhập **Kế hoạch**, **Sản lượng đạt (Good)**, **NG thao tác**, **NG nhà cung cấp** (kèm chọn loại lỗi nếu NG > 0), **Số người làm**.
- Nhập **Giờ bắt đầu** và **Giờ kết thúc** (định dạng giờ:phút) cùng **Giờ nghỉ (phút)** — hệ thống tự tính giờ công = Kết thúc − Bắt đầu − giờ nghỉ; nếu ca qua đêm (giờ kết thúc nhỏ hơn giờ bắt đầu, ví dụ 20:00 → 04:00) hệ thống tự hiểu là qua ngày hôm sau.
- Nhập **Dừng máy (phút)** kèm **Nguyên nhân dừng máy** nếu có.
- Có thể gắn dòng báo cáo với **Lệnh sản xuất** (order batch) nếu line/ngày đó có lệnh.
- Bấm **Lưu** (qua `save_prod_row`) để ghi dòng mới hoặc sửa dòng đã nhập (theo `p_row_id`).

### Lưu ý
- Báo cáo Line/ngày **khóa sau 23:59**; ngoài giờ cho phép hoặc không phụ trách line sẽ bị báo lỗi *"Báo cáo Line … ngày … đã khóa (sau 23:59) hoặc bạn không phụ trách line này"*.
- Giờ làm việc sau khi trừ giờ nghỉ phải **dương** và **không vượt quá 16 giờ**, nếu không hệ thống báo lỗi tương ứng *"Giờ nghỉ phải nhỏ hơn thời gian làm việc"* / *"...không quá 16 giờ"*.
- Phải chọn loại lỗi khi có NG thao tác/NG nhà cung cấp > 0; phải chọn nguyên nhân khi có dừng máy > 0; phải nhập số người làm nếu có sản lượng/NG > 0 — thiếu sẽ bị chặn lưu với thông báo cụ thể.
- Mã sản phẩm phải có trong danh mục đang hoạt động, nếu không báo lỗi *"Mã sản phẩm … không có trong danh mục"*.

## Chất lượng (QAC)

### Mục đích
Form B — kiểm tra chất lượng hằng ngày và quản lý Hotline (phản ánh/khiếu nại) của bộ phận QAC.

### Ai dùng
TBP/nhân viên QAC, GĐNM xem toàn bộ.

### Tab "Kiểm tra hàng ngày" (Form B)
- **Mục đích:** nhập số liệu kiểm tra chất lượng theo ngày/line theo mẫu Form B chung (formHead/GRID dùng chung với các form khác).
- **Cách dùng:** chọn ngày (có điều hướng lùi/tới ngày), nhập các chỉ số kiểm tra theo dòng, lưu qua nút chung trong `formBtns`.
- **Lưu ý:** khóa sau 23:59 như các Form khác; admin có nút "Mở khóa ngày này" để sửa trễ hạn.

### Tab "Hotline"
- **Mục đích:** ghi nhận và theo dõi đầy đủ các phản ánh/khiếu nại qua đường dây nóng.
- **Cách dùng:** thêm/sửa/xóa bản ghi hotline (CRUD đầy đủ qua `hlHTML`/`bindHL`); có nút **xuất Excel** (`hlExport`) để tải danh sách ra file.
- **Lưu ý:** đây là CRUD tự do (không khóa theo ngày như Form B).

## Bảo trì – Cơ điện (Form C)

### Mục đích
Ghi nhận công việc bảo trì/cơ điện và theo dõi tồn kho vật tư cơ điện (`invSnapHTML`/`parseInvNum`) theo ngày.

### Ai dùng
TBP/nhân viên bộ phận Cơ điện (CD), GĐNM xem toàn bộ.

### Cách dùng
- Nhập dữ liệu bảo trì theo ngày/line theo mẫu Form C (cùng scaffolding `formHead`/`GRID`/`formBtns` như Form B).
- Có phần snapshot tồn kho vật tư cơ điện, số liệu được chuẩn hóa qua `parseInvNum` (xử lý số dán từ Excel).

### Lưu ý
- Cũng áp dụng cơ chế khóa sau 23:59 + admin "Mở khóa ngày này".

## Kho

### Mục đích
Quản lý 2 nhóm: Thành phẩm (TP) và Linh kiện/vật tư (LK), gồm nhập tồn kho bằng cách dán dữ liệu từ Excel/Bravo.

### Ai dùng
TBP/nhân viên Kho (KHO), GĐNM xem toàn bộ.

### Cách dùng
- Chuyển giữa 2 sub-tab **TP** và **LK**.
- Dùng khung **"dán dữ liệu"** để dán trực tiếp bảng tồn kho sao chép từ Excel/Bravo (dữ liệu dạng tab-separated), hệ thống tự phân tích thành các dòng tồn kho.
- Xem/so sánh số liệu tồn kho đã nhập theo kỳ.

### Lưu ý
- Việc dán dữ liệu thay thế toàn bộ dòng của kỳ đang nhập (paste-replace) — dán sai định dạng cột có thể gây lệch dữ liệu, cần kiểm tra lại trước khi lưu.

## Nhân sự – HCNS (Form E)

### Mục đích
Ghi nhận số liệu nhân sự hằng ngày (chuyên cần, biến động lao động…) theo mẫu Form E của bộ phận HCNS.

### Ai dùng
TBP/nhân viên HCNS, GĐNM xem toàn bộ.

### Cách dùng
- Nhập theo ngày, theo cùng scaffolding Form chung (`formHead`/`GRID`/`formBtns`) như Form B/C.

### Lưu ý
- Khóa sau 23:59; admin có quyền "Mở khóa ngày này".

## Bảo hành

### Mục đích
Theo dõi dữ liệu bảo hành sản phẩm theo tháng, nhập bằng cách dán dữ liệu (paste-replace) từ nguồn ngoài.

### Ai dùng
TBP/nhân viên phụ trách bảo hành (BHM/BHN), GĐNM xem toàn bộ.

### Cách dùng
- Chọn **tháng** cần xem/nhập (điều hướng lùi/tới tháng qua `stepMonth`, hiển thị theo `monthLabel`).
- Dán dữ liệu bảo hành đã copy từ Excel vào khung dán — hệ thống phân tích qua `parseBhPaste()` và **thay thế** toàn bộ dữ liệu của tháng đó.

### Lưu ý
- Đây là cơ chế **paste-replace theo tháng** — dán lại sẽ xóa và ghi đè dữ liệu cũ của tháng đang chọn, cần chắc chắn dữ liệu dán đầy đủ trước khi xác nhận.

## Kế hoạch

### Mục đích
Quản lý Lệnh sản xuất (LSX) và theo dõi Đơn mua hàng (PO) của bộ phận Kế hoạch sản xuất (KHSX).

### Ai dùng
TBP/nhân viên KHSX (`kh`), GĐNM xem toàn bộ; dữ liệu Lệnh sản xuất được Sản xuất (sx) tham chiếu khi nhập Form A.

### Tab "Lệnh sản xuất"
- **Mục đích:** tạo/quản lý các lệnh sản xuất theo line, làm cơ sở gắn với báo cáo sản xuất hằng ngày.
- **Cách dùng:** dán dữ liệu lệnh sản xuất từ Excel (`parseLsxPaste()`), hệ thống hiển thị theo line (`lineOptsName()`), có thể sửa/xóa qua `bindLsx()`.

### Tab "Theo dõi mua hàng" (PO)
- **Mục đích:** theo dõi đơn mua hàng nguyên vật liệu/vật tư.
- **Cách dùng:** dán dữ liệu PO từ Excel (`parsePoPaste()`), xem danh sách và trạng thái đơn hàng.

### Lưu ý
- Lệnh sản xuất phải khớp **line và ngày** đang nhập ở Form A, nếu không Form A sẽ báo lỗi *"Lệnh sản xuất không khớp line/ngày đang nhập"*.

## Kỹ thuật (ECR)

### Mục đích
Quản lý Phiếu thay đổi kỹ thuật (ECR – Engineering Change Request) và lịch sử định mức theo mã sản phẩm.

### Ai dùng
TBP/nhân viên Kỹ thuật (KT), GĐNM xem toàn bộ.

### Tab "Phiếu ECR"
- **Mục đích:** tạo và theo dõi các phiếu đề nghị thay đổi kỹ thuật/định mức.
- **Cách dùng:** tạo phiếu mới (`ktNewForm`), xem danh sách (`ktListHTML`), sửa phiếu đã tạo (`ktEditForm`) — khi lưu sửa, hệ thống gọi `ecr_edit` và hiện thông báo **"Đã lưu phiếu ECR"**.

### Tab "Lịch sử định mức theo mã"
- **Mục đích:** xem lại lịch sử thay đổi định mức năng suất của từng mã sản phẩm theo thời gian (`ktHistHTML`).
- **Cách dùng:** chọn mã sản phẩm để xem toàn bộ lịch sử định mức đã áp dụng.

### Lưu ý
- Thông báo lỗi khi lưu thất bại hiển thị trực tiếp trong form sửa (`setMsg("ktEditMsg", sbErr(err), "bad")`).

---

# NHÓM THEO DÕI

## KPI riêng

### Mục đích
Quản lý cây KPI riêng theo bộ phận/vị trí, định nghĩa mục tiêu và nhập kết quả thực hiện — khác với ngưỡng KPI chung dùng cho Tổng quan nhà máy (nằm ở Cấu hình hệ thống).

### Ai dùng
GĐNM (toàn bộ), TBP (theo bộ phận mình phụ trách, theo `kpCanSee`/`kpPosDept`).

### Cách dùng
- 3 tab: **"Cây KPI"** (`kpDashHTML` — xem tổng quan cây chỉ số), **"Định nghĩa & Mục tiêu"** (`kpDefHTML` — tạo/sửa chỉ số và mục tiêu theo kỳ, dùng `kpCurTarget` để lấy mục tiêu hiện hành), **"Nhập kết quả"** (`kpResultHTML` — nhập số liệu thực hiện theo kỳ).
- Chuyển tab bằng các nút trên đầu màn, dữ liệu hiển thị theo quyền xem (`kpAll`/`kpCanSee`).

### Lưu ý
- Phân quyền xem/sửa theo vị trí-bộ phận (`kpPosDept`) — TBP chỉ thấy/nhập được KPI của bộ phận mình phụ trách.

## Lịch điều hành

### Mục đích
Số hóa cơ chế họp (Giao ban ngày/Tuần/Tháng/Đột xuất): nội dung họp được **kéo sẵn tự động** từ hệ thống (vấn đề đang mở, việc quá hạn), và **quyết định họp tự chuyển thành việc theo dõi** (Giao việc).

### Ai dùng
GĐNM (toàn quyền loại họp + buổi họp), TBP/người có quyền duyệt bộ phận (xem/ghi chú/tạo quyết định trong buổi họp).

### Tab "Phiên họp"
- **Mục đích:** tạo và quản lý từng buổi họp cụ thể theo ngày.
- **Cách dùng:** bấm **"+ Tạo buổi họp"**, chọn **Loại họp**, **Ngày họp**, có thể **gắn với vấn đề Đỏ** đang mở (cho họp đột xuất). Mở một buổi họp để xem chi tiết: danh sách **Vấn đề Đỏ/Vàng đang mở**, **Việc/chỉ đạo quá hạn**, khung **Ghi chú/ý kiến buổi họp** (lưu qua nút "Lưu ghi chú"), nút **"Đánh dấu đã họp"**, danh sách **Quyết định → việc theo dõi** đã tạo, và nút **"+ Thêm quyết định (tạo việc)"** để nhập Nội dung quyết định, Phòng ban phụ trách, Người phụ trách, Hạn hoàn thành → bấm **"Tạo việc"** sẽ tự sinh mã việc `GV<ddmm>-...` và đưa vào module Giao việc.

### Tab "Cơ chế họp"
- **Mục đích:** định nghĩa các loại họp định kỳ (tên, tần suất, phạm vi, thành phần tham dự).
- **Cách dùng:** (chỉ admin) bấm **"+ Loại họp mới"**, nhập **Tên loại họp**, chọn **Tần suất** (Hàng ngày/Hàng tuần/Hàng tháng/Đột xuất), **Phòng ban** (để trống = toàn nhà máy), **Thành phần tham dự**, tick **"Đang dùng"** để bật/tắt loại họp; bấm **"Sửa"** trên một dòng để chỉnh lại.

### Lưu ý
- Chỉ **admin** mới tạo/sửa được loại họp (tab Cơ chế họp); quyền ghi chú/tạo quyết định trong một buổi họp dành cho admin hoặc người có `approves_depts`.
- "Vấn đề Đỏ/Vàng đang mở" và "Việc quá hạn" là lấy tự động theo ngày họp, không nhập tay.

## Vấn đề và cải tiến

### Mục đích
Quản lý Vấn đề/CAPA (xử lý sự cố, nguyên nhân, hành động khắc phục) và các Dự án cải tiến.

### Ai dùng
GĐNM, TBP/người được quyền tại các bộ phận liên quan.

### Tab "Vấn đề/CAPA"
- **Mục đích:** ghi nhận và theo dõi xử lý các vấn đề (Đỏ/Vàng/Xanh theo mức độ `VD_SEV`), gắn CAPA (nguyên nhân – hành động khắc phục).
- **Cách dùng:** xem/thêm/sửa vấn đề qua `vdIssueHTML`, theo dõi trạng thái tới khi đóng.

### Tab "Dự án cải tiến"
- **Mục đích:** quản lý các dự án cải tiến (Lean/Kaizen...) đang triển khai.
- **Cách dùng:** xem/thêm dự án qua `vdProjHTML`, theo dõi tiến độ.

### Lưu ý
- Vấn đề mức **Đỏ** đang mở sẽ xuất hiện tự động ở Lịch điều hành (gắn họp đột xuất) và ở Tổng quan nhà máy (cảnh báo).

## 3S

### Mục đích
Quản lý tiêu chí 5S/3S, chấm điểm theo khu vực, và danh sách lỗi phát hiện trong chương trình 5S.

### Ai dùng
GĐNM, TBP/người chấm điểm 5S theo khu vực phụ trách.

### Tab "Thống kê"
- **Mục đích:** tổng hợp điểm 5S theo khu vực/kỳ (`fsRange`, `fsSName`).
- **Cách dùng:** chọn tiêu chí (`fsCrit`) và khoảng thời gian để xem thống kê.

### Tab "Danh sách lỗi"
- **Mục đích:** ghi nhận từng lỗi 5S phát hiện khi kiểm tra, kèm ảnh minh chứng.
- **Cách dùng:** bấm tạo mới (`fsNewForm`), tải ảnh lên (`fsUpload`), lưu qua `bind5s()`.

### Lưu ý
- Có cơ chế tải ảnh minh chứng cho từng lỗi 5S, tương tự ảnh minh chứng ở Báo cáo hằng ngày.

---

# NHÓM QUẢN TRỊ

## Quản lý tài khoản

### Mục đích
Tạo, quản lý và phân quyền tài khoản người dùng toàn hệ thống.

### Ai dùng
Chỉ GĐNM (admin).

### Cách dùng
- **Tạo tài khoản:** nhập thông tin tài khoản mới; nếu vai trò là **Khách**, có thể **tạo vị trí mới ngay trong form** (dynamic position creation) nếu vị trí khách cần chưa có sẵn.
- **Nhập nhân sự hàng loạt:** nhập nhiều tài khoản cùng lúc (dạng bulk).
- **Vị trí trong nhà máy:** xem danh sách vị trí hiện có và thêm vị trí mới qua form riêng.
- **Bảng tài khoản:** liệt kê toàn bộ tài khoản, có cột checkbox **"Xem Tổng quan"** (cấp quyền cho Khách xem Tổng quan nhà máy), và các nút hành động: **Đặt lại mật khẩu**, **Khóa**, **Mở khóa**.

### Lưu ý
- Quyền "Xem Tổng quan" là điều kiện duy nhất để tài khoản **Khách** thấy được bất kỳ module nào — nếu không tick, Khách không thấy module nào trong menu.

## Cấu hình hệ thống

### Mục đích
Cấu hình toàn bộ các tham số nền của hệ thống: định mức sản xuất, cơ chế trưởng bộ phận, ngưỡng KPI chung, và quy tắc chung vận hành.

### Ai dùng
Chỉ GĐNM (admin).

### Tab "Định mức năng suất" (norm)
- **Mục đích:** quản lý định mức năng suất theo mã sản phẩm.
- **Cách dùng:** nhập/sửa định mức từng mã, hoặc **dán dữ liệu định mức hàng loạt** (bulk paste) từ Excel; xem **lịch sử** thay đổi định mức (liên kết với tab "Lịch sử định mức theo mã" ở module Kỹ thuật).

### Tab "Trưởng bộ phận & kiêm nhiệm" (tbp)
- **Mục đích:** quản lý trạng thái hoạt động của từng TBP và người kiêm nhiệm khi TBP vắng/nghỉ.
- **Cách dùng:** đặt trạng thái TBP (đang làm/vắng/nghỉ), chỉ định **người kiêm nhiệm** khi vắng, xem **lịch sử** thay đổi trạng thái.

### Tab "KPI" (kpi — ngưỡng chung)
- **Mục đích:** cấu hình ngưỡng **Xanh/Vàng** cho các chỉ số chuẩn hiển thị ở Tổng quan nhà máy (**khác với module "KPI riêng"** ở nhóm Theo dõi).
- **Cách dùng:** nhập ngưỡng cho từng chỉ số chuẩn.

### Tab "Quy tắc chung" (line)
- **Mục đích:** cấu hình tên các line sản xuất và các quy tắc vận hành chung.
- **Cách dùng:** đặt **Tên line sản xuất**, **Hạn nhập SX** (giờ khóa báo cáo), **Định mức mặc định**, **Ngưỡng lệch NG SX↔QAC**, **Ngưỡng lệch giờ dừng SX↔CĐ**, **Chu kỳ cập nhật bảo hành**.

### Tab "Bravo" (đồng bộ)
- **Mục đích:** ghi chú placeholder cho việc đồng bộ dữ liệu với hệ thống Bravo trong tương lai.
- **Cách dùng:** hiện tại chỉ là ghi chú, chưa có chức năng đồng bộ thật.

### Lưu ý
- Thay đổi ở tab "Quy tắc chung" (ví dụ hạn nhập SX, ngưỡng lệch) ảnh hưởng trực tiếp đến cơ chế khóa và cảnh báo ở các module Sản xuất, Chất lượng, Bảo trì và Tổng quan nhà máy — cần cân nhắc kỹ trước khi đổi.

---

## Module chưa triển khai

- **Giá thành (gt):** có trong danh mục 21 module dự kiến (`MODS`) và được gắn với bộ phận KTGT (`DEPT_MOD`), nhưng không có trong `BUILT` → **chưa được xây dựng** trên hệ thống, chưa có màn hình/chức năng nào để hướng dẫn.
