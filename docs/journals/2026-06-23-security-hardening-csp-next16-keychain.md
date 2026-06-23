# Next 16 CSP nonce, `proxy.ts`, và Keychain accessibility: ba bẫy không hiển nhiên

**Date**: 2026-06-23 20:03
**Severity**: Medium
**Component**: web CSP middleware / Swift Keychain (`SessionPersistence.swift`)
**Status**: Resolved (CSP static; Keychain fix local, CI to verify app-target)

## What Happened

Ba pitfall rời rặc cùng nằm trong một nhánh security-hardening, mỗi cái đều đáng một entry nhưng gộp vì chung chủ đề "API contract không hiển nhiên":

1. **Next 16 đổi tên `middleware.ts` → `proxy.ts`**. Tạo `web/middleware.ts` cạnh `web/proxy.ts` có sẵn → build error "Both middleware file and proxy file detected. Please use proxy.ts only."
2. **CSP nonce qua response header không tới `headers()`** trong server component. `headers()` trả REQUEST headers; set `response.headers.set("x-nonce", ...)` chỉ gửi về client, layout đọc `headers().get("x-nonce")` = "" → inline theme script bị chính CSP block với `nonce=""`.
3. **`SecItemUpdate` không đổi được `kSecAttrAccessible`** cho item đã tồn tại. Migration AfterFirstUnlock → AfterFirstUnlockThisDeviceOnly chỉ áp trên nhánh `SecItemAdd`; user cũ đi nhánh `SecItemUpdate` success → không bao giờ re-add → migration không có tác dụng.

## The Brutal Truth

Ba bug này đều giống nhau ở bản chất: **API có hai path (request/response header; add/update; middleware/proxy) và mình đoán sai path nào áp dụng**. CSP nonce đặc biệt đau vì không runtime-verify được local — một code review mới bắt được. Nếu không review, ta sẽ ship một CSP "có vẻ strict" mà thực ra hoàn toàn vô hiệu với inline script.

## Technical Details

- Next 16: file là `proxy.ts`. `middleware.ts` không còn tồn tại. cmux đã dùng `proxy.ts` (intl + redirects).
- Nonce CSP đúng pattern: forward nonce qua REQUEST header bằng `NextResponse.next({ request: { headers } })`. Thread qua next-intl proxy phức tạp → không verify được local.
- Quyết định: fallback **static restrictive CSP** (`script-src 'self' 'unsafe-inline'`...) áp qua `next.config.ts headers()` cho mọi route. Đơn giản, không cần threading runtime.
- Keychain FIX: delete-then-add trên mỗi write → accessibility luôn re-apply (migrate trên lần refresh token kế tiếp).

## Root Cause Analysis

- Giả định "response header = headers()" sai về contract App Router. Static analysis không phát hiện vì type-check qua hết.
- Giả định "SecItemUpdate cho mọi attribute" sai — accessibility class change unreliable qua update.
- Giả định "middleware.ts vẫn hoạt động trên Next 16" sai — đã rename.

## Lessons Learned

- **Nonce CSP trong App Router**: cần request-header forwarding, KHÔNG phải response headers. Verify runtime, đừng tin static analysis.
- **Keychain accessibility change**: delete + re-add; update unreliable.
- **Next major version**: kiểm tra tên file middleware/proxy trước khi tạo. Trên Next 16 là `proxy.ts`.

## Next Steps

- CI verify app-target Swift build (`Sources/SessionPersistence.swift`, `CLI/cmux.swift`) — môi trường dev này không build được (xem entry build-env).
- Squash/rebase nhánh trước PR (history churn: CSP nonce → proxy fixup → static CSP revert).
