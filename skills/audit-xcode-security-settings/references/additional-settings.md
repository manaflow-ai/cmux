# Additional Settings

Additional diagnostic settings that can find more issues but may also produce false positives. These are applied only when the user opts in after the main audit.

## Settings

- `CLANG_WARN_SUSPICIOUS_IMPLICIT_CONVERSION = YES`
- `CLANG_ANALYZER_SECURITY_BUFFER_OVERFLOW_EXPERIMENTAL = YES`
- `CLANG_TIDY_BUGPRONE_REDUNDANT_BRANCH_CONDITION = YES`
- `CLANG_WARN_ASSIGN_ENUM = YES`
- `GCC_WARN_SIGN_COMPARE = YES`

**C++ / DriverKit / IOKit (only if C++ present):**

- `CLANG_ANALYZER_OSOBJECT_C_STYLE_CAST = YES`

**Blocks (only if ObjC, ObjC++, or C with -fblocks present):**

- `CLANG_WARN_COMPLETION_HANDLER_MISUSE = YES`

**ObjC-specific (only if ObjC/ObjC++ present):**

- `CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES`
- `CLANG_WARN_OBJC_REPEATED_USE_OF_WEAK = YES`

## Procedure

Enable relevant settings based on languages used in the project. Record decisions in the decision document.
