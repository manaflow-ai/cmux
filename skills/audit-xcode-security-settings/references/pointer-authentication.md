# Pointer Authentication

Pointer authentication protects against control-flow hijacking attacks by signing pointers with cryptographic metadata and verifying the signatures before use.

## What It Does

When enabled, Xcode builds your app for the **arm64e** architecture and enables pointer authentication. The system:

1. Generates signature metadata for pointers your app creates (memory allocation, C++ object construction)
2. Validates that signatures are unchanged when your app accesses memory through those pointers
3. Crashes your app if a pointer's signature is invalid

This prevents an attacker from overwriting function pointers or return addresses to redirect your app's control flow.

## What Vulnerabilities It Mitigates

- **Control-flow hijacking** — overwriting function pointers, vtable pointers, or return addresses
- **ROP/JOP attacks** — chaining existing code gadgets by corrupting pointer values
- **Code injection via pointer corruption** — modifying data pointers to point to attacker-controlled memory

## How to Enable

**Xcode UI:** Signing & Capabilities > Enhanced Security > check "Authenticate Pointers"

**Build setting:** `ENABLE_POINTER_AUTHENTICATION = Yes`

This is enabled by default when you add the Enhanced Security capability.

For detailed usage, see [Improving control flow integrity with pointer authentication](https://developer.apple.com/documentation/Apple-Silicon/improving-control-flow-integrity-with-pointer-authentication).

## How to Disable

**Xcode UI:** Uncheck "Authenticate Pointers" in the Enhanced Security capability

**Build setting:** `ENABLE_POINTER_AUTHENTICATION = No`

## Swift Package Manager Support

Swift Package dependencies are not automatically built for arm64e when the main project enables pointer authentication. To build SPM packages with arm64e, set workspace-level flags in the project's embedded workspace settings.

For a `.xcodeproj` (which contains an implicit workspace at `MyProject.xcodeproj/project.xcworkspace/`):

```bash
plutil -create xml1 MyProject.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings
plutil -insert iOSPackagesShouldBuildARM64e -bool YES MyProject.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings
plutil -insert macOSPackagesShouldBuildARM64e -bool YES MyProject.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings
plutil -insert visionOSPackagesShouldBuildARM64e -bool YES MyProject.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings
```

For a standalone `.xcworkspace`:

```bash
plutil -create xml1 MyWorkspace.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings
plutil -insert iOSPackagesShouldBuildARM64e -bool YES MyWorkspace.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings
plutil -insert macOSPackagesShouldBuildARM64e -bool YES MyWorkspace.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings
plutil -insert visionOSPackagesShouldBuildARM64e -bool YES MyWorkspace.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings
```

Set the flags for each platform your project targets.

For binary SPM dependencies (XCFrameworks), the XCFramework must include an arm64e slice. If it only contains arm64, linking will fail. Contact the dependency vendor for a universal (arm64 + arm64e) build.

## Platform Availability

**Platforms that support arm64e:**
- iOS / iPadOS (SDKROOT: `iphoneos`)
- macOS (SDKROOT: `macosx`)
- visionOS (SDKROOT: `xros`)
- DriverKit (SDKROOT: `driverkit`)

**Platforms that do NOT support arm64e:**
- watchOS (SDKROOT: `watchos`)
- tvOS (SDKROOT: `appletvos`)
- Simulator (any `*simulator` SDKROOT)

Requires arm64e-capable hardware (A12 chip or later, M1 or later).

When `ENABLE_ENHANCED_SECURITY = YES` cascades `ENABLE_POINTER_AUTHENTICATION = YES` project-wide, targets on non-arm64e platforms need an explicit target-level `ENABLE_POINTER_AUTHENTICATION = NO` override to prevent build failures. Detect via `SDKROOT` or `SUPPORTED_PLATFORMS`.

## Performance and Stability Impact

- **Performance:** Low overhead. Pointer signing/verification is done in hardware.
- **Stability:** Code that manipulates raw pointers, casts between function pointer types, or uses inline assembly with pointers may crash. Test thoroughly.
- **Compatibility:** arm64e binaries are separate from arm64. Need to rebuild dependencies as arm64e. **If there are binary dependencies that you don't have the source code for, you will need to reach out to your dependency vendor to get a universal (arm64 and arm64e) version of the dependency.
