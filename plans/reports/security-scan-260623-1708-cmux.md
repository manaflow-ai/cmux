# Báo cáo quét bảo mật — cmux

**Dự án:** cmux | **Ngày quét:** 2026-06-23 | **Phạm vi:** Swift app + Next.js web + Cloud VM control plane + Cloudflare worker + webviews
**Phương pháp:** Multi-dimensional scan (9 dimensions) song song + adversarial verification mỗi finding + synthesis. 26 agents, 6 false positives đã loại.

## Tóm tắt kết quả

Có **10 phát hiện đã xác nhận (confirmed): 1 medium, 9 low**. Không có critical/high. Phần lớn là lỗ hổng defense-in-depth (keychain accessibility, CSP thiếu `script-src`, plaintext fallback, cache-control) và 1 IDOR vừa (cross-user device-token hijack) có điều kiện khai thác. Không tìm thấy secret thật trong VCS, không SQL injection runtime, không command injection từ input người dùng.

## Bảng tóm tắt

| Severity | Số lượng | Category chính |
|----------|----------|----------------|
| Critical | 0 | — |
| High | 0 | — |
| Medium | 1 | authorization/IDOR |
| Low | 9 | secrets-mgmt / credential storage / info-leak / injection / input-validation-abuse / xss-CSP / authz |

| Category | Số lượng |
|----------|----------|
| authorization/IDOR | 1 |
| input-validation/abuse | 2 |
| info-leak | 1 |
| injection (quota) | 1 |
| secrets-mgmt | 1 |
| credential storage | 2 |
| xss/CSP | 1 |
| authz | 1 |

## Phát hiện (theo thứ tự severity giảm dần)

---

### [MEDIUM] device-tokens register ghi đè row APNs token của user khác (cross-user device-token hijack)

**File:** `web/app/api/device-tokens/route.ts:54-88`

**Mô tả + đường dẫn tấn công:**
`POST /api/device-tokens` authenticate caller, nhưng khi gặp `deviceToken` trùng nó reassign row cho bất kỳ ai gọi. Advisory lock keyed trên `user.id` (line 52: `hashtextextended(${user.id}, 2)`), nên 2 user khác nhau không bao giờ serialize với nhau. Code đọc `userId` của row hiện có (line 54-58), nhận thấy thuộc user khác (line 60 `existingToken?.userId !== user.id`), nhưng branch đó chỉ dùng cho per-user cap check — không bao giờ refuse. Upsert tiếp theo (lines 70-88) làm `onConflictDoUpdate` trên bare `deviceToken` với `set: { userId: user.id, ... }`, reassign row từ A → B.

**Tác động:**
- Attacker biết APNs device token của nạn nhân (64-200 hex char secret, có thể leak qua logs/MITM/compromised device) → register nó vào account mình → `POST /api/notifications/push` từ session của attacker để deliver push notification tùy ý vào iPhone vật lý của nạn nhân.
- Inverse: legitimate owner silently mất push delivery vì `/api/notifications/push` filter theo `userId`.
- Bất đối xứng với `/api/devices` (route anh em) — route đó có ownership guard chính xác (returns 403 `device_not_owned`).

**Bằng chứng:**
```typescript
const [existingToken] = await tx
  .select({ userId: deviceTokens.userId })
  .from(deviceTokens)
  .where(eq(deviceTokens.deviceToken, deviceToken))
  .limit(1);

if (existingToken?.userId !== user.id) {
  // ...chỉ dùng cho per-user cap check; falls through to overwrite
}
await tx
  .insert(deviceTokens)
  .values({ userId: user.id, deviceToken, ... })
  .onConflictDoUpdate({
    target: deviceTokens.deviceToken,
    set: { userId: user.id, bundleId: bundle.bundleId, ... }, // unconditionally reassigns ownership
  });
```

Schema (`web/db/schema.ts:131`): `uniqueIndex("device_tokens_device_token_unique").on(table.deviceToken)` là GLOBAL unique constraint (không `(userId, deviceToken)`), nên conflict path luôn fire. Peer route `/api/devices` (`web/app/api/devices/route.ts:217-219`): `if (existingDevice && existingDevice.userId !== user.id) { return { error: "device_not_owned" }; }` → 403.

Downstream (`web/app/api/notifications/push/route.ts:88`): tokens select bằng `eq(deviceTokens.userId, user.id)`, payload từ body của caller authenticated, deliver qua `sendApnsNotification`.

**Khuyến nghị sửa:**
- Trong conflict branch, refuse take-over row của user khác: `if (existingToken && existingToken.userId !== user.id)` → return 403/409 (`token_not_owned`).
- Nếu cần flow "re-claim from different account" (user reinstall, re-pair device), require prior DELETE bởi old owner hoặc explicit re-binding token.
- Mở rộng advisory lock include `deviceToken` (`hashtextextended(deviceToken, 2)`) để concurrent claims serialize.

---

### [LOW] `/api/analytics/events` chấp nhận event batch unauthenticated, không rate-limit (PostHog quota/abuse amplifier)

**File:** `web/app/api/analytics/events/route.ts:34-88`

**Mô tả + đường dẫn tấn công:**
`POST /api/analytics/events` không bao giờ reject unauthenticated request. `verifyRequest` gọi opportunistically (line 54), kết quả chỉ dùng để stamp `distinct_id` (line 83 `user?.id ?? null`); null user proceeds bình thường. Handler chỉ dựa vào shape gate (allowlist + 64KB body cap + per-batch/per-event bounds) để bound abuse. Comment defer rate limiting ("Rate limiting is deferred for Phase A", issue #5569).

Route biến web app thành open reflector → PostHog: attacker fire batched POSTs unbounded, mỗi request forward lên tới `MAX_ANALYTICS_BATCH_EVENTS` events đến PostHog dùng server-side `api_key` rewrite → consume cmux function invocations VÀ PostHog project quota (events/billing) không có IP/user rate limiting.

**Bằng chứng:**
```typescript
// Auth is read opportunistically, NOT required:
const user = await verifyRequest(request, { allowCookie: false });
// ...no `if (!user) return unauthorized()` follows...
const forwarded = await forwardToPostHog(accepted, user?.id ?? null);
```

**Khuyến nghị sửa:** Thêm anonymous edge/IP rate limit (Vercel Firewall `checkRateLimit`, primitive đã dùng trong `feedback/route.ts` và `notifications/push/route.ts`) keyed trên request IP khi không có Stack session.

---

### [LOW] VM SSH/attach endpoints return live credentials trong JSON không có `Cache-Control: no-store`

**File:** `web/services/vms/routeHelpers.ts:93-98`

**Mô tả + đường dẫn tấn công:**
`jsonResponse()` helper build response chỉ với `content-type` header, không có `Cache-Control: no-store` / `private`. Routes `POST /api/vm/[id]/ssh-endpoint` và `/api/vm/[id]/attach-endpoint` return short-lived nhưng live secrets trong JSON body: one-time Freestyle SSH password (`credential.value`), E2B `trafficAccessToken`, và đặc biệt Freestyle cmuxd RPC WebSocket lease token TTL 12 giờ (`CMUXD_WS_RPC_LEASE_TTL_SECONDS = 12 * 60 * 60` trong `freestyle.ts:40`).

Shared/intermediate HTTP cache, CDN edge, reverse proxy key trên URL+method và treat `application/json` as cacheable có thể persist credentials beyond user session. 12-hour RPC token là leak surface highest-value (grants RPC access to cmuxd daemon inside user's sandbox).

**Bằng chứng:**
```typescript
export function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}
```

Không có global Cache-Control: `web/security-headers.ts` apply CSP/Referrer-Policy/nosniff cho `/:path*` (không Cache-Control). `export const dynamic = "force-dynamic"` chỉ disable Next's own static/ISR caching — không emit no-store, không constrain fronting CDN. Revocation paths exist (`revokeActiveIdentities` tại `workflows.ts:315,350`).

**Khuyến nghị sửa:** Thêm `Cache-Control: no-store, private` (+ ideally `Pragma: no-cache`) cho responses carrying credentials. Easiest: extend `jsonResponse` set header unconditionally, hoặc set explicit trong ssh-endpoint / attach-endpoint route handlers.

---

### [LOW] `vm/[id]/exec` forwards arbitrary shell đến provider sandbox không allowlist, chỉ gated bởi VM ownership

**File:** `web/app/api/vm/[id]/exec/route.ts:43-74`

**Mô tả + đường dẫn tấn công:**
`POST /api/vm/[id]/exec` chỉ validate `command` là non-empty string và clamp `timeoutMs`; string forwarded verbatim đến provider's sandbox shell (freestyle `ref.exec({ command })`, e2b `sandbox.commands.run(command)`). By design (exec IS the feature), ownership enforced đúng qua `requireUserVm` → `findUserVm({ userId, providerVmId })`. Residual risk: abuse quota của caller — không có rate limit/concurrency cap, single command hold sandbox worker tới 15 phút (`MAX_EXEC_TIMEOUT_MS = 15 * 60 * 1000`). Malicious authenticated account tie up provider sandbox quota across `maxActiveVms` concurrent VMs.

**Bằng chứng:**
```typescript
const command = typeof body.command === "string" ? body.command.trim() : "";
if (command.length === 0) { ... }
const MAX_EXEC_TIMEOUT_MS = 15 * 60 * 1000;
const result = await runVmWorkflow(execVm({ userId: user.id, providerVmId: id, command, timeoutMs }));
```

Ownership filter: `repository.ts:363-378` `findUserVm` dùng Drizzle parameterized `eq(cloudVms.userId, input.userId) AND eq(cloudVms.providerVmId, ...)`. No rate-limiting middleware; chỉ `maxActiveVms` cap enforce tại create (default 5 free / 10 paid).

**Khuyến nghị sửa:** Không cần sanitization change (sandbox user-owned). Quota hardening: thêm per-user/per-VM concurrency cap on in-flight execs + shorter default ceiling. Nếu exec metered, count trong billing gateway alongside create credits.

---

### [LOW] CLI passes socket password vào child process qua argv (visible trong `ps`)

**File:** `CLI/cmux.swift:20419-20422` (cũng `3108-3115` accepting `--password`)

**Mô tả + đường dẫn tấn công:**
cmux CLI chấp nhận local control-socket password qua `--password <value>` argument, khi spawn codex-teams watcher forward password vào child Process's argv: `watcherArguments.insert(contentsOf: ["--password", explicitPassword], at: 2)`. Trên macOS argv visible với local users/processes khác qua `ps aux` / proc_info / Activity Monitor → local process đọc socket password. Doc advertise: "--password takes precedence, then CMUX_SOCKET_PASSWORD env var, then password saved in Settings." Preferred path là `CMUX_SOCKET_PASSWORD` env var + password file (0600 perms, constant-time verify). Defense-in-depth gap (local-only exposure), socket là unix domain socket protected bởi filesystem perms, password compare constant-time.

**Bằng chứng:**
```swift
if let explicitPassword,
   !explicitPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    watcherArguments.insert(contentsOf: ["--password", explicitPassword], at: 2)
}
```

Line `1502, 1516, 2886`: password file 0o600 perms. Line `20280` đã set `launcherEnvironment["CMUX_SOCKET_PASSWORD"] = explicitPassword` và env đó pass cho `startCodexTeamsProcess` (line 20431) → watcher đã nhận password qua env, có thể read qua `SocketPasswordResolver.resolve()` (line 1588-1598) không cần argv copy.

**Khuyến nghị sửa:** Không pass socket password qua argv. Watcher inherit `CMUX_SOCKET_PASSWORD` từ parent environment (env-var path đã first-class). Consider deprecate `--password` flag (hoặc no-op read từ file/env) để không shipped path nào put credential vào argv.

---

### [LOW] Auth tokens lưu Keychain với `kSecAttrAccessibleAfterFirstUnlock` (không WhenUnlocked / không device-only)

**File:** `Packages/Shared/CmuxAuthRuntime/Sources/CmuxAuthRuntime/TokenStores/KeychainStackTokenStore.swift:160`

**Mô tả + đường dẫn tấn công:**
Stack Auth access + refresh tokens (secrets keep user signed in, let client refresh session) viết vào data-protection keychain với `kSecAttrAccessibleAfterFirstUnlock`. Accessibility class này (a) decrypt item sau first device unlock của boot và giữ readable khi device merely locked, (b) không phải `*ThisDeviceOnly` variant → item eligible cho Keychain restore onto new/other device qua iCloud Keychain backup. Cho long-lived OAuth-style session tokens đây là weaker-than-necessary protection class: thief/forensic tool obtain device sau khi đã unlock once (common state) → đọc valid refresh token. Best practice high-value bearer tokens: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Cùng accessibility dùng cho SessionPersistence HMAC key (`Sources/SessionPersistence.swift:1271`).

**Bằng chứng:**
```swift
var insert = lookup
insert[kSecValueData as String] = data
insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
let addStatus = SecItemAdd(insert as CFDictionary, nil)
```

`rg` over `*.swift`: chỉ 2 AfterFirstUnlock uses, không `WhenUnlocked` / `ThisDeviceOnly` / `kSecAttrSynchronizable`. Shared code consumed bởi cả macOS app và iOS app (CmuxAuthRuntime under `Packages/Shared/`).

**Khuyến nghị sửa:** Dùng `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` cho access và refresh token items trong `KeychainStackTokenStore.keychainWrite`. Giữ `kSecUseDataProtectionKeychain`. Cho SessionPersistence HMAC secret (`Sources/SessionPersistence.swift:1271`), prefer `WhenUnlockedThisDeviceOnly` trừ khi surface-resume phải work trước first unlock.

---

### [LOW] FallbackTokenStore viết auth tokens (access + refresh) plaintext JSON khi Keychain failure thật

**File:** `Packages/Shared/CmuxAuthRuntime/Sources/CmuxAuthRuntime/TokenStores/FileStackTokenStore.swift:108-124`

**Mô tả + đường dẫn tấn công:**
`MacAuthComposition` luôn wrap Keychain store trong `FallbackTokenStore` (`Sources/Auth/MacAuthComposition.swift:36-41`) — fallback path serialize access + refresh tokens ra JSON document (`credentials.json`) không encryption ngoài 0600 file perms và 0700 parent dir. Fallback reached khi keychain write/read signal failure thật: trên ad-hoc Debug builds là `errSecMissingEntitlement`, nhưng branch unconditional trong Release (`FallbackTokenStore.setTokens` line 58-61). Bất kỳ Keychain error path nào trên real user machine (corrupted keychain, profile issue, MDM restrictions, code-signing/entitlement regression sau rebuild) silently drop live refresh token vào `~/Library/Application Support/cmux/<bundleID>/credentials.json` cleartext. Refresh token alone đủ mint new access tokens; kết hợp với after-first-unlock keychain accessibility → widen at-rest exposure.

**Bằng chứng:**
```swift
private func write(_ snapshot: Snapshot) {
    cache = snapshot
    let fm = FileManager.default
    let dir = fileURL.deletingLastPathComponent()
    do {
        try fm.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
```

`KeychainStackTokenStore.trySetTokens` (line 61-78) returns false trên bất kỳ `SecItemAdd`/`SecItemUpdate` failure.

**Khuyến nghị sửa:**
- Gate `FileStackTokenStore` fallback DEBUG only (hoặc `#if DEBUG`) → Release builds surface hard Keychain failure thay vì persist plaintext tokens.
- HOẶC encrypt file payload với key derived từ Keychain-stored symmetric key.
- Tối thiểu: Release log/metric fallback activation, surface state to user.

---

### [LOW] Web app CSP thiếu `script-src`/`default-src`/`style-src` — CSP gần như vô dụng chống XSS

**File:** `web/security-headers.ts:4`

**Mô tả + đường dẫn tấn công:**
Content-Security-Policy header chỉ có 3 directives: `base-uri 'self'; object-src 'none'; frame-ancestors 'none'`. Không có `default-src`, `script-src`, hay `style-src`. Vì CSP fallback `default-src` không set, browser apply hành vi mặc định (allow all) cho script execution → CSP vô hiệu hoàn toàn chống XSS: bất kỳ inline script nào (qua unsanitized `dangerouslySetInnerHTML` hoặc future bug) execute mà không bị chặn, external scripts từ bất kỳ origin nào cũng load. Header apply cho mọi route `/:path*` qua `next.config.ts` `headers()`.

**Bằng chứng:**
```typescript
export const securityHeaders = [
  { key: "Content-Security-Policy", value: "base-uri 'self'; object-src 'none'; frame-ancestors 'none'" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  ...
```

Pinned bởi `web/tests/security-headers.test.ts` (deliberate design choice). Audited mọi `dangerouslySetInnerHTML` call site: `code-block.tsx:39` (Shiki HTML từ trusted source-code), `docs-search.tsx:278` (Pagefind `excerptHtml` từ static build-generated `/pagefind/` bundle), `page.tsx` (server-generated FAQ JSON-LD), `theme-bootstrap-script.tsx` (static theme script). Không ingest unsanitized attacker-controlled data → không current exploitable XSS path. Impact: FUTURE injection bug sẽ không có CSP safety net.

**Khuyến nghị sửa:** Thêm `script-src` strict với nonce/hash-based whitelist (Next.js App Router hỗ trợ per-request nonce qua `headers()` + `Script` component). Ví dụ: `default-src 'self'; script-src 'self' 'nonce-<random>' 'strict-dynamic'; style-src 'self' 'unsafe-inline'`. Triển khai nonce generation trong middleware, inject vào script tags. Loại bỏ `'unsafe-inline'` cho `script-src`.

---

### [LOW] Unbounded Stack API subrequest amplification từ unique opaque tokens (worker)

**File:** `workers/presence/src/auth.ts:191-225`

**Mô tả + đường dẫn tấn công:**
`verifyRequest` gọi Stack (`/api/v1/users/me` + `/api/v1/teams`) mỗi uncached token. Cache keyed trên SHA-256(token), negative-cached chỉ 10s (`AUTH_NEGATIVE_CACHE_TTL_MS`), capped 1024 entries với FIFO eviction. Unauthenticated attacker send stream of distinct opaque (non-JWT, nên client-side exp short-circuit line 197-198 không fire) strings trong Authorization header; mỗi distinct token hash miss cache → force HAI `fetch()` calls đến `api.stack-auth.com`. 1024-entry cap bound memory NHƯNG KHÔNG bound subrequest rate — khi full, mỗi new token vẫn perform network round trip (eviction lines 209-213 chỉ prevent memory growth, fetch line 207 đã happen). Heartbeats 15s/host, không per-IP/per-token rate limiting trong worker → single hostile client sustain unbounded traffic chống Stack backend (và Cloudflare subrequest daily quotas). Amplification factor constant 2:1.

**Bằng chứng:**
```typescript
const cacheKey = await sha256Hex(token);
  const cached = authCache.get(cacheKey);
  if (cached && cached.expiresAt > now) return cached.user;
  authCache.delete(cacheKey);

  const user = await fetchStackUser(env, token);

  if (authCache.size >= AUTH_CACHE_MAX_ENTRIES) {
    // Drop the oldest insertion; Map preserves insertion order.
    const oldest = authCache.keys().next().value;
    if (oldest !== undefined) authCache.delete(oldest);
  }
```

`fetchStackUser` (lines 150-186): line 154 `fetch(/api/v1/users/me)`, line 172 `fetch(/api/v1/teams?user_id=me)`. Không `rate_limit`/`ratelimit` trong wrangler.toml/index.ts/auth.ts.

**Khuyến nghị sửa:** Thêm per-isolate rate limit trên Stack subrequests (token-bucket counter, hoặc short negative-cache window keyed trên prefix token hash khi token opaque). Reject tokens không parseable JWT với valid `exp` shape trước bất kỳ network call. Fail fast trên malformed bearer (too short, no two dots).

---

### [LOW] Device ownership là first-authenticated-writer-wins (không registry attestation) — worker

**File:** `workers/presence/src/core.ts:250-257`

**Mô tả + đường dẫn tấn công:**
`checkDeviceOwner` pin owner của device thành first authenticated team member announce `deviceId`. Device ids visible với toàn team, presence service không có synchronous dependency vào durable Aurora devices registry (by design, presence phải work khi web API down). Bất kỳ authenticated team member nào race claim not-yet-announced `deviceId` trước first heartbeat của legitimate owner, sau đó real owner locked out (403 `device_owner_mismatch`) đến khi manual intervention. Code document đây là accepted residual; blast radius presence-display only (attach routes và durable identity stay registry-owned).

**Bằng chứng:**
```typescript
export function checkDeviceOwner(
  existingOwner: string | undefined,
  userId: string,
): OwnerCheck {
  if (existingOwner === undefined) return { ok: true, pin: true };
  if (existingOwner === userId) return { ok: true, pin: false };
  return { ok: false, error: "device_owner_mismatch" };
}
```

Auth (`auth.ts#verifyRequest`) chỉ validate token + team membership, không device ownership. DO key durable sau pin, không re-claim sau timeout (`core.ts:240-241`). Attach/ssh endpoints auth qua VM workflow userId chống `web/db` registry, độc lập presence device ownership → impact presence-display only. Intentional/documented (`core.ts:232-248`), unit-tested.

**Khuyến nghị sửa:** Khi available, cross-check first claim chống Aurora devices registry (pin registering userId) trước pin trong DO storage, hoặc have registry issue verifiable per-device credential mà presence validate trên first contact. Document race window to operators.

---

## Phụ thuộc (Dependencies)

`bun audit` (web): phần lớn là transitive vulns kéo vào qua vercel build/dev toolchain (`@vercel/*` → `tar`, `undici`, `minimatch`, `path-to-regexp`, `ajv`, `brace-expansion`, `srvx`, `form-data`).

**Đây là build-time/dev deps, KHÔNG phải production runtime request path.** Phân biệt rõ: các vuln này ảnh hưởng build pipeline/dev server, không reach được end-user request flow trong production. Khuyến nghị upgrade vercel toolchain khi có bản sửa, nhưng không phải vấn đề cấp bách về runtime security.

## Đã loại trừ (False positives đã verify)

| Tiêu đề | File | Lý do loại |
|---------|------|------------|
| `/api/feedback` unauthenticated | `web/app/api/feedback/route.ts` | Intentionally public feedback endpoint. Recipient hard-coded `feedback@manaflow.com` (không open spam relay). Content escape qua `escapeHtml`. Zod cap 4000 chars/10 attachments/4MB. Tự disable (503) khi `rateLimitId` unset, rate-limited trên Vercel deploy. Hardening note, không exploitable flaw. |
| Cloud VM lease tokens stored unsalted SHA-256 | `web/services/vms/workflows.ts` | Tokens high-entropy (256-bit `randomBytes(32)`). SSH token từ Freestyle SDK, revoked trên destroy. Lease verify trên cmuxd daemon (nhận `token_sha256` trực tiếp), không re-read từ Postgres. Plain SHA-256 của high-entropy token là nice-to-have, không defect. |
| Ownership model per-userId (per-user vs per-team split) | `web/services/vms/repository.ts` | Tự assert NO exploitable bypass. `listUserVms` luôn include `eq(userId)` cả 2 branches. Mọi mutate qua `requireUserVm` → `findUserVm` filter `userId` từ server-authenticated `user.id`. Design note, không security flaw. |
| Bundled webview shells không có CSP meta | `Resources/agent-session-react/index.html` | WKWebView loads trusted bundled `file://` shell. Untrusted markdown qua `renderMarkdownHTML()`: `escapeMarkdownRawHTML()` + `marked.parse()` + `sanitizeRenderedHTML()` (remove script/iframe/on*/URL allowlist). Native bridge guard `isTrustedBridgeFrame`. Không demonstrable sanitizer bypass → missing CSP là hardening suggestion. |
| Subscribe forwards all original client headers to DO | `workers/presence/src/index.ts` | `set()` override verified teamId/expiresAt → DO đọc chỉ 3 headers (`x-presence-team-id`, `x-presence-expires-at`, `upgrade`), không đọc Authorization/Cookie. Inert header pass-through, code-review nit. |
| Stack error response bodies parsed as JSON before ok check | `workers/presence/src/auth.ts` | Guard `if (!meResponse.ok) return null;` chạy BEFORE `await meResponse.json()`. Không echo Stack response ra client. Operational observability concern, không adversarial impact. |

## Khuyến nghị ưu tiên (top actions)

1. **[MEDIUM — ưu tiên cao nhất]** Sửa cross-user device-token hijack (`web/app/api/device-tokens/route.ts:60-88`): thêm ownership guard `if (existingToken && existingToken.userId !== user.id) return 403/409` trước upsert; mở rộng advisory lock keyed thêm `deviceToken`. Đây là finding duy nhất có cross-user impact thật (push notification injection + silent push loss).

2. **[LOW — Cluster auth token at-rest]** Gom 2 finding keychain accessibility (`KeychainStackTokenStore.swift:160`) + plaintext fallback (`FileStackTokenStore.swift:108-124`) thành 1 fix: `WhenUnlockedThisDeviceOnly` + gate fallback DEBUG-only hoặc encrypt payload. Combo này giảm significant at-rest exposure của live refresh token.

3. **[LOW — CSP]** Thêm `default-src 'self'; script-src 'self' 'nonce-<random>' 'strict-dynamic'` vào `web/security-headers.ts` (cập nhật đồng thời test pin). Cheap defense-in-depth cho mọi future injection bug.

4. **[LOW — Cache-Control credentials]** Extend `jsonResponse` (`routeHelpers.ts:93-98`) set `Cache-Control: no-store, private` — đặc biệt relevant cho 12-hour cmuxd RPC lease token.

5. **[LOW — CLI argv leak]** Drop `--password` argv forwarding (`CLI/cmux.swift:20419-20422`), watcher đã nhận env var — fix 1-line, loại bỏ local password harvest path.

6. **[LOW — Rate limiting cluster]** Thêm edge/IP rate limit cho `/api/analytics/events` + per-isolate Stack subrequest limit trong worker — bound quota/cost amplification từ unauthenticated callers.

7. **[LOW — exec concurrency]** Per-user/per-VM concurrency cap cho `vm/[id]/exec` + shorter default timeout ceiling để chống quota tie-up.

8. **[LOW — presence device race]** Cross-check Aurora registry trước pin first-owner; document race window.

---

**Câu hỏi chưa giải quyết:** Không. Tất cả 10 confirmed findings đã verify end-to-end với cited lines; 6 false positives đã loại với lý do rõ.
