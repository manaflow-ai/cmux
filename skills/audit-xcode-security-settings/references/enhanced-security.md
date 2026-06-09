# Enhanced Security

Enhanced Security is an Xcode capability, not just a build setting. Enabling it fully touches **two places per target**:

1. Build settings (in pbxproj or xcconfig) — `ENABLE_ENHANCED_SECURITY` + pointer authentication.
2. Entitlements (in the target's `.entitlements` file) — the runtime-protection keys.

`ENABLE_ENHANCED_SECURITY = YES` is the build setting that turns on the compiler-driven pieces. The `com.apple.security.hardened-process` entitlement family turns on the runtime-driven pieces and is what actually provisions the capability.

## Supported Product Types

Enhanced Security only applies on iOS, macOS, visionOS, and DriverKit, to these product types. Skip any target whose product type isn't in this list (frameworks, test bundles, app extensions other than those below, etc.) or whose platform isn't one of those four.

- `com.apple.product-type.application`
- `com.apple.product-type.application.on-demand-install-capable`
- `com.apple.product-type.xpc-service`
- `com.apple.product-type.driver-extension` (**build settings only** — entitlements do not apply to DriverKit)
- `com.apple.product-type.system-extension`
- `com.apple.product-type.tool`

## Part A — Build Settings

Two settings the audit needs to resolve to `YES` on every supported target:

- `ENABLE_ENHANCED_SECURITY = YES` — listed in the capability's `requiredValues`. Cascades automatically to pointer authentication, stack zero init, security compiler warnings, typed allocators, and C++ stdlib hardening (the audit does not manipulate these cascaded settings directly).
- `ENABLE_POINTER_AUTHENTICATION = YES` — builds for arm64e. Listed in the capability's `buildSettingKeysRequiredForAllTargets`.

Both should be set at project level. The apply path:

1. Set `ENABLE_ENHANCED_SECURITY = YES` at project level. If the project uses xcconfig, set it there. Otherwise, use `UpdateProjectBuildSetting`.
2. For each target whose platform doesn't support arm64e, pre-write a target-level `ENABLE_POINTER_AUTHENTICATION = NO` override via `UpdateTargetBuildSetting` so the project-level cascade doesn't break those builds. See `pointer-authentication.md` for the full list of supported and unsupported platforms. Skip if the target already has an explicit target-level value — respect existing user intent.

## Part B — Entitlements

All keys live in the target's `.entitlements` file. Each supported target has its own; the audit walks every one.

Required when the capability is enabled:

- `com.apple.security.hardened-process = <true/>` — the main toggle. Without this, the runtime protections below are inert.
- `com.apple.security.hardened-process.enhanced-security-version-string = "2"` — selects v2 protections.

Default-ON sub-options (the audit adds these when missing):

- `com.apple.security.hardened-process.hardened-heap` — Memory Safety category. Adds extra type-isolation buckets to the allocator at runtime, regardless of compiler settings. Most effective in combination with the cascaded `CLANG_ENABLE_C_TYPED_ALLOCATOR_SUPPORT` / `CLANG_ENABLE_CPLUSPLUS_TYPED_ALLOCATOR_SUPPORT` build settings, which communicate type information from the compiler to the allocator.
- `com.apple.security.hardened-process.dyld-ro` — Runtime Protections. Marks dyld state read-only.
- `com.apple.security.hardened-process.platform-restrictions-string = "2"` — Runtime Protections. Dyld + Mach messaging restrictions.

Default-OFF sub-options (audit reports state, does **not** auto-enable):

- `com.apple.security.hardened-process.checked-allocations` and its related keys — Hardware Memory Tagging (MTE). See `hardware-memory-tagging.md` for supported hardware. Recommend soft-mode rollout when reporting state.

Deprecated — the audit removes these if present alongside `hardened-process = true`:

- `com.apple.security.hardened-process.platform-restrictions` — superseded by the `-string` variant.
- `com.apple.security.hardened-process.enhanced-security-version` — superseded by the `-version-string` variant.

Version migration: when `hardened-process = true` AND either `...version-string = "1"` OR the deprecated `...enhanced-security-version` key is present, set `...version-string = "2"` and delete the deprecated key. If `...version-string` is simply absent (no deprecated key either), it's just a missing required entitlement — add `"2"` via the normal add-entitlements step, not via this migration path.

## Settings implied by Enhanced Security

These are automatically configured when `ENABLE_ENHANCED_SECURITY = YES` and do not need to be set explicitly:

- `GCC_WARN_SHADOW` — `-Wshadow`, detects variable declarations that shadow other variables.
- `CLANG_WARN_EMPTY_BODY` — `-Wempty-body`, detects empty bodies in control flow statements.
- `ENABLE_SECURITY_COMPILER_WARNINGS` — enables additional security-focused warnings (`-Wbuiltin-memcpy-chk-size`, `-Wformat-nonliteral`, `-Warray-bounds`, etc.). See `security-compiler-warnings.md`.
- `CLANG_CXX_STANDARD_LIBRARY_HARDENING` — set to `fast` in Release builds and `debug` in Debug builds (the cascade handles per-configuration differentiation automatically). This enables the hardened libc++ runtime checks only. It does NOT enable unsafe buffer usage warnings — that requires `ENABLE_CPLUSPLUS_BOUNDS_SAFE_BUFFERS` separately (see `cpp-hardening.md`).
- `CLANG_ENABLE_C_TYPED_ALLOCATOR_SUPPORT` — communicates type information from the compiler to the allocator for C code. Works in combination with the `hardened-heap` entitlement (see below).
- `CLANG_ENABLE_CPLUSPLUS_TYPED_ALLOCATOR_SUPPORT` — same, for C++ code.

## Settings NOT covered by Enhanced Security

These must be set independently and are out of scope for this reference:

- All `CLANG_ANALYZER_SECURITY_*` checkers
- Additional `CLANG_WARN_*` / `GCC_WARN_*` diagnostics not flipped by Enhanced Security (e.g. `CLANG_WARN_SUSPICIOUS_IMPLICIT_CONVERSION`, `GCC_WARN_ABOUT_RETURN_TYPE`)
- `GCC_TREAT_IMPLICIT_FUNCTION_DECLARATIONS_AS_ERRORS`, `CLANG_TIDY_*`
- `ENABLE_C_BOUNDS_SAFETY` / `ENABLE_CPLUSPLUS_BOUNDS_SAFE_BUFFERS` (defensive programming models, separate adoption)
