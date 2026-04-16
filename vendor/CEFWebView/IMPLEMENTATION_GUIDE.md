# CEFWebView: Implementation Guide

**Version:** 1.0 (Package Migration Phase)  
**Last Updated:** 2026-04-14  
**Status:** In Progress - Core Migration Complete

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Getting Started](#getting-started)
4. [Building the Package](#building-the-package)
5. [Integration with Apps](#integration-with-apps)
6. [Helper App Bundles](#helper-app-bundles)
7. [Multi-Process vs Single-Process](#multi-process-vs-single-process)
8. [Public API Reference](#public-api-reference)
9. [Troubleshooting](#troubleshooting)
10. [Known Issues](#known-issues)

---

## Overview

CEFWebView is a **Swift package** that brings the Chromium Embedded Framework (CEF) to macOS SwiftUI applications. It provides a drop-in replacement for WKWebView with support for:

- **Chromium rendering engine** - Full WebRTC, V8 JavaScript, modern web standards
- **Multi-process architecture** - Separate GPU, renderer, and utility processes for stability
- **SwiftUI integration** - `NSViewRepresentable`-based `CEFWebView` view
- **Observable state** - `CEFWebViewState` with `@Observable` for reactive updates
- **C++ API** - Uses CEF C++ bindings (not C API) for automatic memory management

### Why CEFWebView Over WKWebView?

| Feature | WKWebView | CEFWebView |
|---------|-----------|-----------|
| **Chromium Extensions** | ❌ Not supported | ✅ Full support (future) |
| **WebRTC** | ⚠️ Limited | ✅ Full |
| **V8 JavaScript** | ❌ JavaScriptCore | ✅ V8 engine |
| **DevTools** | ❌ Limited | ✅ Remote DevTools protocol |
| **Custom PDF Rendering** | ❌ System PDF | ✅ PDFium |
| **Customizable UI** | ⚠️ Limited | ✅ Full control |
| **Process Model** | System-managed | ✅ Custom multi-process |

---

## Architecture

### Package Structure

```
CEFWebView/
├── Package.swift                              # Swift Package definition
├── build_cpp.sh                               # Builds CEF C++ wrapper
├── fix_cef_framework.sh                       # Fixes symlinks after embedding
├── Frameworks/                                # CEF binaries (git-ignored)
│   ├── Chromium Embedded Framework.framework/
│   ├── libcef_dll_wrapper.a
│   └── include/                               # CEF C++ headers
│
└── Sources/
    ├── CEFWrapper/                            # Objective-C++ target (private)
    │   ├── include/
    │   │   └── CEFWrapper.h                   # Public ObjC interface
    │   └── CEFWrapper.mm                      # C++ implementation
    │
    ├── CEFWebView/                            # Swift library (public)
    │   ├── CEFWebView.swift                   # NSViewRepresentable view
    │   ├── CEFWebViewState.swift              # @Observable state
    │   └── CEFBridge.swift                    # CEF lifecycle manager
    │
    ├── CEFHelper/                             # Executable (GPU, utility)
    │   └── main.c                             # Subprocess entry point
    │
    └── CEFHelperRenderer/                     # Executable (renderer)
        └── main.c                             # Renderer subprocess entry
```

### Process Architecture

```
ChromiumWebView.app (Main Process)
├── Runs CEFApplication (message pump, lifecycle)
├── Creates CEFBrowserHost (wraps CEF browser instance)
└── Launches helper subprocesses:
    ├── CEFHelper (--type=gpu-process)         → GPU rendering
    ├── CEFHelper (--type=utility --utility-sub-type=network.mojom.NetworkService)  → Network
    ├── CEFHelper (--type=utility --utility-sub-type=storage.mojom.StorageService)  → Storage
    └── CEFHelperRenderer (--type=renderer)    → Page rendering
```

### Data Flow

```
SwiftUI View (ContentView)
    ↓
@State CEFWebViewState
    ↓
CEFWebView (NSViewRepresentable)
    ↓
CEFApplication (singleton, manages CEF lifecycle)
    ↓
CEFBrowserHost (wraps CEF browser)
    ↓
ChromiumClient (C++ class, receives callbacks)
    ↓
Chromium Embedded Framework.framework
    ↓
Subprocess (renderer, GPU, network)
```

### Why C++ API Instead of C API?

CEFWebView uses the **CEF C++ API** instead of the C API for critical memory safety reasons:

- **C API**: Manual ref-counting with offset arithmetic. One mistake = `free()` crash on wrong pointer.
- **C++ API**: `CefRefPtr<T>` smart pointers handle ref-counting automatically via `IMPLEMENT_REFCOUNTING` macro.

**Result**: Certain categories of memory management bugs are structurally impossible. See `CEF_API_MIGRATION.md` for details.

---

## Getting Started

### Prerequisites

1. **macOS 15+** (Swift 6 required)
2. **Xcode 16+** with Swift 6 language mode
3. **CEF Binaries** - Downloaded and built via `build_cpp.sh`
4. **Git** - For cloning the repo

### Quick Start (Using CEFWebView Package)

1. **Add as a Swift package dependency:**
   ```swift
   // In your app's Package.swift or Xcode project
   .package(path: "../CEFWebView")
   ```

2. **Import in your Swift code:**
   ```swift
   import CEFWebView
   
   struct ContentView: View {
       @State private var url: URL? = URL(string: "https://google.com")
       @State private var webState = CEFWebViewState()
       
       var body: some View {
           CEFWebView(url: $url, state: $webState)
       }
   }
   ```

3. **Build the package:**
   ```bash
   cd CEFWebView
   ./build_cpp.sh  # Populates Frameworks/ with CEF binaries
   swift build     # Builds CEFWrapper, CEFWebView, and helpers
   ```

4. **In your Xcode app project:**
   - Add `import CEFWebView` to your Swift files
   - See "Integration with Apps" section for helper app bundle setup

---

## Building the Package

### Step 1: Populate CEF Binaries

The `build_cpp.sh` script:
1. Finds the CEF binary distribution in `./CEF/cef_binary_*/`
2. Builds the C++ wrapper library (`libcef_dll_wrapper.a`)
3. Copies the framework and headers to `./Frameworks/`
4. Restructures the framework to macOS versioned layout

**Run:**
```bash
cd CEFWebView
./build_cpp.sh
```

**Expected output:**
```
🚀 Building CEFWebView CEF dependencies...
📍 Found CEF at: /path/to/CEFWebView/CEF/cef_binary_123.0.0_macos_arm64
🔨 Building CEF C++ wrapper...
✓ CEF C++ wrapper built
📦 Copying static library and headers...
✓ Copied libcef_dll_wrapper.a and headers
📚 Copying dynamic Chromium Embedded Framework...
✓ Copied Chromium Embedded Framework to Frameworks/
✅ Build complete! Frameworks/ is ready for Xcode.
```

### Step 2: Build Swift Package

```bash
swift build -c release  # or 'debug' for development
```

**What gets built:**
- `libcef_dll_wrapper.a` is linked into the CEFWrapper target
- `CEFWrapper.mm` compiles to Objective-C++ object files
- Swift stdlib wraps it as the `CEFWebView` library product
- `CEFHelper` and `CEFHelperRenderer` executables compiled

### Step 3: Verify Build

```bash
# Check framework was created
ls -la Frameworks/Chromium\ Embedded\ Framework.framework

# Check static library
ls -la Frameworks/libcef_dll_wrapper.a

# Check headers
ls -la Frameworks/include/ | head -20
```

---

## Integration with Apps

### For Xcode App Projects

#### 1. Add Package Dependency

In Xcode:
- File → Add Packages
- Enter path: `../CEFWebView` (or absolute path)
- Select "Add to Target: YourApp"

Or in `Package.swift`:
```swift
dependencies: [
    .package(path: "../CEFWebView")
]
```

#### 2. Update Your App Code

**AppDelegate (lifecycle):**
```swift
import SwiftUI
import CEFWebView

@main
struct YourApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        CEFApplication.shared.shutdown()
    }
}
```

**ContentView (UI):**
```swift
import SwiftUI
import CEFWebView

struct ContentView: View {
    @State private var url: URL? = URL(string: "https://google.com")
    @State private var webState = CEFWebViewState()
    
    var body: some View {
        VStack(spacing: 0) {
            // Navigation toolbar
            HStack {
                Button(action: { webState.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!webState.canGoBack)
                
                Button(action: { webState.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!webState.canGoForward)
                
                TextField("URL", text: .constant(url?.absoluteString ?? ""))
                    .onSubmit {
                        if let newURL = URL(string: urlInput) {
                            url = newURL
                        }
                    }
            }
            .padding()
            
            // Web view
            CEFWebView(url: $url, state: $webState)
                .background(.white)
        }
    }
}
```

#### 3. Configure Build Settings

**Build.xcconfig** (in your app project):
```bash
// Point to CEFWebView package Frameworks directory
FRAMEWORK_SEARCH_PATHS = $(SRCROOT)/../CEFWebView/Frameworks

// Swift settings
SWIFT_VERSION = 6.0
SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor

// Allow build phase scripts to read $SRCROOT
ENABLE_USER_SCRIPT_SANDBOXING = NO

// Entitlements for JIT and Mach IPC
CODE_SIGN_ENTITLEMENTS = YourApp/YourApp.entitlements
```

**Entitlements (YourApp.entitlements):**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.get-task-allow</key>
    <true/>
</dict>
</plist>
```

#### 4. Create Helper App Bundles (Build Phase)

Add a "Run Script" build phase in Xcode to create the helper app structures.

**Script:**
```bash
# Get the built helper executables from SPM build directory
HELPER_EXEC="${BUILD_DIR}/Release/CEFHelper"
RENDERER_EXEC="${BUILD_DIR}/Release/CEFHelperRenderer"

# Determine app framework path
FRAMEWORKS="${BUILT_PRODUCTS_DIR}/${EXECUTABLE_FOLDER_PATH}/../Frameworks"

# Create CEFHelper.app bundle
HELPER_APP="${FRAMEWORKS}/CEFHelper.app"
mkdir -p "${HELPER_APP}/Contents/MacOS"
cp "${HELPER_EXEC}" "${HELPER_APP}/Contents/MacOS/CEFHelper"
chmod +x "${HELPER_APP}/Contents/MacOS/CEFHelper"

# Create Info.plist for CEFHelper
cat > "${HELPER_APP}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CEFHelper</string>
    <key>CFBundleIdentifier</key>
    <string>com.yourcompany.yourapp.helper</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
</dict>
</plist>
EOF

# Create CEFHelper (Renderer).app bundle
RENDERER_APP="${FRAMEWORKS}/CEFHelper (Renderer).app"
mkdir -p "${RENDERER_APP}/Contents/MacOS"
cp "${RENDERER_EXEC}" "${RENDERER_APP}/Contents/MacOS/CEFHelper"
chmod +x "${RENDERER_APP}/Contents/MacOS/CEFHelper"

# Create Info.plist for renderer
cat > "${RENDERER_APP}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CEFHelper</string>
    <key>CFBundleIdentifier</key>
    <string>com.yourcompany.yourapp.helper.renderer</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
</dict>
</plist>
EOF

echo "✓ Helper app bundles created"
```

#### 5. Add Framework Symlink Fix Phase

Add a second "Run Script" build phase **after** "Embed Frameworks":

```bash
# Call the package's framework fix script
"${SRCROOT}/../CEFWebView/fix_cef_framework.sh"
```

---

## Helper App Bundles

### Why Separate Helper Apps?

On macOS, CEF requires subprocess helper executables to follow the standard app bundle naming convention:

```
MyApp.app/Contents/Frameworks/
├── MyApp Helper.app/Contents/MacOS/MyApp Helper         (GPU, utility, network)
└── MyApp Helper (Renderer).app/Contents/MacOS/MyApp Helper  (renderer)
```

**Why this matters:**
- CEF detects process roles via `--type=` command-line arguments
- Each process type may have different requirements (renderer needs specialized resource handling)
- macOS app signing and code injection protections expect this structure
- Old pattern (reusing main executable) fails silently on renderer process

### Structure

**CEFHelper.app:**
```
Contents/
├── MacOS/
│   └── CEFHelper        (executable, 20-30MB)
└── Info.plist           (minimal, BundleIdentifier only)
```

**CEFHelper (Renderer).app:**
```
Contents/
├── MacOS/
│   └── CEFHelper        (same or different executable)
└── Info.plist           (minimal, BundleIdentifier only)
```

**Note:** Both can point to the same executable or different ones. CEF detects the role from command-line `--type=` argument, not the executable name.

---

## Multi-Process vs Single-Process

### Multi-Process Mode (Default)

**Enabled by:** `CEF_MULTI_PROCESS` compilation condition in `Package.swift`

**Configuration in CEFWrapper.mm:**
```objc
#ifdef CEF_MULTI_PROCESS
    settings.single_process = 0;
    
    // Point to helper app bundle for subprocess launches
    NSString* helperPath = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Contents/Frameworks/CEFHelper.app/Contents/MacOS/CEFHelper"];
    CefString(&settings.browser_subprocess_path).FromString([helperPath UTF8String]);
#else
    settings.single_process = 1;
#endif
```

**Advantages:**
- ✅ Stability - crash in one process doesn't crash the app
- ✅ Performance - GPU and network in separate processes
- ✅ Security - renderer process has limited access
- ✅ Production-ready

**Disadvantages:**
- ⚠️ More complex setup (helper app bundles required)
- ⚠️ IPC overhead
- ⚠️ Higher memory usage

### Single-Process Mode

**To use:** Remove `CEF_MULTI_PROCESS` from `Package.swift` build settings

**Advantages:**
- ✅ Simpler setup - no helper app bundles
- ✅ Lower memory
- ✅ Faster development/debugging

**Disadvantages:**
- ❌ Stability risk - one crash kills the whole app
- ❌ Performance worse (no separate GPU process)
- ❌ Security risk (no process isolation)
- ❌ Not recommended for production

---

## Public API Reference

### CEFWebView (View)

The main SwiftUI view for embedding Chromium.

```swift
public struct CEFWebView: NSViewRepresentable {
    @Binding var url: URL?
    @Binding var state: CEFWebViewState
    
    public init(url: Binding<URL?>, state: Binding<CEFWebViewState>)
    
    public func makeNSView(context: Context) -> NSView
    public func updateNSView(_ nsView: NSView, context: Context)
    public func makeCoordinator() -> Coordinator
    public static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator)
}
```

**Usage:**
```swift
@State private var url: URL? = URL(string: "https://google.com")
@State private var webState = CEFWebViewState()

var body: some View {
    CEFWebView(url: $url, state: $webState)
}
```

### CEFWebViewState (Observable)

Reactive state for the browser instance.

```swift
@Observable
public final class CEFWebViewState {
    public var isLoading: Bool
    public var estimatedProgress: Double
    public var title: String?
    public var currentURL: URL?
    public var canGoBack: Bool
    public var canGoForward: Bool
    
    public func reload()
    public func goBack()
    public func goForward()
}
```

**Usage:**
```swift
// Read state
if webState.isLoading {
    ProgressView()
}

Text(webState.title ?? "Loading...")

// Perform actions
Button("Back") { webState.goBack() }
    .disabled(!webState.canGoBack)
```

### CEFWrapper (Objective-C Interface)

Low-level wrapper for CEF C++ API. Typically not used directly by Swift code.

```objc
@interface CEFWrapper : NSObject

+ (BOOL)initializeCEFWithError:(NSError **)error;
+ (nullable NSView *)createBrowserInView:(NSView *)parentView
                                    url:(NSString *)urlString;
+ (void)loadURL:(NSString *)urlString;
+ (void)goBack;
+ (void)goForward;
+ (void)reloadBrowser;
+ (void)closeBrowser;
+ (void)doMessageLoopWork;
+ (void)shutdown;

+ (BOOL)isLoading;
+ (BOOL)canGoBack;
+ (BOOL)canGoForward;
+ (nullable NSString *)currentTitle;
+ (nullable NSString *)currentURL;

@end
```

### CEFBridge (Swift Private)

Internal wrapper for CEF browser lifecycle and state management.

```swift
@MainActor
final class CEFApplication {
    static let shared = CEFApplication()
    func initialize() throws
    func shutdown()
}

@MainActor
public final class CEFBrowserHost {
    public init(parentView: NSView, url: URL, state: CEFWebViewState?) throws
    func loadURL(_ url: URL)
    func reload()
    func goBack()
    func goForward()
    func close()
}
```

---

## Troubleshooting

### "Framework not found: Chromium Embedded Framework"

**Cause:** `build_cpp.sh` hasn't been run, so `Frameworks/` doesn't exist.

**Fix:**
```bash
cd CEFWebView
./build_cpp.sh
```

### "CEF not initialized — cannot create browser"

**Cause:** `CEFApplication.shared.initialize()` hasn't been called, or failed silently.

**Fix:** Check logs for CEF initialization errors:
```bash
cat ~/Library/Caches/com.chromium.webview/debug.log
```

### Browser window is blank (white page)

**Possible causes:**
1. Renderer process not spawning
2. Helper app bundles not created correctly
3. Framework symlinks broken

**Debug:**
```bash
# Check if processes are spawning
ps aux | grep CEFHelper

# Check logs
tail -f ~/Library/Caches/com.chromium.webview/debug.log

# Run the framework fix script
./fix_cef_framework.sh
```

### "Mach-O, but wrong architecture"

**Cause:** CEF binaries compiled for wrong architecture (Intel vs ARM).

**Fix:** Rebuild CEF binaries matching your Mac:
```bash
# Check your architecture
uname -m  # arm64 or x86_64

# In build_cpp.sh, adjust cmake line:
cmake -G "Xcode" -DPROJECT_ARCH="arm64" .  # for Apple Silicon
# or
cmake -G "Xcode" -DPROJECT_ARCH="x86_64" .  # for Intel
```

### Xcode: "Module not found: CEFWebView"

**Cause:** Package dependency not properly configured.

**Fix:**
1. In Xcode, delete derived data: `Cmd+Shift+K`
2. Verify `Package.swift` has correct dependency path
3. Run `swift package resolve` in CEFWebView directory
4. Rebuild: `Cmd+Shift+K`, then `Cmd+B`

### Runtime crash on `CefInitialize`

**Cause:** Settings not properly configured, or CEF version mismatch.

**Fix:**
1. Check CEF version matches headers in `Frameworks/include/`
2. Verify `libcef_dll_wrapper.a` was built successfully
3. Check CEF debug log for DCHECK failures
4. Ensure entitlements are set (JIT requirements)

---

## Known Issues

### Issue 1: Renderer Process Not Spawning

**Status:** Under Investigation  
**Symptom:** Google.com renders blank, but other sites load partially  
**Root Cause:** Likely missing or incorrect renderer helper app bundle  

**Workaround:** Use single-process mode (slower, but works):
```swift
// In Package.swift, remove CEF_MULTI_PROCESS define
```

**Tracking:** See `CEF_Usage.md` and `Status.md` for details.

### Issue 2: Framework Symlinks Break After Xcode Embedding

**Status:** FIXED (via `fix_cef_framework.sh`)  
**Symptom:** Build succeeds but app crashes on launch with framework not found  
**Cause:** Xcode's "Embed Frameworks" phase expands symlinks to copies  

**Fix:** Add build phase script:
```bash
"${SRCROOT}/../CEFWebView/fix_cef_framework.sh"
```

### Issue 3: High Memory Usage

**Status:** Expected  
**Explanation:** Chromium + separate processes = ~100-200MB minimum  

**Mitigation:**
- Use single-process mode if memory-constrained
- Profile with Instruments to find leaks
- Consider WebKit (WKWebView) if Chromium features not needed

### Issue 4: Code Signing Issues

**Status:** Needs Testing  
**Possible Issue:** Helper app bundles must be signed with same identity  

**Mitigation:** Ensure build settings use consistent signing identity across all targets.

---

## References

### Documentation Files

- **PackageMigration.md** - High-level package migration plan
- **MIGRATION_STATUS.md** - Current migration phase status
- **CEF_API_MIGRATION.md** - Why we use C++ API instead of C API
- **CEF_Usage.md** - CEF configuration details and renderer process setup
- **Status.md** - Current app status and known issues (from app project)

### External Resources

- [CEF General Usage](https://chromiumembedded.github.io/cef/general_usage.html)
- [CEF macOS Wiki](https://github.com/dliw/fpCEF3/wiki/macOS)
- [CefSettings API Reference](https://cef-builds.spotifycdn.com/docs/114.2/structcef__settings__t.html)

---

## Next Steps

### For Development

1. ✅ Package structure created
2. ✅ CEFWrapper migrated to package
3. ✅ Helper executables defined
4. ⏳ **TODO:** Test helper app bundle creation
5. ⏳ **TODO:** Verify renderer process spawning
6. ⏳ **TODO:** Performance and memory profiling
7. ⏳ **TODO:** Add JavaScript bridge (evaluateJavaScript)
8. ⏳ **TODO:** Add custom certificate handling
9. ⏳ **TODO:** Add DevTools remote debugging support

### For Production

1. ⏳ Code signing and notarization
2. ⏳ App Store submission testing
3. ⏳ Performance optimization
4. ⏳ Documentation and examples
5. ⏳ Automated CI/CD builds

---

## Contributing

When working on CEFWebView:

1. **Always run `build_cpp.sh`** after pulling changes to ensure Frameworks/ is in sync
2. **Test both single and multi-process modes** - toggle `CEF_MULTI_PROCESS` in Package.swift
3. **Check CEF logs** - `~/Library/Caches/com.chromium.webview/debug.log`
4. **Profile memory** - Use Instruments to check for leaks
5. **Document changes** - Update relevant `.md` files

---

**For questions or issues, refer to the issue tracker or check the CEF documentation linked above.**
