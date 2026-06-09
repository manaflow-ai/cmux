# Stack Zero Initialization

Stack zero initialization automatically zeroes out stack variables when they are created, preventing information leaks from uninitialized memory.

## What It Does

The compiler initializes all automatic (stack) variables in your code with zeroes. Without this, stack memory retains whatever values were left by previous function calls, which can leak sensitive data if a variable is used before explicit initialization.

## What Vulnerabilities It Mitigates

- **Information disclosure via uninitialized stack variables** — reading sensitive data left on the stack from a previous function call
- **Use-of-uninitialized-value bugs** — using a variable before assigning it a value, leading to undefined behavior
- **Stack-based exploitation** — leveraging predictable uninitialized values to influence control flow

## How to Enable

**Build setting:** `CLANG_ENABLE_STACK_ZERO_INIT = Yes`

This is enabled by default when you add the Enhanced Security capability.

## Code Changes Required

None. This is a transparent compiler behavior change.

## How to Disable

**Build setting:** `CLANG_ENABLE_STACK_ZERO_INIT = No`

## Platform Availability

- iOS, iPadOS, macOS, visionOS
- Available on all supported hardware

## Performance and Stability Impact

- **Performance:** Minimal. The compiler inserts zero-initialization instructions for stack variables. In most code paths this is negligible.
- **Stability:** This change can only improve stability. If your code relied on reading uninitialized stack values (a bug), the behavior changes — variables will now consistently be zero instead of containing garbage.

## Why This Feature Is Low-Risk

Stack zero initialization is one of the safest Enhanced Security features to adopt:
- No source code changes required
- No new crash scenarios (zeroing memory cannot cause crashes)
- Minimal performance impact
- Catches a real class of security bugs

This should be one of the first features you enable.
