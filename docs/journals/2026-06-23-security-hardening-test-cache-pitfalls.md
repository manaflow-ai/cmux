# t3-env singleton + bun mock.module: shared module cache sinkhole trong test suite

**Date**: 2026-06-23 20:03
**Severity**: High
**Component**: web test suite (analytics + notifications-push routes)
**Status**: Resolved (fix local, CI to verify)

## What Happened

Trong nhánh `security-hardening`, thêm rate-limit cho analytics route bỗng làm notifications-push test thất bại một cách bí ẩn: route trả 413 (đúng khi không có limiter id) thay vì 429. Nhìn的第一眼 giống `mock.module` collision giữa 2 file test.

## The Brutal Truth

Mất mấy vòng debug mới nhận ra thủ phạm không phải mock mà là module singleton cache của chính t3-env. Cảm giác bực mình vì test "pass" nhưng thực ra đang skip assertion vì route nhận sai env. Sai lầm nghiêm trọng: một test có vẻ green nhưng hoàn toàn không kiểm tra gì.

## Technical Details

- `web/app/api/notifications-push/route.ts` đọc `env.CMUX_PUSH_RATE_LIMIT_ID` qua `import { env }` (t3 createEnv singleton).
- `web/app/api/analytics/route.ts` (theo thứ tự alphabet đứng trước) cũng import `env` → bun cache singleton TRƯỚC khi push test set `process.env.CMUX_PUSH_RATE_LIMIT_ID`.
- Push test set env muộn → singleton đã cache giá trị rỗng → limiter id undefined → route SILENTLY bỏ qua rate limit → trả 413 thay vì 429.
- Cùng loại bug thứ hai: analytics route `import { checkRateLimit } from "@vercel/firewall"` (static) cache module khi analytics test load route → mock.module của push test bị shadow.

## Root Cause Analysis

1. **t3-env là module singleton**: giá trị `process.env` được freeze tại lần import đầu tiên. Thứ tự import file test trong cùng process quyết định cache.
2. **bun `mock.module` cross-file poisoning**: static import của một route kéo module vào cache trước khi test khác kịp mock. Dynamic import chỉ trong nhánh conditional tránh được.

## Lessons Learned

- **t3-env singleton**: route nào test import sớm nên đọc `process.env.X` trực tiếp (như `process.env.VERCEL`), không qua `env`.
- **bun mock.module**: với module route chỉ conditionally cần, dùng `await import("...")` lazy trong nhánh cụ thể. Static import đầu độc cross-file module cache khi sibling test cũng mock cùng module.
- **Debugging clue**: một rate-limited route trả sai status code trong suite nhưng đúng khi isolate → nghi ngờ shared singleton cache ngay lập tức.

## Next Steps

- CI chạy full web suite (143 tests) confirm 0 fail. Owner: CI. Khi: pre-merge.
- Owner backend: provision Vercel Firewall rule id `CMUX_ANALYTICS_RATE_LIMIT_ID`.
