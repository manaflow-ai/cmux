//
//  CEFWrapper.h
//  CEFWebView
//
//  Objective-C wrapper for CEF C++ API - provides simple methods for Swift to interact with CEF
//

#ifndef CEFWrapper_h
#define CEFWrapper_h

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C wrapper exposing CEF functionality to Swift
@interface CEFWrapper : NSObject

/// Handle subprocess role detection — call this at the very start of the app, before any CEF initialization
/// Returns the subprocess exit code if this process is a CEF subprocess (renderer, GPU, utility, network)
/// Returns -1 if this is the main browser process and should continue with normal app startup
/// If subprocess is detected, this method does not return — the process exits with the returned code
+ (int)executeSubprocessWithArgc:(int)argc argv:(char * _Nullable * _Nullable)argv;

/// Initialize CEF framework
/// Must be called on the main thread, once at app startup
+ (BOOL)initializeCEFWithError:(NSError **)error;

/// Create a browser in windowed mode within a parent view
/// @param parentView The parent NSView to embed the browser in
/// @param urlString The initial URL to load (e.g., "https://google.com")
/// @return The NSView containing the CEF browser, or nil on error
+ (nullable NSView *)createBrowserInView:(NSView *)parentView
                                    url:(NSString *)urlString;

/// Reload the current page in the browser
+ (void)reloadBrowser;

/// Close the current browser (call before view teardown)
+ (void)closeBrowser;

/// Navigate back
+ (void)goBack;

/// Navigate forward
+ (void)goForward;

/// Load a new URL
+ (void)loadURL:(NSString *)urlString;

/// Process pending CEF messages (call regularly from message pump)
+ (void)doMessageLoopWork;

/// Call after the embedding NSView changes size or layout (SwiftUI updates frames asynchronously).
/// Maps to CefBrowserHost::WasResized(); required or the browser can stay at 0×0 and show a blank view.
+ (void)notifyBrowserViewGeometryChanged;

/// Shutdown CEF gracefully
+ (void)shutdown;

/// Check if a page is currently loading
+ (BOOL)isLoading;

/// Check if the browser can navigate back
+ (BOOL)canGoBack;

/// Check if the browser can navigate forward
+ (BOOL)canGoForward;

/// Get the current page title
+ (nullable NSString *)currentTitle;

/// Get the current page URL (updated on every navigation)
+ (nullable NSString *)currentURL;

/// Internal: Notify that a helper process has spawned (called from C++ notification handler)
+ (void)notifyHelperSpawned:(NSString *)helperType;

/// Internal: Notify that a helper process has failed (called from C++ notification handler)
+ (void)notifyHelperFailed:(NSString *)helperType;

/// Internal: Helper failed with main-frame load error details (OnLoadError).
+ (void)notifyHelperFailed:(NSString *)helperType
      mainFrameLoadErrorCode:(NSInteger)errorCode
                   errorText:(nullable NSString *)errorText
                  failedUrl:(nullable NSString *)failedUrl;

@end

NS_ASSUME_NONNULL_END

#endif /* CEFWrapper_h */
