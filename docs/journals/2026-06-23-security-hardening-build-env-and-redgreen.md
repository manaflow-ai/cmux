# Local app build không khả thi + two-commit red/green: cái bẫy của "test pass" giả

**Date**: 2026-06-23 20:03
**Severity**: Medium
**Component**: local build env / regression test workflow
**Status**: Ongoing (CI-dependent)

## What Happened

Hai phát hiện về workflow hơn là code:

1. **Môi trường dev này không build được cmux app local**: thiếu `zig` (cần cho GhosttyKit.xcframework) và chỉ có CommandLineTools (không full Xcode → `xcodebuild` refuse). `reload.sh` abort ngay trên missing zig. Chỉ SwiftPM package `CmuxAuthRuntime` build được qua `swift build`.
2. **Two-commit red/green policy (CLAUDE.md) thật sự có giá trị**: cho device-token hijack fix (MEDIUM), commit 1 = failing test (POST cùng token cho user thứ 2 → expect 403), commit 2 = fix. Test fail làm bug visible trong PR CI check history.

## The Brutal Truth

Điều đau ở đây là **"test pass" không có nghĩa là "test chạy"**. Bẫy thật sự:

- DB-gated test cần `CMUX_DB_TEST=1` + Postgres chạy. Local container không start được vì chỉ có `docker compose` v2, không có `docker-compose` v1. Red/green được chứng minh structural, defer sang CI.
- Tương tự `cmuxTests/*.swift` phải wire vào `project.pbxproj` — file nằm trong worktree mà không có `PBXFileReference` + `PBXSourcesBuildPhase` thì Xcode silently ignore, CI báo "Executed 0 tests" không phân biệt được với green thật (đã có trong CLAUDE.md pitfalls, nhưng dễ quên).

## Technical Details

- `swift build` package `CmuxAuthRuntime`: OK. App-target `Sources/SessionPersistence.swift`, `CLI/cmux.swift`: không compile được local.
- Workaround: `swift build` từng package cho token-store code; app-target Swift flag là "CI-verified".
- Device-token hijack: fix ở backend route + DB test. Web suite 143 pass, worker suite 139 pass, `next build` OK, web typecheck 0 errors.

## Root Cause Analysis

- Giả định "local build luôn khả năng" sai — phụ thuộc zig + full Xcode.
- Giả định "test pass = test chạy" sai khi có gate env (`CMUX_DB_TEST`) hoặc wiring requirement (pbxproj).

## Lessons Learned

- Đừng assume local app build khả thi. `swift build` package riêng; flag app-target Swift là CI-verified.
- Two-commit red/green cho bug fix: commit 1 failing test, commit 2 fix. CI check history làm bug visible.
- DB test cần Postgres chạy + `CMUX_DB_TEST=1`. Kiểm tra `docker compose` (v2) vs `docker-compose` (v1).
- `cmuxTests/*.swift`: verify wiring vào `project.pbxproj`, hoặc sẽ thấy "Executed 0 tests" giả-green.

## Next Steps

- CI verify: (a) Swift app-target build, (b) DB test red→green cho device-token với `CMUX_DB_TEST=1`. Owner: CI. Khi: pre-merge.
- Owner: squash/rebase nhánh `security-hardening` (14 commit, history churn) trước PR.
- Unresolved: op cần provision `CMUX_ANALYTICS_RATE_LIMIT_ID` trên Vercel Firewall.
