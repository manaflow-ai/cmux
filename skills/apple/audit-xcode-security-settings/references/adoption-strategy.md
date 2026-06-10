# Adoption Strategy

A recommended order for validating and addressing Xcode Enhanced Security features, from lowest risk and effort to highest.

Adding the Enhanced Security capability enables all cascaded settings at once. The phases below represent the order in which to **validate and fix issues** — not separate enablement steps. Phase 1 features are zero-cost (nothing to fix for well-behaved code), Phase 2 may need minor code changes, and Phase 3 requires active annotation or rewriting.

## Phase 1: Zero-Cost, No Code Changes

Start here. These features have no runtime cost and require no source code changes for well-behaved code.

| Feature | Why first | Reference |
|---------|----------|-----------|
| **Security Compiler Warnings** | Compile-time only. Zero runtime cost. Identifies real bugs. | `security-compiler-warnings.md` |
| **Stack Zero Initialization** | Transparent. Cannot cause crashes. Prevents info leaks. | `stack-zero-init.md` |
| **Read-Only Platform Memory** | No impact on well-behaved code. Blocks post-exploitation. | `readonly-platform-memory.md` |

**Action:** After enabling Enhanced Security, build and fix any new warnings. These features won't cause runtime issues.

## Phase 2: Low-Effort Runtime Protections

Next, validate runtime protections that require minimal or no code changes for most apps.

| Feature | Effort | Reference |
|---------|--------|-----------|
| **Runtime Restrictions** | No changes if using XPC or no IPC. Review needed only for raw Mach IPC. | `runtime-restrictions.md` |
| **Typed Allocators** | No changes for standard `malloc`/`free`. Update custom allocator wrappers if present. | `typed-allocators.md` |

**Action:** Test thoroughly. If you use raw Mach IPC, read the Mach IPC conformance guide.

## Phase 3: Annotation and Code Hardening

These features require active code changes — annotations, pointer type updates, or fixing unsafe patterns.

| Feature | Effort | Reference |
|---------|--------|-----------|
| **Pointer Authentication** | Add `__ptrauth` qualifiers to security-critical function/data pointers. Review pointer casts. | `pointer-authentication.md` |
| **C++ Stdlib Hardening** | Fix out-of-bounds container access and unsafe buffer operations. | `cpp-hardening.md` |

**Action:** Prioritize security-critical code paths first (parsers, network handlers, IPC).

Additionally, consider adopting **C Bounds Safety** (`-fbounds-safety`) as a complementary feature for C codebases — see Xcode's `bounds-safety` skill.

## Phase 4: Hardware-Dependent Protections

These require specific hardware and OS versions.

| Feature | Requirement | Reference |
|---------|------------|-----------|
| **Hardware Memory Tagging** | iPhone 17 family, M5-based Macs/iPads/Vision Pro | `hardware-memory-tagging.md` |

**Action:**
1. Enable with soft mode first — this generates simulated crash reports without terminating the app
2. Deploy soft mode to internal testers
3. Review simulated crash reports and fix memory bugs
4. Disable soft mode for production enforcement

## Decision Matrix

Use this to decide which features to prioritize based on your codebase:

| If your app... | Prioritize |
|---|---|
| Is pure Swift | Phase 1 + Runtime Restrictions + Read-Only Memory |
| Has C code | All of Phase 1-3, plus consider C Bounds Safety (separate skill) |
| Has C++ code | All of Phase 1-3, especially C++ Hardening |
| Processes untrusted input | All features, prioritize bounds checking and memory tagging |
| Uses Mach IPC | Review runtime restrictions carefully before enabling |
| Targets MTE-capable hardware (iPhone 17, M5 Macs/iPads/Vision Pro) | Consider hardware memory tagging (start with soft mode) |
| Is a DriverKit extension | All applicable features — elevated privilege means higher stakes |

## General Principles

1. **Enable Enhanced Security as a capability first** — this turns on all cascaded features at once
2. **Fix warnings before testing runtime protections** — compiler warnings often reveal the same bugs that runtime protections would crash on
3. **Test in soft mode before hard mode** — applies to hardware memory tagging
4. **Prioritize security-critical code** — parsers, network handlers, IPC, auth logic
5. **Don't skip testing** — Enhanced Security features turn latent bugs into crashes, which is the point, but you want to find them before your users do
