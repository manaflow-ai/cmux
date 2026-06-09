# Security Compiler Warnings

Enhanced Security enables a set of compiler warnings that help identify potentially insecure C and C++ code patterns at build time.

## What It Does

Enables two categories of compiler warnings:

### Standard Warnings (always-on with Enhanced Security)

| Warning Flag | What It Detects |
|---|---|
| `-Wshadow` | Variable declarations that shadow other variables or type aliases |
| `-Wempty-body` | Empty bodies in control flow statements (`if`, `for`, `while`) |

### Additional Security Warnings

Enabled via the `ENABLE_SECURITY_COMPILER_WARNINGS` build setting:

| Warning Flag | What It Detects |
|---|---|
| `-Wbuiltin-memcpy-chk-size` | `memcpy` destination buffer smaller than copy size |
| `-Wformat-nonliteral` | `printf`-style format string that isn't a string literal |
| `-Warray-bounds` | Array index before beginning or past end of array; array argument smaller than function expects |
| `-Warray-bounds-pointer-arithmetic` | Pointer arithmetic resulting in out-of-bounds pointer |
| `-Wsuspicious-memaccess` | Suspicious memory operations: acting on vtable pointers, transposed `memset` args, non-trivially-copyable objects, zero-size operations |
| `-Wsizeof-array-div` | Incorrect `sizeof` calculation for array element count due to wrong types |
| `-Wsizeof-pointer-div` | `sizeof` returning pointer size instead of array size |
| `-Wreturn-stack-address` | Returning address of a local (stack) variable to the caller |

## What Vulnerabilities It Mitigates

- **Buffer overflows** — `memcpy` size mismatches, array bounds violations
- **Format string attacks** — non-literal format strings that an attacker could control
- **Use-after-return** — returning pointers to stack-allocated data
- **Logic bugs** — variable shadowing, empty control flow bodies, transposed arguments

## How to Enable

**Build settings:**
- `-Wshadow`: `GCC_WARN_SHADOW = Yes`
- `-Wempty-body`: `CLANG_WARN_EMPTY_BODY = Yes`
- Additional security warnings: `ENABLE_SECURITY_COMPILER_WARNINGS = Yes`

All are cascaded automatically when `ENABLE_ENHANCED_SECURITY = YES` — no manual setup needed if Enhanced Security is enabled.

## Code Changes Required

Fix the warnings. Common fixes include:
- Rename shadowed variables
- Add bounds checks before array access
- Use string literals for format strings, or mark intentional non-literal formats with appropriate attributes
- Fix `sizeof` calculations to use the correct types
- Remove or populate empty control flow bodies

## How to Disable

- `-Wshadow`: `GCC_WARN_SHADOW = No`
- `-Wempty-body`: `CLANG_WARN_EMPTY_BODY = No`
- Additional security warnings: `ENABLE_SECURITY_COMPILER_WARNINGS = No`

## Platform Availability

- All platforms — these are compile-time checks with no runtime component

## Performance and Stability Impact

- **Performance:** Zero runtime cost. These are compile-time warnings only.
- **Stability:** No runtime behavior change. Fixing the warnings improves code correctness.

## Why This Feature Is Low-Risk

Security compiler warnings are the safest Enhanced Security feature:
- Zero runtime cost
- No behavior changes — only build-time diagnostics
- Warnings identify real bugs that should be fixed regardless of security posture

Enable this first, before any other Enhanced Security feature.
