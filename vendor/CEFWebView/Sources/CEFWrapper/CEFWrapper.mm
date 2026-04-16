//
//  CEFWrapper.mm
//  CEFWebView
//
//  Objective-C++ wrapper for the CEF C++ API.
//

#import "include/CEFWrapper.h"

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <dispatch/dispatch.h>

#include <cstring>
#include <string>

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_load_handler.h"
#include "include/cef_display_handler.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_library_loader.h"

// ─── C Function Bridge Forward Declaration ──────────────────────────────────

extern "C" {
    void NotifyHelperSpawned(const char* helperType);
    void NotifyHelperFailed(const char* helperType);
    void NotifyHelperFailedWithLoadError(const char* helperType,
                                         int errorCode,
                                         const char* errorText,
                                         const char* failedUrl);
}

// ─── CEF App: command-line switches applied in every process ───────────────────
//
// macOS often fails to spawn the GPU process (error 1003) under the default app
// configuration (Hardened Runtime / Mach limits), then Chromium aborts with
// "GPU process isn't usable". Disabling GPU forces software rendering and avoids
// that subprocess. Pass the same CefApp to CefExecuteProcess and CefInitialize.

namespace {

class CEFWebViewApp final : public CefApp, public CefBrowserProcessHandler {
public:
    CEFWebViewApp() = default;

    void OnBeforeCommandLineProcessing(const CefString& process_type,
                                       CefRefPtr<CefCommandLine> command_line) override {
        // Disable GPU to avoid process launch failures under Hardened Runtime / Mach limits
        command_line->AppendSwitch("disable-gpu");
        // Do NOT disable gpu-compositing — it can break renderer rendering
        command_line->AppendSwitch("disable-gpu-sandbox");
        // QUIC / HTTP3 can complicate loads on some networks
        command_line->AppendSwitch("disable-quic");
    }

    /// Called before each child process is launched (GPU, utility, renderer, etc.).
    /// Maps Chromium subprocess types to our Swift UI helper indicators.
    void OnBeforeChildProcessLaunch(CefRefPtr<CefCommandLine> command_line) override {
        if (!command_line.get()) {
            return;
        }
        CefString typeStr = command_line->GetSwitchValue("type");
        std::string type = typeStr.ToString();
        if (type.empty()) {
            return;
        }
        if (type == "gpu-process") {
            NotifyHelperSpawned("gpu");
        } else if (type == "utility") {
            CefString sub = command_line->GetSwitchValue("utility-sub-type");
            std::string subStr = sub.ToString();
            if (subStr.find("NetworkService") != std::string::npos) {
                NotifyHelperSpawned("network");
            } else if (subStr.find("Storage") != std::string::npos) {
                NotifyHelperSpawned("storage");
            }
        } else if (type == "renderer") {
            NotifyHelperSpawned("renderer");
        }
        NSLog(@"🔧 OnBeforeChildProcessLaunch: type=%s utility-sub-type=%s",
              type.c_str(),
              command_line->GetSwitchValue("utility-sub-type").ToString().c_str());
    }

    /// Required when using external_message_pump + CefDoMessageLoopWork; without this, renderer IPC
    /// is not serviced promptly and navigations fail with ERR_ABORTED / blank views.
    void OnScheduleMessagePumpWork(int64_t delay_ms) override {
        // Disabled this log message because it spams the logs
        // NSLog(@"⏰ OnScheduleMessagePumpWork: delay_ms=%lld", delay_ms);
        if (delay_ms <= 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                CefDoMessageLoopWork();
            });
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay_ms * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                CefDoMessageLoopWork();
            });
        }
    }

    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

private:
    IMPLEMENT_REFCOUNTING(CEFWebViewApp);
};

}  // namespace

// ─── C++ Client Class ───────────────────────────────────────────────────────────
//
// Inherits from CefClient, CefLoadHandler, and CefDisplayHandler.
// Implements the virtual methods for load state and title tracking.
// IMPLEMENT_REFCOUNTING macro handles all ref-counting automatically.

class ChromiumClient : public CefClient,
                       public CefLoadHandler,
                       public CefDisplayHandler,
                       public CefRequestHandler {
public:
    // CefClient overrides
    CefRefPtr<CefLoadHandler> GetLoadHandler() override {
        return this;
    }

    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override {
        return this;
    }

    CefRefPtr<CefRequestHandler> GetRequestHandler() override {
        return this;
    }

    // CefRequestHandler overrides
    bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefRequest> request,
                        bool user_gesture,
                        bool is_redirect) override {
        NSLog(@"🧭 OnBeforeBrowse: isMain=%s user_gesture=%d is_redirect=%d",
              frame->IsMain() ? "YES" : "NO",
              user_gesture,
              is_redirect);
        return false;  // Don't cancel the navigation
    }

    // CefLoadHandler overrides
    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                              bool isLoading, bool canGoBack, bool canGoForward) override {
        _isLoading = isLoading;
        _canGoBack = canGoBack;
        _canGoForward = canGoForward;
        NSLog(@"📊 OnLoadingStateChange: isLoading=%d canGoBack=%d canGoForward=%d",
              isLoading, canGoBack, canGoForward);
    }

    void OnLoadStart(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     TransitionType transition_type) override {
        NSLog(@"⬇️ OnLoadStart: url=%s isMain=%s",
              frame->GetURL().ToString().c_str(),
              frame->IsMain() ? "YES" : "NO");

        if (frame->IsMain()) {
            NSLog(@"📢 OnLoadStart: main frame load started (renderer already tracked via OnBeforeChildProcessLaunch)");
        }
    }

    void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   int httpStatusCode) override {
        NSLog(@"✅ OnLoadEnd: url=%s status=%d isMain=%s",
              frame->GetURL().ToString().c_str(),
              httpStatusCode,
              frame->IsMain() ? "YES" : "NO");

        // Ensure loading state is cleared when main frame finishes
        if (frame->IsMain()) {
            _isLoading = false;
            NSLog(@"📊 OnLoadEnd (MAIN FRAME): set isLoading=false");
        }
    }

    void OnLoadError(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     ErrorCode errorCode,
                     const CefString& errorText,
                     const CefString& failedUrl) override {
        // Subframe failures (ads, trackers, blocked embeds) often report ERR_ABORTED for URLs that
        // look like the top document; only treat main-frame errors as document load failures.
        if (!frame->IsMain()) {
            NSLog(@"⏭️  OnLoadError (SUBFRAME - ignoring): url=%s error=%d text=%s",
                  failedUrl.ToString().c_str(),
                  errorCode,
                  errorText.ToString().c_str());
            return;
        }

        // ERR_ABORTED (-3) is normal for redirects and navigation interruptions.
        // The page often loads successfully despite this error, so don't report it.
        if (errorCode == -3) {  // net::ERR_ABORTED
            NSLog(@"⏭️  OnLoadError (MAIN FRAME - ERR_ABORTED, ignoring): url=%s",
                  failedUrl.ToString().c_str());
            return;
        }

        NSLog(@"❌ OnLoadError (MAIN FRAME - CRITICAL): url=%s error=%d text=%s",
              failedUrl.ToString().c_str(),
              errorCode,
              errorText.ToString().c_str());
        NSLog(@"💥 Main frame failed to load - renderer will be marked as failed");

        // Renderer process failed to load main frame - mark renderer as failed
        NSLog(@"🔔 Calling NotifyHelperFailedWithLoadError from OnLoadError");
        NotifyHelperFailedWithLoadError("renderer",
                                        static_cast<int>(errorCode),
                                        errorText.ToString().c_str(),
                                        failedUrl.ToString().c_str());
    }

    void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                   TerminationStatus status) {
        NSLog(@"💥 OnRenderProcessTerminated: status=%d (0=normal, 1=abnormal, 2=crashed, 3=oom, 4=launch_failed)", (int)status);
        NSLog(@"🔔 Calling NotifyHelperFailed(\"renderer\") from OnRenderProcessTerminated");
        NotifyHelperFailed("renderer");
    }

    // CefDisplayHandler overrides
    void OnTitleChange(CefRefPtr<CefBrowser> browser,
                       const CefString& title) override {
        NSString* titleCopy = [NSString stringWithUTF8String:title.ToString().c_str()];
        NSLog(@"📄 OnTitleChange: %@", titleCopy);
        dispatch_async(dispatch_get_main_queue(), ^{
            _currentTitle = titleCopy;
        });
    }

    void OnAddressChange(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         const CefString& url) override {
        NSString* urlCopy = [NSString stringWithUTF8String:url.ToString().c_str()];
        NSLog(@"🔗 OnAddressChange: %@", urlCopy);
        dispatch_async(dispatch_get_main_queue(), ^{
            _currentURL = urlCopy;
        });
    }

    // State accessors (called from Objective-C methods below)
    bool IsLoading() const { return _isLoading; }
    bool CanGoBack() const { return _canGoBack; }
    bool CanGoForward() const { return _canGoForward; }
    NSString* GetTitle() const { return _currentTitle; }
    NSString* GetURL() const { return _currentURL; }

private:
    std::atomic<bool> _isLoading{false};
    std::atomic<bool> _canGoBack{false};
    std::atomic<bool> _canGoForward{false};
    NSString* __strong _currentTitle = nil;
    NSString* __strong _currentURL = nil;

    IMPLEMENT_REFCOUNTING(ChromiumClient);
};


// ─── Global State ───────────────────────────────────────────────────────────────

static BOOL g_cefInitialized = NO;
static CefRefPtr<CefBrowser> g_browser;
static CefRefPtr<ChromiumClient> g_client;

/// Single loader per process. On macOS, main browser must call LoadInMain(); CEF helper
/// subprocesses (same binary, `--type=...`) must call LoadInHelper() — see cef_library_loader.h.
static CefScopedLibraryLoader g_cefLibraryLoader;

/// CefScopedLibraryLoader does not allow calling LoadInMain/LoadInHelper twice; the second
/// call fails. We load once in executeSubprocessWithArgc, then initializeCEFWithError must skip.
static BOOL g_cefFrameworkDylibLoaded = NO;

static bool CEFIsHelperProcess(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (a && std::strncmp(a, "--type=", 7) == 0) {
            return true;
        }
    }
    return false;
}

/// |isHelperProcess|: YES → LoadInHelper(), NO → LoadInMain(). Ignored if already loaded.
static BOOL EnsureCEFFrameworkLoaded(BOOL isHelperProcess, NSError **error) {
    if (g_cefFrameworkDylibLoaded) {
        return YES;
    }
    const bool ok = isHelperProcess ? g_cefLibraryLoader.LoadInHelper() : g_cefLibraryLoader.LoadInMain();
    if (!ok) {
        NSLog(@"❌ Failed to load Chromium Embedded Framework (%s process)",
              isHelperProcess ? "helper" : "main");
        if (error) {
            *error = [NSError errorWithDomain:@"CEFWrapper"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to load Chromium Embedded Framework"}];
        }
        return NO;
    }
    g_cefFrameworkDylibLoaded = YES;
    return YES;
}

// ─── CEFWrapper Implementation ───────────────────────────────────────────────────

@implementation CEFWrapper

+ (void)notifyHelperSpawned:(NSString *)helperType {
    NSLog(@"📢 CEFWrapper.notifyHelperSpawned called with type: %@", helperType);

    if (!helperType) {
        return;
    }

    // Post a notification that the Swift side can observe
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"CEFHelperSpawned"
                                                            object:nil
                                                          userInfo:@{@"type": helperType}];
    });
}

+ (void)notifyHelperFailed:(NSString *)helperType {
    NSLog(@"📢 CEFWrapper.notifyHelperFailed called with type: %@", helperType);

    if (!helperType) {
        NSLog(@"⚠️  CEFWrapper.notifyHelperFailed: helperType is nil, returning early");
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *userInfo = @{@"type": helperType};
        NSLog(@"📮 [MAIN QUEUE] Posting CEFHelperFailed userInfo: %@", userInfo);
        [[NSNotificationCenter defaultCenter] postNotificationName:@"CEFHelperFailed"
                                                            object:nil
                                                          userInfo:userInfo];
    });
}

+ (void)notifyHelperFailed:(NSString *)helperType
      mainFrameLoadErrorCode:(NSInteger)errorCode
                   errorText:(NSString *)errorText
                  failedUrl:(NSString *)failedUrl {
    if (!helperType) {
        return;
    }
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[@"type"] = helperType;
    userInfo[@"errorCode"] = @(errorCode);
    if (errorText) {
        userInfo[@"errorText"] = errorText;
    }
    if (failedUrl) {
        userInfo[@"failedUrl"] = failedUrl;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"📮 [MAIN QUEUE] Posting CEFHelperFailed (main frame load error) userInfo: %@", userInfo);
        [[NSNotificationCenter defaultCenter] postNotificationName:@"CEFHelperFailed"
                                                            object:nil
                                                          userInfo:[userInfo copy]];
    });
}

+ (int)executeSubprocessWithArgc:(int)argc argv:(char **)argv {
    NSMutableString* argDump = [NSMutableString stringWithFormat:@"executeSubprocessWithArgc: argc=%d", argc];
    if (argc > 0 && argv) {
        for (int i = 0; i < argc; i++) {
            const char* a = argv[i];
            NSString* s = a ? [NSString stringWithUTF8String:a] : @"(null)";
            [argDump appendFormat:@"\n  argv[%d] = %@", i, s];
        }
    } else {
        [argDump appendString:@" (argv nil or argc <= 0)"];
    }
    NSLog(@"%@", argDump);

    const BOOL isCEFHelperArgv = CEFIsHelperProcess(argc, argv);
    if (isCEFHelperArgv) {
        NSLog(@"executeSubprocessWithArgc: this process has --type=… — CEF helper role; "
              @"CefExecuteProcess will handle it and this process should exit.");
    } else {
        NSLog(@"executeSubprocessWithArgc: no --type= in argv — this is the main browser binary "
              @"(Xcode often adds -NSDocumentRevisionsDebugMode etc.). "
              @"GPU/utility/renderer helpers are separate OS processes (WebView Helper.app); "
              @"their executeSubprocessWithArgc logs appear under the WebView Helper process, "
              @"not WebView — include helper processes in Console or log show.");
    }

    // Without loading the framework first, CefExecuteProcess jumps through a null stub (crash at 0x0).
    // Helper subprocesses must use LoadInHelper(), not LoadInMain() — see CEF cef_library_loader.h.
    if (!EnsureCEFFrameworkLoaded(CEFIsHelperProcess(argc, argv) ? YES : NO, nil)) {
        return 1;
    }
    CefMainArgs args(argc, argv);
    CefRefPtr<CefApp> app = new CEFWebViewApp();
    return CefExecuteProcess(args, app, nullptr);
}

+ (BOOL)initializeCEFWithError:(NSError **)error {
    if (g_cefInitialized) {
        NSLog(@"✓ CEF already initialized");
        return YES;
    }

    // Browser process only (helpers never reach initializeCEF). Framework was already loaded
    // in executeSubprocessWithArgc — EnsureCEFFrameworkLoaded skips the second load.
    if (!EnsureCEFFrameworkLoaded(NO, error)) {
        return NO;
    }
    NSLog(@"✓ Chromium Embedded Framework loaded");

    CefMainArgs args;
    CefSettings settings;

    settings.no_sandbox = 1;
    settings.external_message_pump = 1;

    // Enable verbose logging
    settings.log_severity = LOGSEVERITY_VERBOSE;
    CefString(&settings.log_file).FromString("/tmp/cef_debug.log");

    // Also append command-line switches for extra verbosity
    CefRefPtr<CefCommandLine> command_line = CefCommandLine::GetGlobalCommandLine();
    if (command_line.get()) {
        command_line->AppendSwitch("enable-logging");
        command_line->AppendSwitchWithValue("v", "3");  // v=3 for very verbose

        // TEST: Single-process mode to isolate subprocess spawning issues
        // If single-process mode works, the problem is subprocess spawning.
        // If it still fails, the problem is in CEF core or configuration.
        // IMPORTANT: Remove this after testing — single-process is not production-ready.
        // Uncomment the line below to enable:
        // command_line->AppendSwitch("single-process");
    }

#if TARGET_OS_OSX
    // macOS: set absolute path to the generic helper (see WebView/Scripts/embed_cef_helpers.sh).
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSLog(@"🔍 Main bundle path: %@", bundlePath);
    NSString *frameworksDir = [bundlePath stringByAppendingPathComponent:@"Contents/Frameworks"];
    NSLog(@"🔍 Frameworks dir: %@", frameworksDir);

    // HARD FAIL: CEF framework must exist
    NSString *cefFrameworkPath =
        [frameworksDir stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:cefFrameworkPath]) {
        NSString *errorMsg = [NSString stringWithFormat:
            @"CEF framework not found at %@. This is a critical initialization failure. "
            @"Verify the Chromium Embedded Framework is properly embedded in the app bundle.",
            cefFrameworkPath];
        NSLog(@"💥 INITIALIZATION FAILED: %@", errorMsg);
        if (error) {
            *error = [NSError errorWithDomain:@"CEFWrapper"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
        }
        return NO;
    }
    NSLog(@"✅ CEF framework verified at: %@", cefFrameworkPath);

    // HARD FAIL: CEF resources (icudtl.dat, *.pak files) must exist
    NSString *cefResourcesPath = [cefFrameworkPath stringByAppendingPathComponent:@"Resources"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:cefResourcesPath]) {
        NSString *errorMsg = [NSString stringWithFormat:
            @"CEF resources not found at %@. This is a critical initialization failure. "
            @"Without these resources, page navigation will abort with ERR_ABORTED.",
            cefResourcesPath];
        NSLog(@"💥 INITIALIZATION FAILED: %@", errorMsg);
        if (error) {
            *error = [NSError errorWithDomain:@"CEFWrapper"
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
        }
        return NO;
    }
    NSLog(@"✅ CEF resources verified at: %@", cefResourcesPath);

    // HARD FAIL: WebView Helper executable must exist and be executable
    NSString *helperExe = [frameworksDir stringByAppendingPathComponent:
        @"WebView Helper.app/Contents/MacOS/WebView Helper"];
    NSLog(@"🔍 Checking helper at: %@", helperExe);

    if (![[NSFileManager defaultManager] fileExistsAtPath:helperExe]) {
        NSString *errorMsg = [NSString stringWithFormat:
            @"WebView Helper executable not found at %@. This is a critical initialization failure. "
            @"Run the 'embed_cef_helpers' build phase or execute 'swift build' to build helpers.",
            helperExe];
        NSLog(@"💥 INITIALIZATION FAILED: %@", errorMsg);
        if (error) {
            *error = [NSError errorWithDomain:@"CEFWrapper"
                                         code:5
                                     userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
        }
        return NO;
    }
    NSLog(@"✅ Helper executable exists at: %@", helperExe);

    if (![[NSFileManager defaultManager] isExecutableFileAtPath:helperExe]) {
        NSString *errorMsg = [NSString stringWithFormat:
            @"WebView Helper at %@ exists but is not executable. This is a critical initialization failure. "
            @"The helper may lack proper code signing or JIT entitlements. "
            @"Rebuild with 'swift build' and ensure the embed_cef_helpers build phase runs.",
            helperExe];
        NSLog(@"💥 INITIALIZATION FAILED: %@", errorMsg);
        if (error) {
            *error = [NSError errorWithDomain:@"CEFWrapper"
                                         code:6
                                     userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
        }
        return NO;
    }
    NSLog(@"✅ Helper is executable");
#endif

    // Set CEF settings using direct method that keeps data alive
    CefString(&settings.browser_subprocess_path).FromString([helperExe UTF8String]);
    NSLog(@"✅ CEF browser_subprocess_path configured: %@", helperExe);

    CefString(&settings.resources_dir_path).FromString([cefResourcesPath UTF8String]);
    CefString(&settings.framework_dir_path).FromString([cefFrameworkPath UTF8String]);
    CefString(&settings.main_bundle_path).FromString([bundlePath UTF8String]);

    NSString *ua = [NSString stringWithFormat:
        @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
        @"Chrome/%d.%d.%d.%d Safari/537.36",
        CHROME_VERSION_MAJOR, CHROME_VERSION_MINOR, CHROME_VERSION_BUILD, CHROME_VERSION_PATCH];
    CefString(&settings.user_agent).FromString([ua UTF8String]);

    // Enable verbose CEF logging to debug page rendering issues
    settings.log_severity = LOGSEVERITY_VERBOSE;
    NSString* cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    if (cacheDir) {
        NSString* logPath = [cacheDir stringByAppendingPathComponent:@"com.chromium.webview/debug.log"];
        CefString(&settings.log_file).FromString([logPath UTF8String]);
        NSLog(@"✅ CEF debug log configured at: %@", logPath);
    }

    // Set cache path to avoid singleton behavior warnings
    if (cacheDir) {
        cacheDir = [cacheDir stringByAppendingPathComponent:@"com.chromium.webview"];
        CefString(&settings.root_cache_path).FromString([cacheDir UTF8String]);
        NSLog(@"✅ CEF cache path configured at: %@", cacheDir);
    }

    NSLog(@"🔧 ========================================");
    NSLog(@"🔧 CEF Initialization Settings:");
    NSLog(@"🔧   no_sandbox: %d", settings.no_sandbox);
    NSLog(@"🔧   external_message_pump: %d", settings.external_message_pump);
    NSLog(@"🔧   browser_subprocess_path: %@",
          [NSString stringWithUTF8String:CefString(&settings.browser_subprocess_path).ToString().c_str()]);
    NSLog(@"🔧   resources_dir_path: %@",
          [NSString stringWithUTF8String:CefString(&settings.resources_dir_path).ToString().c_str()]);
    NSLog(@"🔧 ========================================");

    CefRefPtr<CefApp> app = new CEFWebViewApp();
    NSLog(@"🔧 Calling CefInitialize...");
    bool initResult = CefInitialize(args, settings, app, nullptr);
    NSLog(@"🔧 CefInitialize returned: %s", initResult ? "true" : "false");

    if (!initResult) {
        NSString *errorMsg = [NSString stringWithFormat:
            @"CefInitialize failed. This is a critical initialization failure. "
            @"Check the CEF debug log at %@/com.chromium.webview/debug.log for details. "
            @"Common causes: missing/invalid helper executable, resource file (icudtl.dat) not found, "
            @"framework path configuration error, or renderer subprocess initialization failure.",
            cacheDir ?: @"~/Library/Caches"];
        NSLog(@"💥 INITIALIZATION FAILED: %@", errorMsg);
        if (error) {
            *error = [NSError errorWithDomain:@"CEFWrapper"
                                        code:1
                                    userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
        }
        return NO;
    }

    NSLog(@"✅ CefInitialize succeeded - CEF is now initialized and ready");
    g_cefInitialized = YES;
    return YES;
}

+ (nullable NSView *)createBrowserInView:(NSView *)parentView
                                     url:(NSString *)urlString {
    if (!g_cefInitialized) {
        NSLog(@"💥 CRITICAL: CEF not initialized — cannot create browser. "
              @"Call initializeCEFWithError: first and check for errors.");
        return nil;
    }

    if (!parentView) {
        NSLog(@"💥 CRITICAL: parentView is nil — cannot create browser");
        return nil;
    }

    if (!urlString || [urlString length] == 0) {
        NSLog(@"💥 CRITICAL: urlString is nil or empty — cannot create browser");
        return nil;
    }

    NSLog(@"🔧 Creating browser for URL: %@", urlString);
    NSLog(@"🖼️ parentView: %@ bounds: %@", parentView, NSStringFromRect(parentView.bounds));

    // Window info — SetAsChild forces Alloy (windowed-child) mode
    CefWindowInfo windowInfo;
    NSRect parentBounds = parentView.bounds;
    NSLog(@"🔧 Calling SetAsChild with parentView bounds=(%d,%d,%d,%d)",
          (int)parentBounds.origin.x, (int)parentBounds.origin.y,
          (int)parentBounds.size.width, (int)parentBounds.size.height);
    windowInfo.SetAsChild((__bridge void*)parentView,
                          CefRect((int)parentBounds.origin.x, (int)parentBounds.origin.y,
                                  (int)parentBounds.size.width, (int)parentBounds.size.height));

    // Browser settings
    CefBrowserSettings browserSettings;

    // Create the C++ client
    g_client = new ChromiumClient();
    NSLog(@"✅ ChromiumClient created");

    // Create the browser
    CefString url;
    url.FromString([urlString UTF8String]);

    NSLog(@"🔧 Calling CefBrowserHost::CreateBrowserSync...");
    CefRefPtr<CefBrowser> browser =
        CefBrowserHost::CreateBrowserSync(windowInfo, g_client, url, browserSettings, nullptr, nullptr);

    if (!browser) {
        NSLog(@"💥 CRITICAL: CreateBrowserSync returned null. This means the browser subprocess failed to initialize. "
              @"Likely causes: helper process crash, dyld framework loading failure, JIT entitlements missing, "
              @"or invalid code signatures. Check the CEF debug log and system logs for details.");
        g_client = nullptr;
        return nil;
    }

    NSLog(@"✅ Browser object created: %p", browser.get());
    g_browser = browser;

    // Get the native view that CEF created and is rendering into
    NSView* cefView = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
    if (!cefView) {
        NSLog(@"💥 CRITICAL: GetWindowHandle returned null despite successful browser creation");
        return nil;
    }

    NSLog(@"✅ Browser view obtained: %@ frame=%@", cefView, NSStringFromRect(cefView.frame));
    NSLog(@"✅ Browser initialization complete. Initial URL: %@", urlString);

    // Return the CEF-created view (it's already added to parentView by SetAsChild)
    return cefView;
}

+ (void)reloadBrowser {
    if (g_browser) {
        g_browser->Reload();
    } else {
        NSLog(@"⚠️  No browser");
    }
}

+ (void)closeBrowser {
    if (g_browser) {
        NSLog(@"🛑 Closing browser");
        g_browser->GetHost()->CloseBrowser(true);
        g_browser = nullptr;
        g_client = nullptr;
    }
}

+ (void)goBack {
    if (g_browser) {
        g_browser->GoBack();
    }
}

+ (void)goForward {
    if (g_browser) {
        g_browser->GoForward();
    }
}

+ (void)loadURL:(NSString *)urlString {
    NSLog(@"🌐 [loadURL] Entering: %@ g_browser=%p", urlString, g_browser.get());

    if (!g_browser) {
        NSLog(@"⚠️ [loadURL] No browser instance");
        return;
    }

    CefRefPtr<CefFrame> frame = g_browser->GetMainFrame();
    if (!frame) {
        NSLog(@"⚠️ [loadURL] No main frame");
        return;
    }

    CefString url;
    url.FromString([urlString UTF8String]);
    NSLog(@"🌐 [loadURL] Calling frame->LoadURL(%@)", urlString);
    frame->LoadURL(url);
    NSLog(@"🌐 [loadURL] frame->LoadURL returned for %@", urlString);
}

+ (void)doMessageLoopWork {
    if (g_cefInitialized) {
        CefDoMessageLoopWork();
    }
}

+ (void)notifyBrowserViewGeometryChanged {
    if (!g_browser) {
        return;
    }
    CefRefPtr<CefBrowserHost> host = g_browser->GetHost();
    if (host.get()) {
        host->WasResized();
    }
}

+ (void)shutdown {
    if (!g_cefInitialized) return;

    NSLog(@"🛑 Shutting down CEF");

    // Release the browser and client references
    g_browser = nullptr;
    g_client = nullptr;

    CefShutdown();
    g_cefInitialized = NO;
}

+ (BOOL)isLoading {
    return g_client && g_client->IsLoading();
}

+ (BOOL)canGoBack {
    return g_client && g_client->CanGoBack();
}

+ (BOOL)canGoForward {
    return g_client && g_client->CanGoForward();
}

+ (nullable NSString *)currentTitle {
    return g_client ? g_client->GetTitle() : nil;
}

+ (nullable NSString *)currentURL {
    return g_client ? g_client->GetURL() : nil;
}

@end

// ─── C Function Bridge Implementation ────────────────────────────────────────
// These must be defined after @implementation so they can call Objective-C methods

extern "C" {
    void NotifyHelperSpawned(const char* helperType) {
        if (!helperType) return;
        NSString* type = [NSString stringWithUTF8String:helperType];
        NSLog(@"🚀 [C BRIDGE] Helper spawned: %@", type);
        dispatch_async(dispatch_get_main_queue(), ^{
            [CEFWrapper notifyHelperSpawned:type];
        });
    }

    void NotifyHelperFailed(const char* helperType) {
        if (!helperType) {
            NSLog(@"❌ [C BRIDGE] NotifyHelperFailed called with null helperType");
            return;
        }
        NSString* type = [NSString stringWithUTF8String:helperType];
        NSLog(@"❌ [C BRIDGE] Helper failed: %@", type);
        dispatch_async(dispatch_get_main_queue(), ^{
            [CEFWrapper notifyHelperFailed:type];
        });
    }

    void NotifyHelperFailedWithLoadError(const char* helperType,
                                         int errorCode,
                                         const char* errorText,
                                         const char* failedUrl) {
        if (!helperType) {
            return;
        }
        NSString* type = [NSString stringWithUTF8String:helperType];
        NSString* text = errorText ? [NSString stringWithUTF8String:errorText] : nil;
        NSString* url = failedUrl ? [NSString stringWithUTF8String:failedUrl] : nil;
        NSString* safeText = text ?: @"";
        NSString* safeUrl = url ?: @"";
        NSLog(@"❌ [C BRIDGE] Helper failed with load error: %@ code=%d text=%@ url=%@", type, errorCode, safeText, safeUrl);
        dispatch_async(dispatch_get_main_queue(), ^{
            [CEFWrapper notifyHelperFailed:type
                  mainFrameLoadErrorCode:errorCode
                               errorText:text
                              failedUrl:url];
        });
    }
}
