---
name: source-summary
description: Scan source folder, sinh .pagent/source-summary.md để các agent hiểu codebase
allowed_tools: Read,Bash,Grep,Glob
---

# Skill: Source Summary

Bạn được gọi 1 lần khi `pagent init`. Quét folder hiện tại, sinh file
`.pagent/source-summary.md` ngắn gọn để coder/reviewer/tester load nhanh.

## Quy trình
1. `ls`/`Glob` top-level + 1–2 cấp con để hiểu cấu trúc.
2. Đọc các file định danh: `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`,
   `composer.json`, `pom.xml`, `Gemfile`, `README*`, `Makefile`, `Dockerfile*`.
3. Đoán test framework từ devDeps + tên thư mục `tests/`, `__tests__/`, `*_test.go`...

## QUAN TRỌNG về output
- **TUYỆT ĐỐI KHÔNG** dùng tool Write/Edit để tạo hoặc sửa BẤT KỲ file nào.
- **TUYỆT ĐỐI KHÔNG** chạm vào `CLAUDE.md`, `README.md`, `AGENTS.md`.
- Chỉ dùng Read/Bash/Grep/Glob để khảo sát, rồi **TRẢ VỀ markdown thuần** trong response.
- Caller (pagent) sẽ tự ghi response của bạn xuống `.pagent/source-summary.md`.

## Output format (trả về NGUYÊN VĂN markdown, KHÔNG có code fence bọc ngoài)

```markdown
# Source Summary

**Project type:** <node-ts | python | go | ...>
**Language(s):** <list>
**Entry point:** <file>
**Test framework:** <jest | pytest | go test | ...>
**Test command:** <lệnh chạy test>
**Build command:** <lệnh build, nếu có>
**Run command:** <lệnh start dev, nếu có>

## Cấu trúc thư mục
<cây top-level + chú thích>

## Convention
- Naming: <quan sát>
- Import style: <quan sát>
- Module boundary: <quan sát>

## Domain (đoán từ README/code)
<2–4 câu>

## Files quan trọng
- <path> — <vai trò>
- ...
```

Response của bạn = NGUYÊN nội dung markdown trên (bắt đầu bằng `# Source Summary`). Không thêm preamble, không hỏi xác nhận, không "Đã tạo file…".
