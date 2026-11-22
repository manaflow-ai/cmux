# cmux-next Mac Home rendering (IOS3)

Proposal for decision IOS3. Lane 16, 2026-10-02. Status: proposal, measured. Recommendation: B.

Question: Home (IOS2) gets its pixel-perfect message animations from the
UIKit/Catalyst MessagesLab variant. The cmux-next Mac app is AppKit. Do we
(A) render Home with UIKit in a Catalyst process and show it inside the AppKit
window, or (B) share one render core between the UIKit (iOS) code and a native
AppKit host?

## 1. How Messages on macOS renders

Evidence from this Mac (macOS 27.0 26A428, Messages 26.0 build
1491.100.1.1.11). Read-only: `otool`, bundle layout, Info.plist, Objective-C
runtime class lists of system frameworks, `vmmap` and a 1 s `sample` of the
running Messages process. Messages was not launched or controlled.

1. **Messages is a Mac Catalyst app.** The main executable has
   `LC_BUILD_VERSION platform 6` (Mac Catalyst), `minos 27.0`. `vmmap` reports
   `Platform: Catalyst` and build info `Messages_iosmac-…`. Info.plist sets
   `UIUserInterfaceIdiomMac = true` (the "Optimized for Mac" idiom: native
   size, Mac controls, no 77 % scaling), a `UIApplicationSceneManifest` with
   multiple scenes, and `NSPrincipalClass = SMSApplication`.
2. **The transcript is the iOS code.** The executable links the iOS frameworks
   under `/System/iOSSupport`: UIKit, ChatKit (private), IMCore,
   IMSharedUtilities, ContactsUI. ChatKit holds the transcript for iOS and
   Mac: `CKTranscriptCollectionView` (a `UICollectionView`),
   `CKTranscriptCompositionalLayout`, `CKBalloonView` / `CKBalloonLayer`,
   `CKSendAnimationContext` / `CKSendAnimationContainerView`,
   `CKFullScreenEffectManager`, `CKMessageEntryView`. Mac-only pieces are thin:
   `CKCatalystUtilities`, `CKMacToolbarController` (NSToolbar through
   Catalyst), `CKCatalystInvisibleInkGestureRecognizer`.
3. **AppKit only where UIKit has no Mac equivalent, through a plug-in bundle.**
   `Contents/PlugIns/MessagesAppKitBridge.bundle` is a macOS-platform bundle
   (`platform 1`, principal class `CKAppKitBridge`) that links AppKit,
   UIKitMacHelper, AccountsUI, CharacterPicker. It holds the Settings window
   (`CKPreferencesWindowController` and panes), the emoji picker
   (`CKMacEmojiPicker`), `NSPopover`-based reminders, sticker drag helpers and
   the app icon appearance. A Catalyst process can load a macOS bundle; the
   reverse is not possible (item 6).
4. **One UI process, data out of process.** All UI runs in the Messages
   process (1.6 GB footprint after 8 days). There is no separate render
   process. Data and transport run in daemons: `imagent` (IMCore),
   `IMDPersistenceAgent` (the message database), `identityservicesd`,
   BlastDoor XPC services (sandboxed parsing of incoming content), history
   deletion and escrow agents. Extensions: an ExtensionKit App Intents
   extension (`Contents/Extensions/MessagesActionExtension.appex`, itself
   Catalyst) and NSExtension plug-ins. Message-app balloons from other apps
   are remote views composited into the transcript.
5. **Catalyst composites UIKit into AppKit by layer hosting, in process.** Each
   scene window is a `UINSWindow` (UIKitMacHelper). Its `UINSSceneView`
   (`NSView`) shows the UIKit scene through `_sceneLayer`, a `USSLayerHost`
   (a `CALayerHost`) that points at the scene's Core Animation context by
   `_contextId`. Prototype A1 uses the same primitive across processes.
   UIKitMacHelper also has `UINSSceneHostingView -initWithUIView:` (UIKit
   views inside NSToolbar items) and `UINSLocalSceneHostingView`. Input goes
   through `UINSEventTranslator` / `UINSMouseEventTranslator` (NSEvent to
   UIEvent). The sample shows `com.apple.NSEventThread`,
   `com.apple.UIKit.inProcessAnimationManager` and a `CVDisplayLink` thread.
6. **An AppKit process cannot load UIKit.** `dlopen` of
   `/System/iOSSupport/System/Library/Frameworks/UIKit.framework/UIKit` from a
   macOS-platform process fails with "wrong platform to load into process".
   So the cmux AppKit app can only get UIKit pixels from another process, or
   not use UIKit on the Mac.

Documented background: Apple introduced Messages for macOS Big Sur as a Mac
Catalyst app (WWDC 2020) together with the Mac idiom ("Optimize the interface
of your Mac Catalyst app", WWDC 2020). ExtensionKit remote UI is documented
in "Including extension-based UI in your interface".

Conclusion: Apple gets one transcript on iOS and Mac by making the Mac app a
Catalyst app, not by mirroring. The Mac app is UIKit first, with AppKit
plugged in. cmux-next is AppKit first, so the Apple pattern does not transfer
directly.

## 2. Options

| Id | Method | API | Notes |
| --- | --- | --- | --- |
| A1 | Catalyst helper process renders Home; the AppKit window shows its UIKit layer tree with `CALayerHost` (context id), input forwarded over a socket | private (`CAContext`, `CALayerHost`, UIKit context id) | zero-copy, composited by the render server in the same frame |
| A2 | Catalyst ExtensionKit UI extension; the AppKit window shows it with `EXHostViewController` | public | the system owns input, focus, IME and accessibility bridging |
| A3 | Helper renders into an IOSurface; the host draws it | public | one copy and at least one frame of latency per frame; rejected |
| A4 | Catalyst helper window placed over the AppKit window | private window ordering | a helper window; rejected (Lawrence dislikes helper windows) |
| B | Shared render core (`CmuxHomeRender`, CALayer + Core Text + Core Animation) with a UIKit host on iOS and an AppKit host on the Mac | public | one process; host-specific input and text |

## 3. Prototypes

Throwaway apps in private scratch (not in this repo):
`.cmux-scratch/nx-worker/mac-home-proto/` with `a-mirror/`, `a2-extensionkit/`,
`b-shared/`, `harness/` and the shared scenario contract `CONTRACT.md`. The Home
content is the MessagesLab fixture.

**A1, Catalyst mirror (works).** `MirrorHost` (AppKit) starts `MirrorHelper`
(Catalyst, with an AppKit plug-in bundle as in Messages) and shows the
helper's UIKit context through a `CALayerHost`.
- Pixels: at rest A1 is 100 % identical to the same app's native Catalyst
  window. During the send animation, frames frozen at 0-700 ms differ from
  native by at most 19/255 per pixel; two runs of A1 differ by up to 25/255,
  so the difference is timing noise, not the mirror.
- Hiding: the helper window stays at alpha 0 under the host content, ignores
  the mouse, has no shadow and is excluded from window cycling. An
  ordered-out window still renders but loses UIKit hit testing. The helper is
  still a real window in the window server.
- Input: the host sends events over a Unix socket (round trip p50 16 µs,
  p95 29 µs). Keys use host-side text input: the host's input context
  produces insertText / setMarkedText / commands, and the helper applies them
  to UIKit `UITextInput`. A raw `NSWindow sendEvent:` keyDown hangs a
  Catalyst window that is not key. UIKit pulls scroll and click events from
  the AppKit queue (`UINSMouseEventTranslator`), so the helper must post them
  into its own queue, else every scroll starts with a 93-124 ms stall.
- IME: marked text, commit and caret rectangle work through the proxy; the
  marked-text underline is missing. Live input-method switching UNVERIFIED.
- Accessibility: a remote accessibility element in the host returns the
  helper's UIKit elements on hit test, but their parent chain points to the
  helper window. UNVERIFIED in the final configuration.
- Resize: the host passes a Core Animation fence port to the helper for each
  step and waits up to 12 ms. The helper acknowledged 125 of 135 steps
  (median 6.9 ms). Without a pixel capture a one-frame mismatch is not
  excluded; under load the content visibly lagged the window.
- Required private API: `CALayerHost`, `CAContext.restrictedHostProcessId`
  (UIKit restricts its context to the UIKitSystem process; the prototype sets
  it to 0, which turns off a security control), `CAContext` fence ports,
  `NSAccessibilityRemoteUIElement`, `-[NSEvent _eventRelativeToWindow:]`, a
  hook on `NSApplication sendEvent:`.

**A2, ExtensionKit remote view (blocked).** A Catalyst ExtensionKit UI
extension is not registered by the extension registry, embedded in the AppKit
host or in a Catalyst container app (built by Xcode, ad-hoc signed). The
same extension built for macOS registers and activates in the same host
without user approval. A public-API mirror is therefore not available today.
UNVERIFIED with a Developer ID signature.

**B, shared render core (works).** `CmuxHomeRender` (layout, Core Text, bubble
geometry, fitted springs, motion choreography, the CALayer tree, scroll and
compose state, accessibility items; imports Foundation, CoreGraphics,
CoreText, QuartzCore, ImageIO, CoreImage only) plus two thin hosts.
- Share: render core 3,667 lines, AppKit host 340, Catalyst host 348, data
  stand-in 800. About 93 % of each app is shared.
- Parity: AppKit host vs Catalyst host over the 170-frame send: mean 0.106,
  worst frame 0.202 (0-255 scale). Against the reference recording: AppKit
  2.19 mean, Catalyst host 2.20, the original UIKit app 2.75. The frame-exact
  send check fails 61/128 frames (original UIKit app: 53), mainly in the
  first frames after Return.
- Not shared: text input (AppKit text input with IME; Catalyst key input),
  scroll input (AppKit phases and momentum; Catalyst pan, with the core's
  momentum model), SF Symbols drawing, window chrome, accessibility wrappers.
- Accessibility VERIFIED on both hosts through the AX API (rows as static
  text with sender, compose as text area). Reduce Motion VERIFIED (springs
  become a 0.25 s cross-fade).
- Problems: live resize re-renders every visible row bitmap (1.5 s CPU per
  scenario); idle footprint 160-210 MB (header blur context and decoded
  images, not proved).

## 4. Measurements

Host cmux-lawrence-2 (M5 Pro, 15 cores, built-in 120 Hz XDR display, console
GUI session; apps started over ssh render and get a 120 Hz display link).
Screen capture is blocked by privacy settings for ssh-started processes there,
and on the main laptop the capture service delivers no frames (load 80-1000),
so timing is the in-app display-link log: callbacks, missed 8.33 ms targets,
longest gap. This shows main-thread timing, not frames dropped by the render
server, and not input-to-photon. Load is the 1-minute load average at start
-> end; above 30 the run is marked distorted. The display-link log itself
costs 17-29 ms CPU per second per process.

| Scenario | Metric | N1 Catalyst native | A1 mirror (host + helper) | B AppKit port | N2 earlier AppKit variant |
| --- | --- | --- | --- | --- | --- |
| send | missed / longest | 3 / 17.5 ms | host 4 / 43.6 ms, helper 15 / 28.7 ms | 4 / 34.0 ms | 1 / 16.7 ms |
| send | CPU | 94 ms | 85 + 187 ms | 130 ms | 124 ms |
| send | load | 33.6 -> 35.1 | 16.3 -> 15.5 | 27.3 -> 26.0 | 35.1 -> 35.0 |
| type | missed / longest | 1 / 16.7 ms | host 4 / 42.4 ms, helper 1 / 16.7 ms | 5 / 20.8 ms | 0 / 8.3 ms |
| type | CPU | 120 ms | 82 + 189 ms | 82 ms | 87 ms |
| fling | missed / longest | 0 / 8.3 ms | host 0 / 8.3 ms, helper 12 / 102.9 ms | 6 / 28.1 ms | 1 / 18.7 ms |
| fling | CPU | 87 ms | 36 + 151 ms | 132 ms | 327 ms |
| resize | missed / longest | 1 / 16.7 ms | host 10 / 21.5 ms, helper 82 / 108.6 ms | 97 / 49.8 ms | 35 / 27.4 ms |
| resize | CPU | 1,220 ms | 126 + 1,493 ms | 1,538 ms | 2,782 ms |
| idle 10 s | CPU (no display-link log) | 1.2 ms | 0 + 0 ms (laptop) | 1.1 ms | 2.1 ms |
| all | footprint peak / steady | 45 / 44 MB | 17 + 42-64 MB | 160-181 / 84-107 MB (resize peak 702, 228 after a cache bound) | 93 / 31 MB |

Loads for type, fling and resize: N1 and N2 31.7-35.0, A1 13.6-15.5, B
21.1-24.6. Every row except A1 is above the distortion limit or close to it;
treat differences under about 5 missed targets as noise.

Input latency: A1 adds the socket hop (event round trip p50 66 µs, p95
116 µs under fling), below 1 % of a 120 Hz frame. Input-to-photon was
measured only once with screen capture on the laptop (N2 send, key to first
changed frame median 13.0 ms, p95 29.8 ms, load 288 -> 702, distorted). It is
not measured for A1 or B.

## 5. Recommendation

Choose B: one render core (`Packages/Shared/CmuxHomeRender`, on top of the
data core `Packages/Shared/CmuxHomeCore`) that draws Home as plain Core
Animation layers, hosted natively by AppKit on the Mac and by UIKit on iOS.

Reasons:
1. Same frames on both platforms by construction: both hosts run the same
   layer tree and the same render-server springs (AppKit vs Catalyst host
   mean difference 0.106/255). The pixel quality that came "only from UIKit"
   came from Core Animation springs fitted to the reference, which B keeps.
2. One process, public API only, native AppKit text input, IME,
   accessibility, focus, menus and Reduce Motion. No helper window.
3. A1 works but depends on turning off a Core Animation security control
   (`restrictedHostProcessId`), on private fence, event and accessibility
   APIs, and on UIKitMacHelper internals (the scroll stall fix). Each macOS
   update can break Home on the Mac with no public fallback (A2 is blocked).
4. A1 keeps an invisible helper window and a second app process with its own
   lifecycle, crash and activation states. Lawrence dislikes helper windows.

Strongest objection: A1 gives exact UIKit pixels and behaviour for free,
uses less memory (about 60 MB for both processes against 160 MB or more for
B), and B must re-implement what UIKit gives (scroll physics and rubber
band, text editing, context menus, the tapback picker, selection) and today
fails more frames of the send check (61 against 53 of 128). The long tail of
"slightly off" behaviour is a real cost. Answer: the iOS app renders through
the same core, so every fix lands once for both platforms; the extra
send-check failures are in the shared fit, not in AppKit; memory and resize
CPU have known fixes (bounded caches, reflow only rows whose wrap width
changes, as the earlier AppKit variant did).

Consequences: the iOS Home screen also hosts the `CmuxHomeRender` root layer
(no `UICollectionView` transcript); spring constants become Motion tokens;
the render core owns layout and motion, the data core owns the model, ops and
mirror; no second model type.

## 6. Risks and follow-ups

- Measure input-to-photon and render-server drops on a GUI session that may
  capture the screen (needs a one-time privacy approval at the console of
  the build host) before shipping.
- Port the not-yet-shared UIKit behaviours: rubber band, thread panel,
  tapbacks, edit/unsend, attachments, context menus, hit testing.
- Fix resize reflow and footprint in the landed render core.

State 2026-10-02 (Lawrence chose B): the render core draws row bitmaps off the main actor, wakes through a host-injected `HomeDeadline` (no sleep), and takes a theme-built `HomePalette` (no blue default); branch feat-cmux-next-home-render-fixes. Next: merge it when its checks are green, then wire the AppKit host (DemandTimer adapter, Ghostty-theme palette) and the iOS host.
