# Handoff prompt — security-hardening (phiên tiếp theo)

> Dán nguyên khối dưới đây làm tin nhắn đầu tiên của phiên tiếp theo (sau khi xoá ngữ cảnh). Memory + journal đã được ghi, sẽ auto-load.

---

## PROMPT (copy từ đây)

Tiếp tục công việc security-hardening trên repo cmux (CWD: /Users/thailq/solo-dev/cmux). Ngữ cảnh đã bị xoá — đọc các tài liệu sau trước khi làm gì:

1. **Memory** (đã auto-load qua MEMORY.md): `~/.claude/projects/-Users-thailq-solo-dev-cmux/memory/` — đặc biệt `cmux-security-hardening.md` (trạng thái nhánh), `cmux-build-env-constraints.md`, `cmux-nextjs16-conventions.md`, `cmux-test-isolation-pitfalls.md`.
2. **Kế hoạch**: `~/.claude/plans/logical-forging-deer.md`.
3. **Báo cáo scan**: `plans/reports/security-scan-260623-1708-cmux.md`.
4. **Journal bài học**: `docs/journals/2026-06-23-security-hardening-*.md` (3 file).
5. **Git**: `git log --oneline origin/main..security-hardening` và `git diff origin/main...security-hardening`.

**Trạng thái**: nhánh `security-hardening`, 14 commit, CHƯA push. Đã implement xong 10 fix (1 MEDIUM device-token hijack + 9 LOW). Verify đã pass ở đây: web suite 143/0 fail, worker 139/0 fail, web typecheck 0 error, `next build` OK, SwiftPM `CmuxAuthRuntime` build OK. KHÔNG build được app macOS locally (thiếu zig + Xcode — xem memory).

**Việc cần làm (theo thứ tự)**:
1. **Squash/rebase** lịch sử nhánh (hiện có churn: CSP nonce → proxy.ts fixup → static CSP revert). Gộp thành commit sạch theo nhóm fix; GIỮ two-commit red/green cho device-token hijack (commit test fail trước, fix sau) theo policy CLAUDE.md.
2. **Push + mở PR** tới `manaflow-ai/cmux` (dùng `gh`). CI sẽ verify: (a) Swift app-target build (SessionPersistence.swift, CLI/cmux.swift), (b) DB test red→green cho device-token với `CMUX_DB_TEST=1`.
3. **Op/provisioning**: tạo Vercel Firewall rule `CMUX_ANALYTICS_RATE_LIMIT_ID` cho analytics rate-limit (route degrade OK khi thiếu).
4. **Quyết định CSP**: hiện là static restrictive (`web/security-headers.ts`, script-src 'self' 'unsafe-inline'). Nếu muốn nonce-based mạnh hơn → phải forward nonce qua REQUEST headers (`NextResponse.next({request:{headers}})`), KHÔNG qua response headers, và runtime-verify (DevTools không CSP violation). Xem memory `cmux-nextjs16-conventions.md`.

**Lưu ý quan trọng** (bẫy đã gặp, xem journal/memory): Next 16 dùng `proxy.ts` không phải `middleware.ts`; route nào test import sớm hãy đọc `process.env` thay vì singleton `env`; lazy-import module conditionally-needed; SecItemUpdate không đổi accessibility (phải delete-then-add); KHÔNG claim app build pass khi chưa build được.

Bắt đầu bằng việc đọc 5 tài liệu trên, rồi báo cáo tóm tắt trạng thái + đề xuất kế hoạch squash trước khi thực hiện.

## (hết prompt)

## Ghi chú cho phiên hiện tại
- Memory dir tạo mới: `~/.claude/projects/-Users-thailq-solo-dev-cmux/memory/` (5 file + MEMORY.md).
- Journal: `docs/journals/` (3 file, ngày 2026-06-23).
- Không push gì; không đổi code thêm.
