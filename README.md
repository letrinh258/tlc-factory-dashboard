# TLC FACTORY OPERATION DASHBOARD

Hệ thống điều hành nhà máy TLC Lighting: Dashboard GĐNM, giao việc, báo cáo ngày 14 vị trí, báo cáo chuyên môn, KPI, cảnh báo.

- Trang chạy: https://letrinh258.github.io/tlc-factory-dashboard/
- Giao diện: một tệp `index.html` (HTML/CSS/JS thuần, không cần build)
- Máy chủ: Supabase (Auth, PostgreSQL + RLS, Edge Functions)

## Cấu trúc
| Đường dẫn | Nội dung |
|---|---|
| `index.html` | Toàn bộ giao diện |
| `supabase/01_tlc_schema.sql` | Bảng, hàm phân quyền, RLS, dữ liệu gốc (chạy trong SQL Editor) |
| `supabase/02_gd4.sql` | GĐ4: báo cáo ngày 5 mục, giao việc, ảnh minh chứng, khóa 23:59 (chạy sau file 01) |
| `supabase/functions/admin-users/index.ts` | Edge Function tạo / khóa / đặt lại mật khẩu tài khoản (tắt Verify JWT) |

## Bảo mật
- Trang web chỉ chứa *publishable key*; dữ liệu được bảo vệ bằng RLS trên máy chủ.
- Không bao giờ đưa secret key / service_role key vào repo này.

## Tiến độ
- GĐ1 Phân tích nghiệp vụ – xong
- GĐ2 Dashboard GĐNM – xong (số liệu sản xuất mẫu đến GĐ5)
- GĐ3 Đăng nhập, phân quyền – nghiệm thu đạt 01/11
- GĐ4 Giao việc, báo cáo ngày 14 vị trí – đang nghiệm thu
