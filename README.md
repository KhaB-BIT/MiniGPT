# MiniGPT

Ứng dụng menu bar macOS nhỏ gọn để xem hạn mức Codex và trạng thái phiên Codex
đang hoạt động.

## Hiển thị

- Phần trăm còn lại và thời gian hồi của phiên 5 giờ.
- Phần trăm còn lại và thời gian hồi theo tuần.
- `⚙️` Codex đang chạy, `🔐` cần cấp quyền, `✅` đã chạy xong.
- Không xuất hiện biểu tượng ở Dock.

## Yêu cầu

- macOS 13 trở lên.
- Codex CLI đã được cài đặt và đăng nhập.

Cài Codex CLI theo hướng dẫn chính thức:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
codex
```

Ở lần chạy `codex` đầu tiên, chọn đăng nhập bằng ChatGPT.

## Chạy từ mã nguồn

```bash
swift run
```

## Tạo ứng dụng macOS

Không cần full Xcode. Chạy:

```bash
./scripts/build-app.sh
```

Kết quả:

- `dist/MiniGPT.app`
- `dist/MiniGPT-0.1.3-macos-universal.zip`

File thực thi hỗ trợ cả Apple Silicon và Intel. Bản hiện tại chỉ được ký ad-hoc,
chưa có Apple Developer ID và chưa notarize. Khi tải từ Internet, macOS có thể
yêu cầu nhấp chuột phải vào app và chọn **Open** ở lần mở đầu tiên.

## Đưa lên GitHub Releases

Tạo release mới trên GitHub, ví dụ tag `v0.1.3`, rồi tải file
`dist/MiniGPT-0.1.3-macos-universal.zip` lên làm release asset.

## Quyền riêng tư

App chỉ đọc dữ liệu Codex cục bộ trên máy người dùng. Thông tin tài khoản và hạn
mức được lấy qua `codex app-server`; trạng thái hoạt động được đọc từ dữ liệu phiên
trong `~/.codex`. App không tự gửi các dữ liệu này tới dịch vụ bên thứ ba.
