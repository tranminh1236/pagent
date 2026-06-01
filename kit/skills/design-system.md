---
name: design-system
description: Heuristic UX/UI Grab/Shopee (mobile-first, density, CTA, trust) + Apple HIG (clarity/deference/depth, ≥44pt, dynamic type) — reference cho designer
---

# Skill: Design System Heuristics

Reference cho agent `designer`. Tổng hợp chuẩn để spec ăn khớp e-commerce/super-app mobile
(Grab/Shopee) và nguyên tắc nền tảng (Apple HIG).

## Apple HIG — 3 trụ
- **Clarity** — chữ đọc được mọi cỡ, icon chính xác, nhấn nội dung không nhấn chrome.
- **Deference** — UI nhường chỗ cho content; tránh trang trí cạnh tranh với dữ liệu.
- **Depth** — phân lớp & chuyển cảnh truyền đạt thứ bậc, gợi định vị.

### Quy tắc cứng (HIG)
- Touch target **≥44×44pt**, khoảng cách giữa target tối thiểu 8pt.
- **Dynamic Type**: typography theo role (largeTitle…caption), không khóa cỡ px cứng.
- Contrast **WCAG AA**: ≥4.5:1 text thường, ≥3:1 text lớn / icon.
- Safe area & thumb reach: action chính trong vùng ngón cái với tới (đáy màn).
- Motion tôn trọng `reduce-motion`; feedback < 100ms cho tap.

## Grab / Shopee — heuristic super-app
- **Mobile-first**: thiết kế cho 360–414px trước, scale lên tablet/web sau.
- **Density cao nhưng có nhịp**: nhiều thông tin/màn nhưng group bằng spacing 8pt & divider; không để "tường chữ".
- **CTA**: đúng **1 primary action / màn**, màu thương hiệu nổi bật (Grab green #00B14F, Shopee orange #EE4D2D), secondary là outline/ghost. CTA dính đáy (sticky) cho flow mua/đặt.
- **Trust signals**: rating sao + số review, badge (chính hãng/freeship/secure), seller verified, ảnh thật, giá gạch + % giảm rõ ràng.
- **Conversion**: giảm bước, prefill, hiển thị tổng tiền sớm, progress cho checkout.
- **Feedback**: skeleton khi load, toast/inline cho lỗi, state rỗng có hướng dẫn.
- **Localization**: chừa chỗ cho chuỗi tiếng Việt dài hơn, số tiền định dạng `₫`.

## Token discipline
- Color **semantic** (primary/surface/text/success/warning/danger), không hardcode hex trong component.
- Spacing scale 4/8pt (4,8,12,16,24,32…).
- Typography theo role + dynamic-type mapping.
- Mỗi component khai báo state: default / pressed / disabled / loading.

## Checklist trước khi chốt spec
- [ ] Mọi tap target ≥44pt, đủ khoảng cách.
- [ ] Contrast AA cho text + icon trên surface tương ứng.
- [ ] Đúng 1 primary CTA, đặt trong thumb zone.
- [ ] Trust signal cho màn liên quan giao dịch.
- [ ] Token semantic, không hardcode màu/spacing.
- [ ] State loading/empty/error đã định nghĩa.
- [ ] Dynamic type / responsive breakpoint đã nêu.
