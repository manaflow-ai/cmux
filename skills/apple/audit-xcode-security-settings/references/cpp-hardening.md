# C++ Standard Library Hardening and Bounds Checking

Enables safety checks in the C++ standard library and compiler-enforced bounds checking for unsafe buffer operations.

## What It Does

Two protections in one setting:

### 1. C++ Standard Library Hardening (Fast Mode)

Enables assertion checks in standard library container types:

- **Valid element access** — checks that elements exist before accessing them (applies to all containers including `std::function` and `std::optional`)
- **Valid input range** — checks that ranges passed to standard algorithms are valid (begin iterator can reach the sentinel)

These checks run in constant time. If an assertion fails, the system crashes the app.

### 2. Unsafe Buffer Usage Warnings (as Errors)

The compiler reports errors when it detects:
- Indexing an array, performing pointer arithmetic, or using unsafe C stdlib functions on raw pointers
- Calling `operator[]()` on a smart pointer referring to a list of objects
- Constructing `std::span` with a two-argument (pointer + size) constructor

## What Vulnerabilities It Mitigates

- **Out-of-bounds container access** — accessing elements beyond container size
- **Iterator invalidation** — using invalid or dangling iterators
- **Unsafe buffer access** — raw pointer arithmetic and indexing without bounds
- **Span construction errors** — creating spans with incorrect size parameters

## How to Enable

**Build setting:** `ENABLE_CPLUSPLUS_BOUNDS_SAFE_BUFFERS = Yes`

This enables both protections described above (hardened libc++ and unsafe buffer usage warnings).

**Relationship to Enhanced Security:** `ENABLE_ENHANCED_SECURITY = YES` cascades the hardened libc++ portion only (via `CLANG_CXX_STANDARD_LIBRARY_HARDENING`). It does NOT enable unsafe buffer usage warnings. `ENABLE_CPLUSPLUS_BOUNDS_SAFE_BUFFERS` is the superset — it enables both the hardened libc++ and the compiler warnings — and must be enabled separately if you want both.

## Hardening Modes

You can override the mode per-file by defining `_LIBCPP_HARDENING_MODE` **before** any standard library includes:

| Macro Value | Mode | Checks |
|---|---|---|
| `_LIBCPP_HARDENING_MODE_NONE` | None | No checks |
| `_LIBCPP_HARDENING_MODE_FAST` | Fast (default) | Constant-time checks only |
| `_LIBCPP_HARDENING_MODE_EXTENSIVE` | Extensive | Additional non-constant-time checks |
| `_LIBCPP_HARDENING_MODE_DEBUG` | Debug | All checks including debug-only assertions |

```cpp
// At the very top of the file, before any includes
#define _LIBCPP_HARDENING_MODE _LIBCPP_HARDENING_MODE_EXTENSIVE
#include <vector>
```

For more information, see [Hardening Modes](https://libcxx.llvm.org/Hardening.html) in the LLVM documentation.

## Code Changes Required

- Fix hardening assertion failures (e.g., accessing `std::vector` out of bounds, using invalidated iterators)
- Replace unsafe raw pointer operations with safe alternatives (e.g., use `std::span` with range constructors, `std::array`, or iterator-based access)
- Fix `std::span` construction to use safe constructors

## How to Disable

**Build setting:** `ENABLE_CPLUSPLUS_BOUNDS_SAFE_BUFFERS = No`

## Platform Availability

- iOS, iPadOS, macOS, visionOS
- Available on all supported hardware

## Performance and Stability Impact

- **Performance:** Low. Fast mode checks are constant-time. The overhead is typically negligible for most applications.
- **Stability:** Code with latent out-of-bounds access bugs will crash. Test with the Debug hardening mode during development to catch issues early.
