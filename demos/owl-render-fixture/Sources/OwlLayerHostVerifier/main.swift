import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import OwlBrowserCore
import OwlMojoBindingsGenerated
import QuartzCore

private struct Options {
    var chromiumHost: String
    var mojoRuntimePath: String
    var outputDirectory: URL
    var timeout: TimeInterval
    var includeCanvas: Bool
    var includeExample: Bool
    var includeInput: Bool
    var includeResize: Bool
    var includeLifecycle: Bool
    var includeScale: Bool
    var includeRecovery: Bool
    var includeFilePicker: Bool
    var includeGoogle: Bool
    var includeWidgets: Bool
    var includeDevTools: Bool
    var inputDiagnosticCapture: Bool
    var onlyTargets: Set<String>
}

private struct RenderTarget {
    let name: String
    let url: String
    let screenshotName: String
    let expected: Set<ExpectedPixel>
    let preInputScreenshotName: String?
    let preInputExpected: Set<ExpectedPixel>?
    let inputActions: [InputAction]
    let postInputDiagnosticScript: String?
    let postInputExpectations: [JavaScriptExpectation]
    let completeAfterInputActions: Bool

    init(
        name: String,
        url: String,
        screenshotName: String,
        expected: Set<ExpectedPixel>,
        preInputScreenshotName: String?,
        preInputExpected: Set<ExpectedPixel>?,
        inputActions: [InputAction],
        postInputDiagnosticScript: String?,
        postInputExpectations: [JavaScriptExpectation],
        completeAfterInputActions: Bool = false
    ) {
        self.name = name
        self.url = url
        self.screenshotName = screenshotName
        self.expected = expected
        self.preInputScreenshotName = preInputScreenshotName
        self.preInputExpected = preInputExpected
        self.inputActions = inputActions
        self.postInputDiagnosticScript = postInputDiagnosticScript
        self.postInputExpectations = postInputExpectations
        self.completeAfterInputActions = completeAfterInputActions
    }
}

private struct MouseClick {
    let x: Float
    let y: Float
    let button: UInt32
    let clickCount: UInt32

    init(x: Float, y: Float, button: UInt32 = 0, clickCount: UInt32 = 1) {
        self.x = x
        self.y = y
        self.button = button
        self.clickCount = clickCount
    }
}

private enum InputAction {
    case mouseClick(MouseClick)
    case mouseWheel(OwlFreshMouseEvent)
    case key(OwlFreshKeyEvent)
    case resize(OwlFreshWebViewResizeRequest, waitForMode: String)
    case text(String)
    case waitForJavaScript(label: String, script: String, expectations: [JavaScriptExpectation])
    case waitForDevToolsJavaScript(label: String, script: String, expectations: [JavaScriptExpectation])
    case waitForSurfaceTree(label: String, expectations: [SurfaceTreeExpectation])
    case waitForNoSurface(label: String, kind: OwlFreshSurfaceKind, surfaceLabel: String)
    case captureWindow(name: String, expected: Set<ExpectedPixel>)
    case detachReattachHost(name: String, expected: Set<ExpectedPixel>)
    case hideShowHostWindow(name: String, expected: Set<ExpectedPixel>)
    case verifySurfaceScale(name: String, minimumScale: Float)
    case verifyWindowEdgeCoverage(name: String)
    case captureNativeMenu(label: String, name: String, expected: Set<ExpectedPixel>, response: NativeMenuResponse)
    case captureNativeFilePicker(label: String, name: String, expected: Set<ExpectedPixel>, response: NativeFilePickerResponse)
    case openDevTools(OwlFreshDevToolsMode)
    case closeDevTools
    case clickDevToolsCloseButton
    case evaluateDevToolsJavaScript(label: String, script: String, expectations: [JavaScriptExpectation])
    case captureDetachedSurface(label: String, name: String, expected: Set<ExpectedPixel>)
    case acceptActivePopupMenuItem(UInt32)
    case cancelActivePopup
}

private enum NativeMenuResponse {
    case accept(UInt32)
    case cancel
}

private enum NativeFilePickerResponse {
    case select([String])
    case cancel
}

private struct JavaScriptExpectation {
    let key: String
    let value: ExpectedJavaScriptValue
}

private struct SurfaceTreeExpectation {
    let kind: OwlFreshSurfaceKind
    let label: String?
    let x: Int32?
    let y: Int32?
    let width: UInt32?
    let height: UInt32?
    let menuItem: String?
    let filePickerMode: String?
    let filePickerAcceptType: String?

    init(
        kind: OwlFreshSurfaceKind,
        label: String? = nil,
        x: Int32? = nil,
        y: Int32? = nil,
        width: UInt32? = nil,
        height: UInt32? = nil,
        menuItem: String? = nil,
        filePickerMode: String? = nil,
        filePickerAcceptType: String? = nil
    ) {
        self.kind = kind
        self.label = label
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.menuItem = menuItem
        self.filePickerMode = filePickerMode
        self.filePickerAcceptType = filePickerAcceptType
    }
}

private enum ExpectedJavaScriptValue {
    case string(String)
    case bool(Bool)
}

private enum KeyModifiers {
    static let command = UInt32(truncatingIfNeeded: NSEvent.ModifierFlags.command.rawValue)
    static let control = UInt32(truncatingIfNeeded: NSEvent.ModifierFlags.control.rawValue)
    static let option = UInt32(truncatingIfNeeded: NSEvent.ModifierFlags.option.rawValue)
    static let shift = UInt32(truncatingIfNeeded: NSEvent.ModifierFlags.shift.rawValue)
}

private enum KeyCodes {
    static let backspace: UInt32 = 8
    static let delete: UInt32 = 46
    static let downArrow: UInt32 = 40
    static let escape: UInt32 = 27
    static let leftArrow: UInt32 = 37
    static let returnKey: UInt32 = 13
}

private struct PixelStats: Codable {
    let width: Int
    let height: Int
    let redPixels: Int
    let greenPixels: Int
    let bluePixels: Int
    let yellowPixels: Int
    let darkPixels: Int
    let lightPixels: Int
    let nonWhitePixels: Int
}

private struct SurfaceScaleSnapshot: Codable {
    let surfaceID: UInt64
    let contextID: UInt32
    let surfaceScale: Float
    let hostedLayerContentsScale: Double
    let popupLayerCount: Int
}

private struct CaptureResult: Codable {
    let name: String
    let url: String
    let hostPID: Int32
    let hostCommand: String
    let contextID: UInt32
    let swiftWindowID: UInt32
    let screenshotPath: String
    let preInputScreenshotPath: String?
    let stats: PixelStats
    let profileHadDevToolsActivePort: Bool
    let sessionEvents: OwlBrowserSessionEventSnapshot
    let surfaceTree: OwlFreshSurfaceTree?
    let generatedTransportTracePath: String
    let generatedTransportCallCount: Int
}

private struct CrashRecoveryResult: Codable {
    let crashedHostPID: Int32
    let disconnectedEventSeen: Bool
    let beforeCrashScreenshotPath: String
    let beforeCrashContextID: UInt32
    let afterRecoveryCaptureName: String
    let afterRecoveryScreenshotPath: String
}

private struct CrashRecoveryRun {
    let metadata: CrashRecoveryResult
    let afterCapture: CaptureResult
}

private struct Summary: Codable {
    let chromiumHost: String
    let mojoRuntimePath: String
    let outputDirectory: String
    let displayPath: String
    let contextSource: String
    let controlTransport: String
    let swiftHostTransport: String
    let mojoRuntime: String
    let mojoBindingSourceChecksum: String
    let mojoBindingDeclarationCount: Int
    let devToolsFrontendHTTPAllowed: Bool
    let devToolsActivePortFound: Bool
    let remoteDebuggingArgumentFound: Bool
    let crashRecovery: CrashRecoveryResult?
    let captures: [CaptureResult]
}

private struct CaptureFailureSnapshot: Codable {
    let name: String
    let contextID: UInt32?
    let lastWindowID: UInt32?
    let lastError: String
    let lastStats: PixelStats?
    let sessionEvents: OwlBrowserSessionEventSnapshot
}

private enum VerifierError: Error, CustomStringConvertible {
    case usage(String)
    case bridge(String)
    case launch(String)
    case timeout(String)
    case capture(String)
    case pixelCheck(String)
    case forbiddenPath(String)
    case pngWrite(String)
    case layerHost(String)
    case input(String)

    var description: String {
        switch self {
        case .usage(let message),
             .bridge(let message),
             .launch(let message),
             .timeout(let message),
             .capture(let message),
             .pixelCheck(let message),
             .forbiddenPath(let message),
             .pngWrite(let message),
             .layerHost(let message),
             .input(let message):
            return message
        }
    }
}

struct OwlLayerHostVerifier {
    static func main() {
        var outputDirectory: URL?
        do {
            let options = try parseOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            outputDirectory = options.outputDirectory
            try LayerHostRunner(options: options).run()
        } catch let error as VerifierError {
            writeFatalError(error.description, outputDirectory: outputDirectory)
            fputs("error: \(error.description)\n", stderr)
            exit(1)
        } catch {
            let message = String(describing: error)
            writeFatalError(message, outputDirectory: outputDirectory)
            fputs("error: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func parseOptions(arguments: [String]) throws -> Options {
        var chromiumHost = ProcessInfo.processInfo.environment["OWL_CHROMIUM_HOST"] ?? ""
        var mojoRuntimePath = ProcessInfo.processInfo.environment["OWL_MOJO_RUNTIME_PATH"] ?? ""
        var outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/layer-host-latest", isDirectory: true)
        var timeout: TimeInterval = 30
        var includeCanvas = true
        var includeExample = true
        var includeInput = false
        var includeResize = ProcessInfo.processInfo.environment["OWL_LAYER_HOST_RESIZE_CHECK"] == "1"
        var includeLifecycle = ProcessInfo.processInfo.environment["OWL_LAYER_HOST_LIFECYCLE_CHECK"] == "1"
        var includeScale = ProcessInfo.processInfo.environment["OWL_LAYER_HOST_SCALE_CHECK"] == "1"
        var includeRecovery = ProcessInfo.processInfo.environment["OWL_LAYER_HOST_RECOVERY_CHECK"] == "1"
        var includeFilePicker = ProcessInfo.processInfo.environment["OWL_LAYER_HOST_FILE_PICKER_CHECK"] == "1"
        var includeGoogle = ProcessInfo.processInfo.environment["OWL_LAYER_HOST_GOOGLE_CHECK"] == "1"
        var includeWidgets = ProcessInfo.processInfo.environment["OWL_LAYER_HOST_WIDGET_CHECK"] == "1"
        var includeDevTools = ProcessInfo.processInfo.environment["OWL_LAYER_HOST_DEVTOOLS_CHECK"] == "1"
        var inputDiagnosticCapture = false
        var onlyTargets = Set(
            (ProcessInfo.processInfo.environment["OWL_LAYER_HOST_ONLY_TARGETS"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--chromium-host":
                index += 1
                guard index < arguments.count else {
                    throw VerifierError.usage("missing value for --chromium-host")
                }
                chromiumHost = arguments[index]
            case "--mojo-runtime":
                index += 1
                guard index < arguments.count else {
                    throw VerifierError.usage("missing value for \(argument)")
                }
                mojoRuntimePath = arguments[index]
            case "--output-dir":
                index += 1
                guard index < arguments.count else {
                    throw VerifierError.usage("missing value for --output-dir")
                }
                outputDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--timeout":
                index += 1
                guard index < arguments.count, let parsed = TimeInterval(arguments[index]) else {
                    throw VerifierError.usage("invalid value for --timeout")
                }
                timeout = parsed
            case "--skip-example":
                includeExample = false
            case "--skip-canvas":
                includeCanvas = false
            case "--input-check":
                includeInput = true
            case "--resize-check":
                includeResize = true
            case "--lifecycle-check":
                includeLifecycle = true
            case "--scale-check":
                includeScale = true
            case "--recovery-check":
                includeRecovery = true
            case "--file-picker-check":
                includeFilePicker = true
            case "--google-check":
                includeGoogle = true
            case "--widget-check":
                includeWidgets = true
            case "--devtools-check":
                includeDevTools = true
            case "--input-diagnostic-capture":
                inputDiagnosticCapture = true
            case "--only-target":
                index += 1
                guard index < arguments.count else {
                    throw VerifierError.usage("missing value for --only-target")
                }
                onlyTargets.insert(arguments[index])
            case "--help":
                print("""
                Usage: OwlLayerHostVerifier --chromium-host <path> --mojo-runtime <path> [--output-dir <dir>] [--timeout <seconds>] [--skip-canvas] [--skip-example] [--input-check] [--resize-check] [--lifecycle-check] [--scale-check] [--recovery-check] [--file-picker-check] [--google-check] [--widget-check] [--devtools-check] [--input-diagnostic-capture] [--only-target <name>]
                """)
                exit(0)
            default:
                throw VerifierError.usage("unknown argument: \(argument)")
            }
            index += 1
        }

        guard !chromiumHost.isEmpty else {
            throw VerifierError.usage("missing --chromium-host or OWL_CHROMIUM_HOST")
        }
        guard !mojoRuntimePath.isEmpty else {
            throw VerifierError.usage("missing --mojo-runtime or OWL_MOJO_RUNTIME_PATH")
        }

        return Options(
            chromiumHost: chromiumHost,
            mojoRuntimePath: mojoRuntimePath,
            outputDirectory: outputDirectory,
            timeout: timeout,
            includeCanvas: includeCanvas,
            includeExample: includeExample,
            includeInput: includeInput,
            includeResize: includeResize,
            includeLifecycle: includeLifecycle,
            includeScale: includeScale,
            includeRecovery: includeRecovery,
            includeFilePicker: includeFilePicker,
            includeGoogle: includeGoogle,
            includeWidgets: includeWidgets,
            includeDevTools: includeDevTools,
            inputDiagnosticCapture: inputDiagnosticCapture,
            onlyTargets: onlyTargets
        )
    }
}

private func writeFatalError(_ message: String, outputDirectory: URL?) {
    guard let outputDirectory else {
        return
    }
    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    try? "error: \(message)\n".write(
        to: outputDirectory.appendingPathComponent("fatal-error.txt"),
        atomically: true,
        encoding: .utf8
    )
}

private func devToolsBadgeScript(text: String) -> String {
    let quotedText = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    return """
    (() => {
      const proof = \(quotedText);
      const id = "owl-devtools-proof";
      let badge = document.getElementById(id);
      if (!badge) {
        badge = document.createElement("div");
        badge.id = id;
        Object.assign(badge.style, {
          alignItems: "center",
          background: "rgb(0,210,90)",
          border: "3px solid rgb(10,10,10)",
          boxSizing: "border-box",
          color: "rgb(10,10,10)",
          display: "flex",
          font: "700 22px -apple-system, BlinkMacSystemFont, sans-serif",
          height: "72px",
          justifyContent: "center",
          left: "40px",
          position: "fixed",
          top: "24px",
          width: "460px",
          zIndex: "2147483647"
        });
        document.documentElement.appendChild(badge);
      }
      badge.textContent = proof;
      return {
        bodyReady: !!document.body,
        proof
      };
    })()
    """
}

private func devToolsFrontendReadyScript() -> String {
    """
    (() => {
      const textFrom = root => {
        let out = "";
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
        for (let node = walker.currentNode; node; node = walker.nextNode()) {
          if (node.nodeType === Node.TEXT_NODE) {
            out += ` ${node.nodeValue}`;
          } else if (node.shadowRoot) {
            out += ` ${textFrom(node.shadowRoot)}`;
          }
        }
        return out.replace(/\\s+/g, " ").trim();
      };
      const collectElements = root => {
        const elements = [];
        const visit = current => {
          for (const element of current.querySelectorAll("*")) {
            elements.push(element);
            if (element.shadowRoot) {
              visit(element.shadowRoot);
            }
          }
        };
        visit(root);
        return elements;
      };
      const elements = collectElements(document);
      const textSample = document.body ? textFrom(document.body).slice(0, 2000) : "";
      const attributes = elements.map(element => [
        element.getAttribute("aria-label") || "",
        element.getAttribute("title") || "",
        element.getAttribute("aria-keyshortcuts") || "",
        element.textContent || ""
      ].join(" ")).join(" ");
      const tagNames = elements
        .filter(element => element.classList?.contains("webkit-html-tag-name"))
        .map(element => element.textContent?.trim() || "")
        .filter(Boolean);
      const hasDevToolsChrome =
        !!document.querySelector(".inspector-view, .tabbed-pane-header, .toolbar, .main-tabbed-pane") ||
        /\\b(Elements|Console|Sources|Network)\\b/.test(textSample);
      const hasElementPickerButton = /Select an element in the page to inspect it/.test(attributes);
      const hasDeviceToolbarButton = /Toggle device toolbar/.test(attributes);
      const hasElementsPanelDOM = tagNames.includes("html") && tagNames.includes("body");
      return {
        path: location.pathname,
        readyState: document.readyState,
        bodyReady: !!document.body,
        runtimeReady: !!globalThis.runtime,
        hasDevToolsChrome,
        hasElementPickerButton,
        hasDeviceToolbarButton,
        hasElementsPanelDOM,
        title: document.title,
        tagNames: tagNames.slice(0, 20).join(","),
        textSample,
        bodyHTMLSample: document.body ? document.body.innerHTML.slice(0, 500) : ""
      };
    })()
    """
}

private func devToolsPageBoundsScript() -> String {
    """
    (() => {
      if (window.owlDevToolsFixture?.measure) {
        window.owlDevToolsFixture.measure();
      }
      return window.owlDevToolsFixture?.bounds || {
        size: `${window.innerWidth}x${window.innerHeight}`,
        innerWidth: window.innerWidth,
        innerHeight: window.innerHeight
      };
    })()
    """
}

OwlLayerHostVerifier.main()

private final class LayerHostRunner {
    private let options: Options
    private let fileManager = FileManager.default
    private let contentSize = CGSize(width: 960, height: 640)

    init(options: Options) {
        self.options = options
    }

    func run() throws {
        guard fileManager.isExecutableFile(atPath: options.chromiumHost) else {
            throw VerifierError.usage("Chromium host is not executable: \(options.chromiumHost)")
        }
        guard fileManager.fileExists(atPath: options.mojoRuntimePath) else {
            throw VerifierError.usage("OWL Mojo runtime dylib does not exist: \(options.mojoRuntimePath)")
        }

        try fileManager.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        let fixtureDirectory = options.outputDirectory.appendingPathComponent("fixtures", isDirectory: true)
        try fileManager.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)

        let canvasFixture = try writeFixture(
            name: "canvas-fixture",
            html: Fixtures.canvasFixture,
            directory: fixtureDirectory
        )
        let inputFixture = try writeFixture(
            name: "input-fixture",
            html: Fixtures.inputFixture,
            directory: fixtureDirectory
        )
        let formFixture = try writeFixture(
            name: "form-fixture",
            html: Fixtures.formFixture,
            directory: fixtureDirectory
        )
        let modifierFixture = try writeFixture(
            name: "modifier-fixture",
            html: Fixtures.modifierFixture,
            directory: fixtureDirectory
        )
        let resizeFixture = try writeFixture(
            name: "resize-fixture",
            html: Fixtures.resizeFixture,
            directory: fixtureDirectory
        )
        let scrollFixture = try writeFixture(
            name: "scroll-fixture",
            html: Fixtures.scrollFixture,
            directory: fixtureDirectory
        )
        let textEditingFixture = try writeFixture(
            name: "text-edit-fixture",
            html: Fixtures.textEditingFixture,
            directory: fixtureDirectory
        )
        let widgetFixture = try writeFixture(
            name: "widget-fixture",
            html: Fixtures.widgetFixture,
            directory: fixtureDirectory
        )
        let nativePopupFixture = try writeFixture(
            name: "native-popup-fixture",
            html: Fixtures.nativePopupFixture,
            directory: fixtureDirectory
        )
        let plainNativeSelectFixture = try writeFixture(
            name: "plain-native-select-fixture",
            html: Fixtures.plainNativeSelectFixture,
            directory: fixtureDirectory
        )
        let filePickerFixture = try writeFixture(
            name: "file-picker-fixture",
            html: Fixtures.filePickerFixture,
            directory: fixtureDirectory
        )
        let devToolsFixture = try writeFixture(
            name: "devtools-fixture",
            html: Fixtures.devToolsFixture,
            directory: fixtureDirectory
        )
        let filePickerUpload = fixtureDirectory.appendingPathComponent("owl-upload.txt")
        try "OWL file picker upload\n".write(to: filePickerUpload, atomically: true, encoding: .utf8)
        let crashRecoveryFixture = try writeFixture(
            name: "crash-recovery-fixture",
            html: Fixtures.canvasFixture,
            directory: fixtureDirectory
        )
        var targets: [RenderTarget] = []
        if options.includeCanvas {
            targets.append(RenderTarget(
                name: "canvas-fixture",
                url: canvasFixture.absoluteString,
                screenshotName: "canvas-fixture-layer-host.png",
                expected: [.red, .green, .blue, .dark],
                preInputScreenshotName: nil,
                preInputExpected: nil,
                inputActions: [],
                postInputDiagnosticScript: nil,
                postInputExpectations: []
            ))
        }
        if options.includeExample {
            targets.append(
                RenderTarget(
                    name: "example-com",
                    url: "https://example.com/",
                    screenshotName: "example-com-layer-host.png",
                    expected: [.dark, .light, .nonWhite],
                    preInputScreenshotName: nil,
                    preInputExpected: nil,
                    inputActions: [],
                    postInputDiagnosticScript: nil,
                    postInputExpectations: []
                )
            )
        }
        if options.includeInput {
            targets.append(
                RenderTarget(
                    name: "input-fixture",
                    url: inputFixture.absoluteString,
                    screenshotName: "input-fixture-after-click.png",
                    expected: [.yellow, .dark],
                    preInputScreenshotName: "input-fixture-before-click.png",
                    preInputExpected: [.red, .dark],
                    inputActions: [
                        .mouseClick(MouseClick(x: 170, y: 180)),
                        .key(OwlFreshKeyEvent(keyDown: true, keyCode: 88, text: "x", modifiers: 0)),
                    ],
                    postInputDiagnosticScript: "({className: document.body.className, status: document.getElementById('status')?.textContent || ''})",
                    postInputExpectations: [
                        JavaScriptExpectation(key: "status", value: .string("OWL_INPUT_CLICKED")),
                    ]
                )
            )
            targets.append(
                RenderTarget(
                    name: "form-fixture",
                    url: formFixture.absoluteString,
                    screenshotName: "form-fixture-after-submit.png",
                    expected: [.green, .yellow, .dark],
                    preInputScreenshotName: "form-fixture-before-input.png",
                    preInputExpected: [.blue, .dark, .light],
                    inputActions: [
                        .mouseClick(MouseClick(x: 170, y: 152)),
                        .text("hello owl"),
                        .mouseClick(MouseClick(x: 68, y: 244)),
                        .mouseClick(MouseClick(x: 151, y: 333)),
                    ],
                    postInputDiagnosticScript: """
                    ({
                      activeId: document.activeElement?.id || "",
                      checked: document.getElementById("agree")?.checked === true,
                      status: document.getElementById("status")?.textContent || "",
                      submitted: document.body.classList.contains("submitted"),
                      typed: document.getElementById("nameInput")?.value || ""
                    })
                    """,
                    postInputExpectations: [
                        JavaScriptExpectation(key: "checked", value: .bool(true)),
                        JavaScriptExpectation(key: "status", value: .string("HELLO_OWL_SUBMITTED")),
                        JavaScriptExpectation(key: "submitted", value: .bool(true)),
                        JavaScriptExpectation(key: "typed", value: .string("hello owl")),
                    ]
                )
            )
            targets.append(
                RenderTarget(
                    name: "modifier-fixture",
                    url: modifierFixture.absoluteString,
                    screenshotName: "modifier-fixture-after-input.png",
                    expected: [.green, .yellow, .dark],
                    preInputScreenshotName: "modifier-fixture-before-input.png",
                    preInputExpected: [.blue, .dark, .light],
                    inputActions: [
                        .mouseClick(MouseClick(x: 180, y: 152)),
                        .text("plain"),
                        .key(OwlFreshKeyEvent(keyDown: true, keyCode: 77, text: "", modifiers: KeyModifiers.command)),
                        .key(OwlFreshKeyEvent(keyDown: true, keyCode: 79, text: "", modifiers: KeyModifiers.option)),
                        .key(OwlFreshKeyEvent(keyDown: true, keyCode: 67, text: "", modifiers: KeyModifiers.control)),
                        .key(OwlFreshKeyEvent(keyDown: true, keyCode: 83, text: "S", modifiers: KeyModifiers.shift)),
                    ],
                    postInputDiagnosticScript: """
                    ({
                      commandSeen: window.owlModifierState?.commandSeen === true,
                      controlSeen: window.owlModifierState?.controlSeen === true,
                      optionSeen: window.owlModifierState?.optionSeen === true,
                      shiftSeen: window.owlModifierState?.shiftSeen === true,
                      status: document.getElementById("status")?.textContent || "",
                      typed: document.getElementById("modInput")?.value || ""
                    })
                    """,
                    postInputExpectations: [
                        JavaScriptExpectation(key: "commandSeen", value: .bool(true)),
                        JavaScriptExpectation(key: "controlSeen", value: .bool(true)),
                        JavaScriptExpectation(key: "optionSeen", value: .bool(true)),
                        JavaScriptExpectation(key: "shiftSeen", value: .bool(true)),
                        JavaScriptExpectation(key: "status", value: .string("OWL_MODIFIERS_OK")),
                        JavaScriptExpectation(key: "typed", value: .string("plainS")),
                    ]
                )
            )
            let requestedResizeTargets = !options.onlyTargets.isDisjoint(with: [
                "resize-small-fixture",
                "resize-roundtrip-fixture",
            ])
            if options.includeResize || requestedResizeTargets {
                targets.append(
                    RenderTarget(
                        name: "resize-small-fixture",
                        url: resizeFixture.absoluteString,
                        screenshotName: "resize-small-after.png",
                        expected: [.green, .yellow, .dark],
                        preInputScreenshotName: "resize-small-before.png",
                        preInputExpected: [.blue, .dark, .light],
                        inputActions: [
                            .resize(OwlFreshWebViewResizeRequest(width: 720, height: 480, scale: 1.0), waitForMode: "small"),
                            .verifyWindowEdgeCoverage(name: "resize-small-edge-coverage.png"),
                        ],
                        postInputDiagnosticScript: """
                        ({
                          mode: window.owlResizeState?.mode || "",
                          status: document.getElementById("status")?.textContent || ""
                        })
                        """,
                        postInputExpectations: [
                            JavaScriptExpectation(key: "mode", value: .string("small")),
                            JavaScriptExpectation(key: "status", value: .string("OWL_RESIZE_SMALL_OK")),
                        ]
                    )
                )
                targets.append(
                    RenderTarget(
                        name: "resize-roundtrip-fixture",
                        url: resizeFixture.absoluteString,
                        screenshotName: "resize-roundtrip-after.png",
                        expected: [.green, .yellow, .dark],
                        preInputScreenshotName: "resize-roundtrip-before.png",
                        preInputExpected: [.blue, .dark, .light],
                        inputActions: [
                            .resize(OwlFreshWebViewResizeRequest(width: 720, height: 480, scale: 1.0), waitForMode: "small"),
                            .verifyWindowEdgeCoverage(name: "resize-roundtrip-small-edge-coverage.png"),
                            .resize(OwlFreshWebViewResizeRequest(width: 960, height: 640, scale: 1.0), waitForMode: "restored"),
                            .verifyWindowEdgeCoverage(name: "resize-roundtrip-restored-edge-coverage.png"),
                        ],
                        postInputDiagnosticScript: """
                        ({
                          mode: window.owlResizeState?.mode || "",
                          status: document.getElementById("status")?.textContent || ""
                        })
                        """,
                        postInputExpectations: [
                            JavaScriptExpectation(key: "mode", value: .string("restored")),
                            JavaScriptExpectation(key: "status", value: .string("OWL_RESIZE_ROUNDTRIP_OK")),
                        ]
                    )
                )
            }
            let requestedLifecycleTargets = options.onlyTargets.contains("lifecycle-fixture")
            if options.includeLifecycle || requestedLifecycleTargets {
                let lifecycleExpected: Set<ExpectedPixel> = [.red, .blue, .dark, .nonWhite]
                targets.append(
                    RenderTarget(
                        name: "lifecycle-fixture",
                        url: resizeFixture.absoluteString,
                        screenshotName: "lifecycle-after.png",
                        expected: lifecycleExpected,
                        preInputScreenshotName: "lifecycle-before.png",
                        preInputExpected: lifecycleExpected,
                        inputActions: [
                            .waitForJavaScript(
                                label: "lifecycle fixture ready",
                                script: """
                                ({
                                  mode: window.owlResizeState?.mode || "",
                                  status: document.getElementById("status")?.textContent || ""
                                })
                                """,
                                expectations: [
                                    JavaScriptExpectation(key: "mode", value: .string("initial")),
                                    JavaScriptExpectation(key: "status", value: .string("OWL_RESIZE_READY")),
                                ]
                            ),
                            .captureWindow(name: "lifecycle-before-detach.png", expected: lifecycleExpected),
                            .detachReattachHost(name: "lifecycle-after-reattach.png", expected: lifecycleExpected),
                            .hideShowHostWindow(name: "lifecycle-after-hide-show.png", expected: lifecycleExpected),
                            .verifyWindowEdgeCoverage(name: "lifecycle-edge-coverage.png"),
                        ],
                        postInputDiagnosticScript: """
                        ({
                          mode: window.owlResizeState?.mode || "",
                          status: document.getElementById("status")?.textContent || ""
                        })
                        """,
                        postInputExpectations: [
                            JavaScriptExpectation(key: "mode", value: .string("initial")),
                            JavaScriptExpectation(key: "status", value: .string("OWL_RESIZE_READY")),
                        ]
                    )
                )
            }
            let requestedScaleTargets = options.onlyTargets.contains("scale-fixture")
            if options.includeScale || requestedScaleTargets {
                let scaleExpected: Set<ExpectedPixel> = [.red, .blue, .dark, .nonWhite]
                targets.append(
                    RenderTarget(
                        name: "scale-fixture",
                        url: resizeFixture.absoluteString,
                        screenshotName: "scale-fixture-after.png",
                        expected: scaleExpected,
                        preInputScreenshotName: "scale-fixture-before.png",
                        preInputExpected: scaleExpected,
                        inputActions: [
                            .waitForJavaScript(
                                label: "scale fixture ready",
                                script: """
                                ({
                                  devicePixelRatio: window.devicePixelRatio || 0,
                                  mode: window.owlResizeState?.mode || "",
                                  status: document.getElementById("status")?.textContent || ""
                                })
                                """,
                                expectations: [
                                    JavaScriptExpectation(key: "mode", value: .string("initial")),
                                    JavaScriptExpectation(key: "status", value: .string("OWL_RESIZE_READY")),
                                ]
                            ),
                            .verifySurfaceScale(name: "scale-fixture-surface-scale.json", minimumScale: 1.0),
                            .captureWindow(name: "scale-fixture-scale-applied.png", expected: scaleExpected),
                            .verifyWindowEdgeCoverage(name: "scale-fixture-edge-coverage.png"),
                        ],
                        postInputDiagnosticScript: """
                        ({
                          mode: window.owlResizeState?.mode || "",
                          status: document.getElementById("status")?.textContent || ""
                        })
                        """,
                        postInputExpectations: [
                            JavaScriptExpectation(key: "mode", value: .string("initial")),
                            JavaScriptExpectation(key: "status", value: .string("OWL_RESIZE_READY")),
                        ]
                    )
                )
            }
            targets.append(
                RenderTarget(
                    name: "scroll-fixture",
                    url: scrollFixture.absoluteString,
                    screenshotName: "scroll-fixture-after.png",
                    expected: [.green, .yellow, .dark],
                    preInputScreenshotName: "scroll-fixture-before.png",
                    preInputExpected: [.blue, .dark, .light],
                    inputActions: [
                        .mouseWheel(OwlFreshMouseEvent(
                            kind: .wheel,
                            x: 520,
                            y: 520,
                            button: 0,
                            clickCount: 0,
                            deltaX: 0,
                            deltaY: -900,
                            modifiers: 0
                        )),
                    ],
                    postInputDiagnosticScript: """
                    ({
                      ok: window.owlScrollState?.ok === true,
                      firstVisibleLine: window.owlScrollState?.firstVisibleLine || "",
                      status: document.getElementById("status")?.textContent || ""
                    })
                    """,
                    postInputExpectations: [
                        JavaScriptExpectation(key: "ok", value: .bool(true)),
                        JavaScriptExpectation(key: "firstVisibleLine", value: .string("LINE_06")),
                        JavaScriptExpectation(key: "status", value: .string("OWL_SCROLL_LINE_OK")),
                    ]
                )
            )
            targets.append(
                RenderTarget(
                    name: "text-edit-fixture",
                    url: textEditingFixture.absoluteString,
                    screenshotName: "text-edit-fixture-after.png",
                    expected: [.green, .yellow, .dark],
                    preInputScreenshotName: "text-edit-fixture-before.png",
                    preInputExpected: [.blue, .dark, .light],
                    inputActions: [
                        .mouseClick(MouseClick(x: 170, y: 152)),
                        .text("abcdef"),
                        .key(OwlFreshKeyEvent(keyDown: true, keyCode: KeyCodes.leftArrow, text: "", modifiers: 0)),
                        .key(OwlFreshKeyEvent(keyDown: true, keyCode: KeyCodes.leftArrow, text: "", modifiers: 0)),
                        .key(OwlFreshKeyEvent(keyDown: true, keyCode: KeyCodes.backspace, text: "", modifiers: 0)),
                        .key(OwlFreshKeyEvent(keyDown: true, keyCode: KeyCodes.delete, text: "", modifiers: 0)),
                        .text("Z"),
                        .text("final"),
                        .mouseClick(MouseClick(x: 170, y: 356)),
                        .text("selection"),
                        .key(OwlFreshKeyEvent(keyDown: true, keyCode: KeyCodes.leftArrow, text: "", modifiers: KeyModifiers.shift)),
                        .key(OwlFreshKeyEvent(keyDown: true, keyCode: KeyCodes.leftArrow, text: "", modifiers: KeyModifiers.shift)),
                        .key(OwlFreshKeyEvent(keyDown: true, keyCode: KeyCodes.leftArrow, text: "", modifiers: KeyModifiers.shift)),
                        .text("XYZ"),
                    ],
                    postInputDiagnosticScript: """
                    ({
                      editTyped: document.getElementById("editInput")?.value || "",
                      sawEditIntermediate: window.owlTextEditState?.sawIntermediate === true,
                      sawSelection: window.owlTextEditState?.sawSelection === true,
                      sawSelectionReplacement: window.owlTextEditState?.sawSelectionReplacement === true,
                      selectionTyped: document.getElementById("selectionInput")?.value || "",
                      sawIntermediate: window.owlTextEditState?.sawIntermediate === true,
                      status: document.getElementById("status")?.textContent || "",
                      typed: document.getElementById("editInput")?.value || ""
                    })
                    """,
                    postInputExpectations: [
                        JavaScriptExpectation(key: "editTyped", value: .string("abcZfinalf")),
                        JavaScriptExpectation(key: "sawEditIntermediate", value: .bool(true)),
                        JavaScriptExpectation(key: "sawIntermediate", value: .bool(true)),
                        JavaScriptExpectation(key: "sawSelection", value: .bool(true)),
                        JavaScriptExpectation(key: "sawSelectionReplacement", value: .bool(true)),
                        JavaScriptExpectation(key: "selectionTyped", value: .string("selectXYZ")),
                        JavaScriptExpectation(key: "status", value: .string("OWL_TEXT_SELECTION_OK")),
                        JavaScriptExpectation(key: "typed", value: .string("abcZfinalf")),
                    ]
                )
            )
        }
        let requestedGoogleTargets = options.onlyTargets.contains("google-search")
        if options.includeGoogle || requestedGoogleTargets {
            targets.append(
                RenderTarget(
                    name: "google-search",
                    url: "https://www.google.com/?hl=en&igu=1",
                    screenshotName: "google-search-after-type.png",
                    expected: [.dark, .light, .nonWhite],
                    preInputScreenshotName: "google-search-before-type.png",
                    preInputExpected: [.dark, .light, .nonWhite],
                    inputActions: [
                        .waitForJavaScript(
                            label: "google search box",
                            script: """
                            (() => {
                              const input = document.querySelector('textarea[name="q"], input[name="q"]');
                              if (!input) {
                                return { ready: false };
                              }
                              input.focus();
                              return {
                                activeName: document.activeElement?.getAttribute("name") || "",
                                ready: document.activeElement === input,
                                tag: input.tagName
                              };
                            })()
                            """,
                            expectations: [
                                JavaScriptExpectation(key: "ready", value: .bool(true)),
                            ]
                        ),
                        .text("owl mojo layer host"),
                    ],
                    postInputDiagnosticScript: """
                    ({
                      activeName: document.activeElement?.getAttribute("name") || "",
                      query: document.querySelector('textarea[name="q"], input[name="q"]')?.value || "",
                      title: document.title || ""
                    })
                    """,
                    postInputExpectations: [
                        JavaScriptExpectation(key: "query", value: .string("owl mojo layer host")),
                    ]
                )
            )
        }
        let requestedWidgetTargets = options.onlyTargets.contains("widget-fixture")
            || options.onlyTargets.contains("native-popup-fixture")
            || options.onlyTargets.contains("plain-native-select-fixture")
        if options.includeWidgets || requestedWidgetTargets {
            targets.append(
                RenderTarget(
                    name: "widget-fixture",
                    url: widgetFixture.absoluteString,
                    screenshotName: "widget-fixture-after-input.png",
                    expected: [.green, .yellow, .dark],
                    preInputScreenshotName: "widget-fixture-before-input.png",
                    preInputExpected: [.blue, .dark, .light],
                    inputActions: [
                        .waitForJavaScript(
                            label: "widget fixture ready",
                            script: """
                            ({
                              ready: window.owlWidgetState?.ready === true
                            })
                            """,
                            expectations: [
                                JavaScriptExpectation(key: "ready", value: .bool(true)),
                            ]
                        ),
                        .mouseClick(MouseClick(x: 188, y: 190)),
                        .mouseClick(MouseClick(x: 330, y: 312, button: 2)),
                        .cancelActivePopup,
                        .mouseClick(MouseClick(x: 192, y: 470)),
                        .key(OwlFreshKeyEvent(keyDown: true, keyCode: KeyCodes.escape, text: "", modifiers: 0)),
                    ],
                    postInputDiagnosticScript: """
                    ({
                      colorClicked: window.owlWidgetState?.colorClicked === true,
                      colorFocused: window.owlWidgetState?.colorFocused === true,
                      contextSeen: window.owlWidgetState?.contextSeen === true,
                      selectValue: document.getElementById("nativeSelect")?.value || "",
                      status: document.getElementById("status")?.textContent || ""
                    })
                    """,
                    postInputExpectations: [
                        JavaScriptExpectation(key: "colorClicked", value: .bool(true)),
                        JavaScriptExpectation(key: "colorFocused", value: .bool(true)),
                        JavaScriptExpectation(key: "contextSeen", value: .bool(true)),
                        JavaScriptExpectation(key: "selectValue", value: .string("beta")),
                        JavaScriptExpectation(key: "status", value: .string("OWL_WIDGETS_OK")),
                    ]
                )
            )
            targets.append(
                RenderTarget(
                    name: "plain-native-select-fixture",
                    url: plainNativeSelectFixture.absoluteString,
                    screenshotName: "plain-native-select-after-input.png",
                    expected: [.dark, .light, .nonWhite, .green],
                    preInputScreenshotName: "plain-native-select-before-input.png",
                    preInputExpected: [.dark, .light, .nonWhite, .blue],
                    inputActions: [
                        .waitForJavaScript(
                            label: "plain native select ready",
                            script: """
                            ({
                              hit: document.elementFromPoint(158, 159)?.id || "",
                              ready: window.owlPlainNativeSelectState?.ready === true &&
                                document.readyState === "complete" &&
                                document.getElementById("plainSelect") instanceof HTMLSelectElement
                            })
                            """,
                            expectations: [
                                JavaScriptExpectation(key: "hit", value: .string("plainSelect")),
                                JavaScriptExpectation(key: "ready", value: .bool(true)),
                            ]
                        ),
                        .mouseClick(MouseClick(x: 158, y: 159)),
                        .waitForSurfaceTree(
                            label: "plain native select popup surface",
                            expectations: [
                                SurfaceTreeExpectation(
                                    kind: .nativeMenu,
                                    label: "select-menu",
                                    menuItem: "Beta"
                                ),
                            ]
                        ),
                        .captureNativeMenu(
                            label: "select-menu",
                            name: "plain-native-select-popup-open.png",
                            expected: [.dark, .light, .nonWhite],
                            response: .accept(1)
                        ),
                    ],
                    postInputDiagnosticScript: """
                    ({
                      selectValue: document.getElementById("plainSelect")?.value || ""
                    })
                    """,
                    postInputExpectations: [
                        JavaScriptExpectation(key: "selectValue", value: .string("beta")),
                    ]
                )
            )
            targets.append(
                RenderTarget(
                    name: "native-popup-fixture",
                    url: nativePopupFixture.absoluteString,
                    screenshotName: "native-popup-after-input.png",
                    expected: [.green, .yellow, .dark],
                    preInputScreenshotName: "native-popup-before-input.png",
                    preInputExpected: [.blue, .dark, .light],
                    inputActions: [
                        .waitForJavaScript(
                            label: "native popup fixture ready",
                            script: """
                            ({
                              ready: window.owlNativePopupState?.ready === true
                            })
                            """,
                            expectations: [
                                JavaScriptExpectation(key: "ready", value: .bool(true)),
                            ]
                        ),
                        .mouseClick(MouseClick(x: 190, y: 172)),
                        .waitForSurfaceTree(
                            label: "select popup surface",
                            expectations: [
                                SurfaceTreeExpectation(
                                    kind: .nativeMenu,
                                    label: "select-menu",
                                    menuItem: "BETA_NATIVE_OPTION"
                                ),
                            ]
                        ),
                        .captureNativeMenu(
                            label: "select-menu",
                            name: "native-select-popup-open.png",
                            expected: [.dark, .light, .nonWhite],
                            response: .accept(1)
                        ),
                        .waitForJavaScript(
                            label: "native select accepted",
                            script: """
                            ({
                              selectValue: document.getElementById("nativeSelect")?.value || ""
                            })
                            """,
                            expectations: [
                                JavaScriptExpectation(key: "selectValue", value: .string("beta")),
                            ]
                        ),
                        .mouseClick(MouseClick(x: 330, y: 338, button: 2)),
                        .waitForSurfaceTree(
                            label: "context menu surface",
                            expectations: [
                                SurfaceTreeExpectation(
                                    kind: .nativeMenu,
                                    label: "context-menu",
                                    menuItem: "Inspect"
                                ),
                            ]
                        ),
                        .captureNativeMenu(
                            label: "context-menu",
                            name: "native-context-menu-open.png",
                            expected: [.dark, .light, .nonWhite],
                            response: .cancel
                        ),
                    ],
                    postInputDiagnosticScript: """
                    ({
                      contextSeen: window.owlNativePopupState?.contextSeen === true,
                      selectValue: document.getElementById("nativeSelect")?.value || "",
                      status: document.getElementById("status")?.textContent || ""
                    })
                    """,
                    postInputExpectations: [
                        JavaScriptExpectation(key: "contextSeen", value: .bool(true)),
                        JavaScriptExpectation(key: "selectValue", value: .string("beta")),
                        JavaScriptExpectation(key: "status", value: .string("OWL_NATIVE_POPUPS_OK")),
                    ]
                )
            )
        }
        let requestedFilePickerTargets = options.onlyTargets.contains("file-picker-fixture")
        if options.includeFilePicker || requestedFilePickerTargets {
            targets.append(
                RenderTarget(
                    name: "file-picker-fixture",
                    url: filePickerFixture.absoluteString,
                    screenshotName: "file-picker-after-select.png",
                    expected: [.green, .blue, .dark, .light],
                    preInputScreenshotName: "file-picker-before-open.png",
                    preInputExpected: [.blue, .dark, .light],
                    inputActions: [
                        .waitForJavaScript(
                            label: "file picker fixture ready",
                            script: """
                            ({
                              hit: document.elementFromPoint(190, 168)?.id || "",
                              ready: window.owlFilePickerState?.ready === true
                            })
                            """,
                            expectations: [
                                JavaScriptExpectation(key: "hit", value: .string("fileInput")),
                                JavaScriptExpectation(key: "ready", value: .bool(true)),
                            ]
                        ),
                        .mouseClick(MouseClick(x: 190, y: 168)),
                        .waitForSurfaceTree(
                            label: "native file picker surface",
                            expectations: [
                                SurfaceTreeExpectation(
                                    kind: .nativeFilePicker,
                                    label: "file-picker",
                                    filePickerMode: "open",
                                    filePickerAcceptType: ".txt"
                                ),
                            ]
                        ),
                        .captureNativeFilePicker(
                            label: "file-picker",
                            name: "file-picker-native-panel-open.png",
                            expected: [.dark, .light, .nonWhite],
                            response: .select([filePickerUpload.path])
                        ),
                    ],
                    postInputDiagnosticScript: """
                    ({
                      changeSeen: window.owlFilePickerState?.changeSeen === true,
                      filesLength: document.getElementById("fileInput")?.files?.length ?? -1,
                      status: document.getElementById("status")?.textContent || ""
                    })
                    """,
                    postInputExpectations: [
                        JavaScriptExpectation(key: "changeSeen", value: .bool(true)),
                        JavaScriptExpectation(key: "status", value: .string("OWL_FILE_PICKER_SELECTED")),
                    ]
                )
            )
        }
        let requestedDevToolsTargets = options.onlyTargets.contains(where: { $0.hasPrefix("devtools-") })
        if options.includeDevTools || requestedDevToolsTargets {
            let dockThickness = UInt32(280)
            let sideThickness = UInt32(360)
            let fullWidth = UInt32(contentSize.width)
            let fullHeight = UInt32(contentSize.height)
            let sideWebWidth = fullWidth - sideThickness
            let bottomWebHeight = fullHeight - dockThickness
            let frontendReadyExpectations = [
                JavaScriptExpectation(key: "path", value: .string("/devtools/devtools_app.html")),
                JavaScriptExpectation(key: "readyState", value: .string("complete")),
                JavaScriptExpectation(key: "bodyReady", value: .bool(true)),
                JavaScriptExpectation(key: "runtimeReady", value: .bool(true)),
                JavaScriptExpectation(key: "hasDevToolsChrome", value: .bool(true)),
                JavaScriptExpectation(key: "hasElementPickerButton", value: .bool(true)),
                JavaScriptExpectation(key: "hasDeviceToolbarButton", value: .bool(true)),
                JavaScriptExpectation(key: "hasElementsPanelDOM", value: .bool(true)),
            ]

            struct DevToolsDockTargetSpec {
                let name: String
                let mode: OwlFreshDevToolsMode
                let label: String
                let webX: Int32
                let webY: Int32
                let webWidth: UInt32
                let webHeight: UInt32
                let devToolsX: Int32
                let devToolsY: Int32
                let devToolsWidth: UInt32
                let devToolsHeight: UInt32
                let closesAfterProof: Bool
            }

            let dockTargets = [
                DevToolsDockTargetSpec(
                    name: "devtools-bottom-fixture",
                    mode: .bottom,
                    label: "devtools-bottom",
                    webX: 0,
                    webY: Int32(dockThickness),
                    webWidth: fullWidth,
                    webHeight: bottomWebHeight,
                    devToolsX: 0,
                    devToolsY: 0,
                    devToolsWidth: fullWidth,
                    devToolsHeight: dockThickness,
                    closesAfterProof: true
                ),
                DevToolsDockTargetSpec(
                    name: "devtools-right-fixture",
                    mode: .right,
                    label: "devtools-right",
                    webX: 0,
                    webY: 0,
                    webWidth: sideWebWidth,
                    webHeight: fullHeight,
                    devToolsX: Int32(sideWebWidth),
                    devToolsY: 0,
                    devToolsWidth: sideThickness,
                    devToolsHeight: fullHeight,
                    closesAfterProof: false
                ),
                DevToolsDockTargetSpec(
                    name: "devtools-left-fixture",
                    mode: .left,
                    label: "devtools-left",
                    webX: Int32(sideThickness),
                    webY: 0,
                    webWidth: sideWebWidth,
                    webHeight: fullHeight,
                    devToolsX: 0,
                    devToolsY: 0,
                    devToolsWidth: sideThickness,
                    devToolsHeight: fullHeight,
                    closesAfterProof: false
                ),
            ]

            for spec in dockTargets {
                var actions: [InputAction] = [
                    .openDevTools(spec.mode),
                    .waitForSurfaceTree(
                        label: "\(spec.label) dock layout",
                        expectations: [
                            SurfaceTreeExpectation(
                                kind: .webView,
                                label: "web-view",
                                x: spec.webX,
                                y: spec.webY,
                                width: spec.webWidth,
                                height: spec.webHeight
                            ),
                            SurfaceTreeExpectation(
                                kind: .devTools,
                                label: spec.label,
                                x: spec.devToolsX,
                                y: spec.devToolsY,
                                width: spec.devToolsWidth,
                                height: spec.devToolsHeight
                            ),
                        ]
                    ),
                    .waitForJavaScript(
                        label: "\(spec.label) inspected page bounds",
                        script: devToolsPageBoundsScript(),
                        expectations: [
                            JavaScriptExpectation(
                                key: "size",
                                value: .string("\(spec.webWidth)x\(spec.webHeight)")
                            ),
                        ]
                    ),
                    .waitForDevToolsJavaScript(
                        label: "\(spec.label) frontend",
                        script: devToolsFrontendReadyScript(),
                        expectations: frontendReadyExpectations
                    ),
                    .captureWindow(name: "\(spec.name)-ui.png", expected: [.blue, .dark, .light, .nonWhite]),
                ]
                if spec.closesAfterProof {
                    actions.append(contentsOf: [
                        .clickDevToolsCloseButton,
                        .waitForNoSurface(
                            label: "\(spec.label) closed",
                            kind: .devTools,
                            surfaceLabel: spec.label
                        ),
                        .waitForJavaScript(
                            label: "\(spec.label) restored inspected page bounds",
                            script: devToolsPageBoundsScript(),
                            expectations: [
                                JavaScriptExpectation(
                                    key: "size",
                                    value: .string("\(fullWidth)x\(fullHeight)")
                                ),
                            ]
                        ),
                        .captureWindow(name: "\(spec.name)-after-close.png", expected: [.blue, .dark, .light, .nonWhite]),
                    ])
                }
                targets.append(
                    RenderTarget(
                        name: spec.name,
                        url: devToolsFixture.absoluteString,
                        screenshotName: "\(spec.name)-ui.png",
                        expected: [.blue, .dark, .light, .nonWhite],
                        preInputScreenshotName: "\(spec.name)-before-open.png",
                        preInputExpected: [.blue, .dark, .light, .nonWhite],
                        inputActions: actions,
                        postInputDiagnosticScript: nil,
                        postInputExpectations: [],
                        completeAfterInputActions: true
                    )
                )
            }

            targets.append(
                RenderTarget(
                    name: "devtools-window-fixture",
                    url: devToolsFixture.absoluteString,
                    screenshotName: "devtools-window-after-open.png",
                    expected: [.nonWhite],
                    preInputScreenshotName: "devtools-window-before-open.png",
                    preInputExpected: [.blue, .dark, .light, .nonWhite],
                    inputActions: [
                        .openDevTools(.window),
                        .waitForSurfaceTree(
                            label: "window DevTools surface",
                            expectations: [
                                SurfaceTreeExpectation(
                                    kind: .webView,
                                    label: "web-view",
                                    x: 0,
                                    y: 0,
                                    width: fullWidth,
                                    height: fullHeight
                                ),
                                SurfaceTreeExpectation(
                                    kind: .devTools,
                                    label: "devtools-window",
                                    x: 0,
                                    y: 0,
                                    width: fullWidth,
                                    height: fullHeight
                                ),
                            ]
                        ),
                        .waitForJavaScript(
                            label: "window mode inspected page bounds",
                            script: devToolsPageBoundsScript(),
                            expectations: [
                                JavaScriptExpectation(
                                    key: "size",
                                    value: .string("\(fullWidth)x\(fullHeight)")
                                ),
                            ]
                        ),
                        .waitForDevToolsJavaScript(
                            label: "window DevTools frontend",
                            script: devToolsFrontendReadyScript(),
                            expectations: frontendReadyExpectations
                        ),
                        .captureDetachedSurface(
                            label: "devtools-window",
                            name: "devtools-window-ui.png",
                            expected: [.nonWhite]
                        ),
                        .captureDetachedSurface(
                            label: "devtools-window",
                            name: "devtools-window-after-open.png",
                            expected: [.nonWhite]
                        ),
                    ],
                    postInputDiagnosticScript: nil,
                    postInputExpectations: [],
                    completeAfterInputActions: true
                )
            )
        }
        let recoveryTargetName = "crash-recovery-fixture"
        let requestedRecoveryTarget = options.onlyTargets.contains(recoveryTargetName)
        var runCrashRecovery = options.includeRecovery || requestedRecoveryTarget

        if !options.onlyTargets.isEmpty {
            let availableTargetNames = Set(targets.map(\.name))
                .union(runCrashRecovery ? [recoveryTargetName] : [])
            let missingTargets = options.onlyTargets.subtracting(availableTargetNames)
            guard missingTargets.isEmpty else {
                throw VerifierError.usage(
                    "unknown or disabled --only-target value(s): \(missingTargets.sorted().joined(separator: ", "))"
                )
            }
            targets = targets.filter { options.onlyTargets.contains($0.name) }
            runCrashRecovery = requestedRecoveryTarget
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()

        let runtime = try DynamicLibraryBrowserRuntime(path: options.mojoRuntimePath)
        try runtime.initialize()

        var captures: [CaptureResult] = []
        for target in targets {
            captures.append(try runCapture(target: target, runtime: runtime, app: app))
        }
        var crashRecovery: CrashRecoveryResult?
        if runCrashRecovery {
            let result = try runCrashRecoveryGate(
                fixtureURL: crashRecoveryFixture.absoluteString,
                runtime: runtime,
                app: app
            )
            captures.append(result.afterCapture)
            crashRecovery = result.metadata
        }

        let summary = Summary(
            chromiumHost: options.chromiumHost,
            mojoRuntimePath: options.mojoRuntimePath,
            outputDirectory: options.outputDirectory.path,
            displayPath: "Mojo-published CAContext id hosted by Swift CALayerHost",
            contextSource: ProcessInfo.processInfo.environment["OWL_FRESH_LAYER_FIXTURE"] == nil
                ? "chromium-compositor-ca-context"
                : "chromium-layer-fixture-ca-context",
            controlTransport: "mojo",
            swiftHostTransport: OwlFreshGeneratedMojoTransport.name,
            mojoRuntime: runtime.runtimeDescription,
            mojoBindingSourceChecksum: OwlFreshMojoSchema.sourceChecksum,
            mojoBindingDeclarationCount: OwlFreshMojoSchema.declarations.count,
            devToolsFrontendHTTPAllowed: options.includeDevTools,
            devToolsActivePortFound: captures.contains(where: \.profileHadDevToolsActivePort),
            remoteDebuggingArgumentFound: captures.contains { containsRemoteDebuggingArgument($0.hostCommand) },
            crashRecovery: crashRecovery,
            captures: captures
        )

        guard options.includeDevTools || !summary.devToolsActivePortFound else {
            throw VerifierError.forbiddenPath("DevToolsActivePort was created during layer host verification")
        }
        guard !summary.remoteDebuggingArgumentFound else {
            throw VerifierError.forbiddenPath("host process used a remote debugging argument")
        }

        let summaryURL = options.outputDirectory.appendingPathComponent("summary.json")
        try JSONEncoder.pretty.encode(summary).write(to: summaryURL)
        let transportReportURL = options.outputDirectory.appendingPathComponent(
            "generated-transport-report.html"
        )
        try renderGeneratedTransportReport(summary: summary).write(
            to: transportReportURL,
            atomically: true,
            encoding: .utf8
        )

        print("OWL LayerHost verification passed")
        print("Artifacts: \(options.outputDirectory.path)")
        print("Control transport: \(summary.controlTransport)")
        print("Display path: \(summary.displayPath)")
        print("Context source: \(summary.contextSource)")
        print("DevTools frontend HTTP allowed: \(summary.devToolsFrontendHTTPAllowed)")
        print("DevToolsActivePort found: \(summary.devToolsActivePortFound)")
        print("Remote debugging args found: \(summary.remoteDebuggingArgumentFound)")
        for capture in captures {
            print("- \(capture.name): \(capture.screenshotPath) contextID=\(capture.contextID) windowID=\(capture.swiftWindowID) size=\(capture.stats.width)x\(capture.stats.height)")
        }
    }

    private func writeFixture(name: String, html: String, directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(name).html")
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func runCapture(
        target: RenderTarget,
        runtime: any OwlBrowserRuntime,
        app: NSApplication
    ) throws -> CaptureResult {
        let profileDirectory = options.outputDirectory
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("\(target.name)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: profileDirectory, withIntermediateDirectories: true)

        let useLayerFixture = ProcessInfo.processInfo.environment["OWL_FRESH_LAYER_FIXTURE"] != nil
        let initialURL = useLayerFixture ? target.url : "about:blank"
        let sessionEvents = OwlBrowserSessionEvents()
        let session = try runtime.createSession(
            chromiumHost: options.chromiumHost,
            initialURL: initialURL,
            userDataDirectory: profileDirectory.path,
            events: sessionEvents
        )
        var hostPID: Int32 = -1
        defer {
            runtime.destroy(session)
            terminateHostProcessIfNeeded(pid: hostPID)
            pumpApp(app, for: 0.2)
        }
        let hostController = try OwlBrowserSessionController(
            pipe: runtime,
            session: session
        )

        try hostController.resize(
            OwlFreshWebViewResizeRequest(
                width: UInt32(contentSize.width),
                height: UInt32(contentSize.height),
                scale: 1.0
            )
        )
        try hostController.setFocus(true)

        hostPID = runtime.hostPID(session)
        guard hostPID > 0 else {
            throw VerifierError.launch("Mojo runtime did not report a valid host PID for \(target.name)")
        }

        try waitForReady(name: target.name, events: sessionEvents, runtime: runtime, app: app)
        let baseline = sessionEvents.snapshot()
        var contextID: UInt32
        if useLayerFixture, baseline.contextID != 0 {
            contextID = baseline.contextID
        } else {
            try hostController.navigate(target.url)
            try waitForInitialReadinessIfPresent(
                target: target,
                runtime: runtime,
                session: session,
                events: sessionEvents,
                app: app
            )
            try waitForHostFlush(runtime: runtime, session: session, app: app)
            contextID = try waitForInitialWebViewContextID(
                name: target.name,
                events: sessionEvents,
                runtime: runtime,
                hostController: hostController,
                app: app
            )
        }
        let window = try LayerHostWindow(
            title: "OWL LayerHost \(target.name)",
            contextID: contextID,
            size: contentSize
        )
        window.onDevToolsCloseRequested = {
            guard try hostController.closeDevTools() else {
                throw VerifierError.input("host did not close DevTools from close button")
            }
        }
        defer {
            window.close()
            pumpApp(app, for: 0.2)
        }

        app.activate(ignoringOtherApps: true)
        window.show()
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        pumpApp(app, for: 0.2)

        let screenshotURL = options.outputDirectory.appendingPathComponent(target.screenshotName)
        let preInputScreenshotURL = target.preInputScreenshotName.map {
            options.outputDirectory.appendingPathComponent($0)
        }
        let deadline = Date().addingTimeInterval(options.timeout)
        var lastError = "no capture attempted"
        var lastWindowID: UInt32?
        var lastStats: PixelStats?
        var inputSent = target.inputActions.isEmpty
        var currentExpected = target.preInputExpected ?? target.expected
        var currentSize = contentSize
        var capturedPreInputPath: String?
        var postInputStateVerified = false
        var postInputDiagnosticsWritten = false
        var abortCurrentVerifierError = false

        while Date() < deadline {
            runtime.pollEvents(milliseconds: 50)
            pumpApp(app, for: 0.05)
            window.flushHostedLayer()

            let snapshot = sessionEvents.snapshot()
            if useLayerFixture, snapshot.contextID != 0, snapshot.contextID != contextID {
                contextID = snapshot.contextID
                window.update(contextID: contextID)
                pumpApp(app, for: 0.05)
            }
            if let surfaceTree = snapshot.surfaceTree {
                window.update(surfaceTree: surfaceTree)
            }

            if !target.inputActions.isEmpty, inputSent, !postInputStateVerified {
                do {
                    try verifyPostInputStateIfNeeded(target: target, runtime: runtime, session: session)
                    postInputStateVerified = true
                    if options.inputDiagnosticCapture, !postInputDiagnosticsWritten {
                        writePostInputDiagnostics(target: target, runtime: runtime, session: session)
                        postInputDiagnosticsWritten = true
                    }
                    try hostController.setFocus(true)
                    runtime.pollEvents(milliseconds: 10)
                } catch let error as VerifierError {
                    lastError = error.description
                    continue
                } catch {
                    lastError = String(describing: error)
                    continue
                }
            }

            if inputSent {
                app.activate(ignoringOtherApps: true)
                window.show()
                pumpApp(app, for: 0.02)
            }

            guard let windowID = swiftHostWindowID(title: window.title, minimumSize: currentSize) else {
                lastError = "Swift LayerHost window was not visible in CGWindowList"
                continue
            }
            lastWindowID = windowID

            do {
                let captureURL = inputSent ? screenshotURL : (preInputScreenshotURL ?? screenshotURL)
                let capture = try captureWindow(windowID: windowID, to: captureURL)
                let stats = analyze(image: capture.image)
                lastStats = stats
                if currentExpected.isSatisfied(by: stats) {
                    if !inputSent {
                        capturedPreInputPath = captureURL.path
                        try hostController.setFocus(true)
                        abortCurrentVerifierError = true
                        try performInputActions(
                            target.inputActions,
                            target: target,
                            runtime: runtime,
                            hostController: hostController,
                            session: session,
                            events: sessionEvents,
                            window: window,
                            app: app,
                            currentSize: &currentSize
                        )
                        pumpApp(app, for: 0.05)
                        if options.inputDiagnosticCapture {
                            writePostInputDOMState(target: target, runtime: runtime, session: session)
                        }
                        if target.completeAfterInputActions {
                            let data = try Data(contentsOf: screenshotURL)
                            guard let image = loadImage(from: data) else {
                                throw VerifierError.capture("could not load completed action screenshot \(screenshotURL.path)")
                            }
                            let stats = analyze(image: image)
                            guard target.expected.isSatisfied(by: stats) else {
                                throw VerifierError.pixelCheck(
                                    "\(target.name) completed action screenshot did not match \(target.expected): \(stats)"
                                )
                            }
                            let hostCommand = processCommandLine(pid: hostPID)
                            try rejectForbiddenRuntimePaths(
                                processCommand: hostCommand,
                                profileDirectory: profileDirectory,
                                name: target.name
                            )
                            let traceURL = options.outputDirectory.appendingPathComponent(
                                "\(target.name)-generated-transport-trace.json"
                            )
                            try JSONEncoder.pretty.encode(hostController.recordedCalls).write(to: traceURL)
                            let finalEventSnapshot = sessionEvents.snapshot()
                            let finalSurfaceTree = (try? hostController.getSurfaceTree())
                                ?? finalEventSnapshot.surfaceTree
                            return CaptureResult(
                                name: target.name,
                                url: target.url,
                                hostPID: hostPID,
                                hostCommand: hostCommand,
                                contextID: contextID,
                                swiftWindowID: windowID,
                                screenshotPath: screenshotURL.path,
                                preInputScreenshotPath: capturedPreInputPath,
                                stats: stats,
                                profileHadDevToolsActivePort: hasDevToolsActivePort(profileDirectory: profileDirectory),
                                sessionEvents: finalEventSnapshot,
                                surfaceTree: finalSurfaceTree,
                                generatedTransportTracePath: traceURL.path,
                                generatedTransportCallCount: hostController.recordedCalls.count
                            )
                        }
                        abortCurrentVerifierError = false
                        inputSent = true
                        currentExpected = target.expected
                        lastError = "input actions sent through Mojo; waiting for post-input pixels"
                        continue
                    }
                    if !target.inputActions.isEmpty,
                       inputSent,
                       options.inputDiagnosticCapture,
                       !postInputDiagnosticsWritten {
                        writePostInputDiagnostics(target: target, runtime: runtime, session: session)
                        postInputDiagnosticsWritten = true
                    }
                    let hostCommand = processCommandLine(pid: hostPID)
                    try rejectForbiddenRuntimePaths(
                        processCommand: hostCommand,
                        profileDirectory: profileDirectory,
                        name: target.name
                    )
                    let traceURL = options.outputDirectory.appendingPathComponent(
                        "\(target.name)-generated-transport-trace.json"
                    )
                    try JSONEncoder.pretty.encode(hostController.recordedCalls).write(to: traceURL)
                    let finalEventSnapshot = sessionEvents.snapshot()
                    let finalSurfaceTree = (try? hostController.getSurfaceTree())
                        ?? finalEventSnapshot.surfaceTree
                    return CaptureResult(
                        name: target.name,
                        url: target.url,
                        hostPID: hostPID,
                        hostCommand: hostCommand,
                        contextID: contextID,
                        swiftWindowID: windowID,
                        screenshotPath: screenshotURL.path,
                        preInputScreenshotPath: capturedPreInputPath,
                        stats: stats,
                        profileHadDevToolsActivePort: hasDevToolsActivePort(profileDirectory: profileDirectory),
                        sessionEvents: finalEventSnapshot,
                        surfaceTree: finalSurfaceTree,
                        generatedTransportTracePath: traceURL.path,
                        generatedTransportCallCount: hostController.recordedCalls.count
                    )
                }
                lastError = "pixel stats did not match expected set \(currentExpected): \(stats)"
            } catch let error as VerifierError {
                if abortCurrentVerifierError {
                    throw error
                }
                if case .input(let message) = error,
                   message.hasPrefix("expected resize mode ") {
                    throw error
                }
                lastError = error.description
            } catch {
                if abortCurrentVerifierError {
                    throw error
                }
                lastError = String(describing: error)
            }
        }

        let failure = CaptureFailureSnapshot(
            name: target.name,
            contextID: contextID,
            lastWindowID: lastWindowID,
            lastError: lastError,
            lastStats: lastStats,
            sessionEvents: sessionEvents.snapshot()
        )
        try? JSONEncoder.pretty.encode(failure).write(
            to: options.outputDirectory.appendingPathComponent("\(target.name)-failure.json")
        )
        throw VerifierError.timeout("timed out waiting for \(target.name) through Swift LayerHost: \(lastError); lastWindowID=\(lastWindowID.map(String.init) ?? "none"); events=\(sessionEvents.snapshot())")
    }

    private func runCrashRecoveryGate(
        fixtureURL: String,
        runtime: any OwlBrowserRuntime,
        app: NSApplication
    ) throws -> CrashRecoveryRun {
        let profileDirectory = options.outputDirectory
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("crash-recovery-before-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: profileDirectory, withIntermediateDirectories: true)

        let sessionEvents = OwlBrowserSessionEvents()
        let initialURL = ProcessInfo.processInfo.environment["OWL_FRESH_LAYER_FIXTURE"] == nil
            ? "about:blank"
            : fixtureURL
        let session = try runtime.createSession(
            chromiumHost: options.chromiumHost,
            initialURL: initialURL,
            userDataDirectory: profileDirectory.path,
            events: sessionEvents
        )
        var hostPID: Int32 = -1
        var sessionDestroyed = false
        defer {
            if !sessionDestroyed {
                runtime.destroy(session)
            }
            terminateHostProcessIfNeeded(pid: hostPID)
            pumpApp(app, for: 0.2)
        }

        let hostController = try OwlBrowserSessionController(
            pipe: runtime,
            session: session
        )
        try hostController.resize(
            OwlFreshWebViewResizeRequest(
                width: UInt32(contentSize.width),
                height: UInt32(contentSize.height),
                scale: 1.0
            )
        )
        try hostController.setFocus(true)

        hostPID = runtime.hostPID(session)
        guard hostPID > 0 else {
            throw VerifierError.launch("Mojo runtime did not report a valid host PID for crash recovery")
        }

        try waitForReady(name: "crash-recovery-before", events: sessionEvents, runtime: runtime, app: app)
        if ProcessInfo.processInfo.environment["OWL_FRESH_LAYER_FIXTURE"] == nil {
            try hostController.navigate(fixtureURL)
        }
        try waitForHostFlush(runtime: runtime, session: session, app: app)
        let contextID = try waitForInitialWebViewContextID(
            name: "crash-recovery-before",
            events: sessionEvents,
            runtime: runtime,
            hostController: hostController,
            app: app
        )
        let window = try LayerHostWindow(
            title: "OWL LayerHost crash-recovery-before",
            contextID: contextID,
            size: contentSize
        )
        defer {
            window.close()
            pumpApp(app, for: 0.2)
        }

        app.activate(ignoringOtherApps: true)
        window.show()
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        pumpApp(app, for: 0.2)

        let before = try captureStableHostedWindow(
            name: "crash-recovery-before-crash.png",
            expected: [.red, .green, .blue, .dark],
            runtime: runtime,
            session: session,
            events: sessionEvents,
            hostController: hostController,
            window: window,
            size: contentSize,
            app: app
        )
        let hostCommand = processCommandLine(pid: hostPID)
        try rejectForbiddenRuntimePaths(
            processCommand: hostCommand,
            profileDirectory: profileDirectory,
            name: "crash-recovery-before"
        )

        guard kill(hostPID, SIGKILL) == 0 else {
            throw VerifierError.launch("could not kill crash-recovery host pid \(hostPID)")
        }
        let disconnectedEventSeen = try waitForDisconnectEvent(
            name: "crash-recovery-before",
            pid: hostPID,
            events: sessionEvents,
            runtime: runtime,
            app: app
        )
        runtime.destroy(session)
        sessionDestroyed = true

        let afterTarget = RenderTarget(
            name: "crash-recovery-fixture",
            url: fixtureURL,
            screenshotName: "crash-recovery-after-restart.png",
            expected: [.red, .green, .blue, .dark],
            preInputScreenshotName: nil,
            preInputExpected: nil,
            inputActions: [],
            postInputDiagnosticScript: nil,
            postInputExpectations: []
        )
        let afterCapture = try runCapture(target: afterTarget, runtime: runtime, app: app)
        let metadata = CrashRecoveryResult(
            crashedHostPID: hostPID,
            disconnectedEventSeen: disconnectedEventSeen,
            beforeCrashScreenshotPath: before.path,
            beforeCrashContextID: before.contextID,
            afterRecoveryCaptureName: afterCapture.name,
            afterRecoveryScreenshotPath: afterCapture.screenshotPath
        )
        try JSONEncoder.pretty.encode(metadata).write(
            to: options.outputDirectory.appendingPathComponent("crash-recovery.json")
        )
        return CrashRecoveryRun(metadata: metadata, afterCapture: afterCapture)
    }

    private func captureStableHostedWindow(
        name: String,
        expected: Set<ExpectedPixel>,
        runtime: any OwlBrowserRuntime,
        session: OpaquePointer,
        events: OwlBrowserSessionEvents,
        hostController: OwlBrowserSessionController,
        window: LayerHostWindow,
        size: CGSize,
        app: NSApplication
    ) throws -> (path: String, contextID: UInt32, stats: PixelStats) {
        let captureURL = options.outputDirectory.appendingPathComponent(name)
        let deadline = Date().addingTimeInterval(min(10, options.timeout))
        var lastStats: PixelStats?
        var lastError = "no capture attempted"
        var contextID = events.snapshot().contextID
        while Date() < deadline {
            runtime.pollEvents(milliseconds: 50)
            pumpApp(app, for: 0.05)
            do {
                let tree = try hostController.getSurfaceTree()
                if let surface = tree.surfaces.first(where: { $0.visible && $0.kind == .webView && $0.contextId != 0 }) ??
                    tree.surfaces.first(where: { $0.visible && $0.contextId != 0 }) {
                    contextID = surface.contextId
                }
                window.update(surfaceTree: tree)
                window.flushHostedLayer()
            } catch {
                lastError = String(describing: error)
            }
            guard let windowID = swiftHostWindowID(title: window.title, minimumSize: size) else {
                lastError = "Swift LayerHost window was not visible in CGWindowList"
                continue
            }
            do {
                let capture = try captureWindow(windowID: windowID, to: captureURL)
                let stats = analyze(image: capture.image)
                lastStats = stats
                if expected.isSatisfied(by: stats) {
                    return (captureURL.path, contextID, stats)
                }
                lastError = "pixel stats did not match expected set \(expected): \(stats)"
            } catch {
                lastError = String(describing: error)
            }
        }
        throw VerifierError.timeout(
            "timed out waiting for \(name): \(lastError); lastStats=\(String(describing: lastStats)); events=\(events.snapshot())"
        )
    }

    private func waitForDisconnectEvent(
        name: String,
        pid: Int32,
        events: OwlBrowserSessionEvents,
        runtime: any OwlBrowserRuntime,
        app: NSApplication
    ) throws -> Bool {
        let deadline = Date().addingTimeInterval(10)
        var lastSnapshot = events.snapshot()
        while Date() < deadline {
            runtime.pollEvents(milliseconds: 50)
            pumpApp(app, for: 0.02)
            lastSnapshot = events.snapshot()
            if lastSnapshot.disconnected {
                return true
            }
        }
        throw VerifierError.launch(
            "\(name) host pid \(pid) was killed, but Mojo disconnect was not observed; last events=\(lastSnapshot)"
        )
    }

    private func waitForContextID(
        name: String,
        events: OwlBrowserSessionEvents,
        runtime: any OwlBrowserRuntime,
        app: NSApplication,
        afterGeneration: UInt64,
        rejectingContextID: UInt32?
    ) throws -> UInt32 {
        let deadline = Date().addingTimeInterval(min(15, options.timeout))
        while Date() < deadline {
            runtime.pollEvents(milliseconds: 50)
            pumpApp(app, for: 0.01)
            let snapshot = events.snapshot()
            if snapshot.ready,
               snapshot.contextID != 0,
               snapshot.contextGeneration > afterGeneration,
               snapshot.contextID != rejectingContextID {
                return snapshot.contextID
            }
            if snapshot.disconnected {
                throw VerifierError.launch("\(name) disconnected before Mojo published a CAContext id")
            }
        }
        throw VerifierError.timeout("timed out waiting for \(name) Mojo context id: \(events.snapshot())")
    }

    private func waitForInitialReadinessIfPresent(
        target: RenderTarget,
        runtime: any OwlBrowserRuntime,
        session: OpaquePointer,
        events: OwlBrowserSessionEvents,
        app: NSApplication
    ) throws {
        guard case .waitForJavaScript(let label, let script, let expectations) = target.inputActions.first else {
            return
        }
        try waitForJavaScriptExpectations(
            label: "initial \(label)",
            script: script,
            expectations: expectations,
            runtime: runtime,
            session: session,
            events: events,
            app: app
        )
    }

    private func waitForInitialWebViewContextID(
        name: String,
        events: OwlBrowserSessionEvents,
        runtime: any OwlBrowserRuntime,
        hostController: OwlBrowserSessionController,
        app: NSApplication
    ) throws -> UInt32 {
        let deadline = Date().addingTimeInterval(min(10, options.timeout))
        var lastTree: OwlFreshSurfaceTree?
        var lastError = ""
        while Date() < deadline {
            runtime.pollEvents(milliseconds: 50)
            pumpApp(app, for: 0.02)
            do {
                let tree = try hostController.getSurfaceTree()
                lastTree = tree
                if let surface = tree.surfaces.first(where: {
                    $0.visible && $0.kind == .webView && $0.contextId != 0
                }) {
                    return surface.contextId
                }
            } catch {
                lastError = String(describing: error)
            }
        }
        throw VerifierError.timeout(
            "timed out waiting for \(name) initial web-view surface; lastTree=\(String(describing: lastTree)); lastError=\(lastError); events=\(events.snapshot())"
        )
    }

    private func waitForReady(
        name: String,
        events: OwlBrowserSessionEvents,
        runtime: any OwlBrowserRuntime,
        app: NSApplication
    ) throws {
        let deadline = Date().addingTimeInterval(min(10, options.timeout))
        while Date() < deadline {
            runtime.pollEvents(milliseconds: 50)
            pumpApp(app, for: 0.01)
            let snapshot = events.snapshot()
            if snapshot.ready {
                return
            }
            if snapshot.disconnected {
                throw VerifierError.launch("\(name) disconnected before Mojo ready")
            }
        }
        throw VerifierError.timeout("timed out waiting for \(name) Mojo ready event: \(events.snapshot())")
    }

    private func rejectForbiddenRuntimePaths(
        processCommand: String,
        profileDirectory: URL,
        name: String
    ) throws {
        if containsRemoteDebuggingArgument(processCommand) {
            throw VerifierError.forbiddenPath("\(name) host command contains remote debugging: \(processCommand)")
        }
        if !options.includeDevTools && hasDevToolsActivePort(profileDirectory: profileDirectory) {
            throw VerifierError.forbiddenPath("\(name) profile created DevToolsActivePort")
        }
    }

    private func performInputActions(
        _ actions: [InputAction],
        target: RenderTarget,
        runtime: any OwlBrowserRuntime,
        hostController: OwlBrowserSessionController,
        session: OpaquePointer,
        events: OwlBrowserSessionEvents,
        window: LayerHostWindow,
        app: NSApplication,
        currentSize: inout CGSize
    ) throws {
        for action in actions {
            switch action {
            case .mouseClick(let click):
                if ProcessInfo.processInfo.environment["OWL_LAYER_HOST_KEY_ONLY"] == "1" {
                    continue
                }
                try hostController.sendMouse(OwlFreshMouseEvent(
                    kind: .move,
                    x: click.x,
                    y: click.y,
                    button: 0,
                    clickCount: 0,
                    deltaX: 0,
                    deltaY: 0,
                    modifiers: 0
                ))
                runtime.pollEvents(milliseconds: 10)
                try hostController.sendMouse(OwlFreshMouseEvent(
                    kind: .down,
                    x: click.x,
                    y: click.y,
                    button: click.button,
                    clickCount: click.clickCount,
                    deltaX: 0,
                    deltaY: 0,
                    modifiers: 0
                ))
                runtime.pollEvents(milliseconds: 10)
                try hostController.sendMouse(OwlFreshMouseEvent(
                    kind: .up,
                    x: click.x,
                    y: click.y,
                    button: click.button,
                    clickCount: click.clickCount,
                    deltaX: 0,
                    deltaY: 0,
                    modifiers: 0
                ))
                runtime.pollEvents(milliseconds: 10)
            case .mouseWheel(let wheel):
                try hostController.sendMouse(wheel)
                runtime.pollEvents(milliseconds: 20)
                try waitForHostFlush(runtime: runtime, session: session, app: app)
            case .key(let stroke):
                try sendKeyStroke(stroke, runtime: runtime, hostController: hostController)
            case .resize(let resize, let expectedMode):
                try hostController.resize(resize)
                currentSize = CGSize(
                    width: CGFloat(Int(resize.width)),
                    height: CGFloat(Int(resize.height))
                )
                window.resize(to: currentSize)
                pumpApp(app, for: 0.2)
                runtime.pollEvents(milliseconds: 50)
                window.flushHostedLayer()
                try waitForHostFlush(runtime: runtime, session: session, app: app)
                try waitForResizeMode(
                    expectedMode,
                    runtime: runtime,
                    session: session,
                    events: events,
                    app: app
                )
            case .text(let text):
                for character in text {
                    guard let stroke = OwlFreshKeyEvent.typing(character) else {
                        throw VerifierError.input("unsupported typed character for \(character)")
                    }
                    try sendKeyStroke(stroke, runtime: runtime, hostController: hostController)
                }
            case .waitForJavaScript(let label, let script, let expectations):
                try waitForJavaScriptExpectations(
                    label: label,
                    script: script,
                    expectations: expectations,
                    runtime: runtime,
                    session: session,
                    events: events,
                    app: app
                )
            case .waitForDevToolsJavaScript(let label, let script, let expectations):
                try waitForDevToolsJavaScriptExpectations(
                    label: label,
                    script: script,
                    expectations: expectations,
                    hostController: hostController,
                    events: events,
                    app: app
                )
            case .waitForSurfaceTree(let label, let expectations):
                let tree = try waitForSurfaceTreeExpectations(
                    label: label,
                    expectations: expectations,
                    runtime: runtime,
                    hostController: hostController,
                    session: session,
                    events: events,
                    window: window,
                    app: app
                )
                window.update(surfaceTree: tree)
            case .waitForNoSurface(let label, let kind, let surfaceLabel):
                let tree = try waitForNoSurface(
                    label: label,
                    kind: kind,
                    surfaceLabel: surfaceLabel,
                    runtime: runtime,
                    hostController: hostController,
                    events: events,
                    window: window,
                    app: app
                )
                window.update(surfaceTree: tree)
            case .openDevTools(let mode):
                guard try hostController.openDevTools(mode) else {
                    throw VerifierError.input("host did not open DevTools in mode \(mode)")
                }
                runtime.pollEvents(milliseconds: 50)
                try waitForHostFlush(runtime: runtime, session: session, app: app)
                window.update(surfaceTree: try hostController.getSurfaceTree())
                window.flushHostedLayer()
            case .closeDevTools:
                guard try hostController.closeDevTools() else {
                    throw VerifierError.input("host did not close DevTools")
                }
                runtime.pollEvents(milliseconds: 50)
                try waitForHostFlush(runtime: runtime, session: session, app: app)
                window.update(surfaceTree: try hostController.getSurfaceTree())
                window.flushHostedLayer()
            case .clickDevToolsCloseButton:
                try window.performDevToolsCloseButtonClick()
                runtime.pollEvents(milliseconds: 50)
                try waitForHostFlush(runtime: runtime, session: session, app: app)
                window.update(surfaceTree: try hostController.getSurfaceTree())
                window.flushHostedLayer()
            case .evaluateDevToolsJavaScript(let label, let script, let expectations):
                let result = try hostController.evaluateDevToolsJavaScript(script)
                try verifyJavaScriptExpectations(
                    result: result,
                    expectations: expectations,
                    targetName: label
                )
                runtime.pollEvents(milliseconds: 50)
                window.update(surfaceTree: try hostController.getSurfaceTree())
                window.flushHostedLayer()
            case .captureDetachedSurface(let label, let name, let expected):
                let tree = try hostController.getSurfaceTree()
                window.update(surfaceTree: tree)
                window.flushHostedLayer()
                guard let surface = tree.surfaces.first(where: {
                    $0.visible && $0.kind == .devTools && $0.label == label && $0.contextId != 0
                }) else {
                    throw VerifierError.input("\(target.name) missing detached DevTools surface \(label): \(tree)")
                }
                guard surface.width > 0, surface.height > 0 else {
                    throw VerifierError.input("\(target.name) detached DevTools surface has empty bounds: \(surface)")
                }
                let captureURL = options.outputDirectory.appendingPathComponent(name)
                let capture = try window.captureDetachedSurface(
                    label: label,
                    minimumSize: CGSize(width: CGFloat(surface.width), height: CGFloat(surface.height)),
                    to: captureURL
                )
                let stats = analyze(image: capture.image)
                guard expected.isSatisfied(by: stats) else {
                    throw VerifierError.pixelCheck("\(target.name) \(name) detached surface pixels did not match \(expected): \(stats)")
                }
            case .captureWindow(let name, let expected):
                window.update(surfaceTree: try hostController.getSurfaceTree())
                window.flushHostedLayer()
                pumpApp(app, for: 0.05)
                guard let windowID = swiftHostWindowID(title: window.title, minimumSize: currentSize) else {
                    throw VerifierError.capture("Swift LayerHost window was not visible for \(name)")
                }
                let captureURL = options.outputDirectory.appendingPathComponent(name)
                let capture = try captureWindow(windowID: windowID, to: captureURL)
                let stats = analyze(image: capture.image)
                guard expected.isSatisfied(by: stats) else {
                    throw VerifierError.pixelCheck("\(target.name) \(name) pixels did not match \(expected): \(stats)")
                }
            case .detachReattachHost(let name, let expected):
                let tree = try hostController.getSurfaceTree()
                window.update(surfaceTree: tree)
                try window.detachAndReattachPrimaryHost(surfaceTree: tree)
                pumpApp(app, for: 0.1)
                guard let windowID = swiftHostWindowID(title: window.title, minimumSize: currentSize) else {
                    throw VerifierError.capture("Swift LayerHost window was not visible for \(name)")
                }
                let captureURL = options.outputDirectory.appendingPathComponent(name)
                let capture = try captureWindow(windowID: windowID, to: captureURL)
                let stats = analyze(image: capture.image)
                guard expected.isSatisfied(by: stats) else {
                    throw VerifierError.pixelCheck("\(target.name) \(name) pixels did not survive detach/reattach \(expected): \(stats)")
                }
            case .hideShowHostWindow(let name, let expected):
                window.hide()
                pumpApp(app, for: 0.1)
                window.show()
                window.update(surfaceTree: try hostController.getSurfaceTree())
                window.flushHostedLayer()
                pumpApp(app, for: 0.1)
                guard let windowID = swiftHostWindowID(title: window.title, minimumSize: currentSize) else {
                    throw VerifierError.capture("Swift LayerHost window was not visible for \(name)")
                }
                let captureURL = options.outputDirectory.appendingPathComponent(name)
                let capture = try captureWindow(windowID: windowID, to: captureURL)
                let stats = analyze(image: capture.image)
                guard expected.isSatisfied(by: stats) else {
                    throw VerifierError.pixelCheck("\(target.name) \(name) pixels did not survive hide/show \(expected): \(stats)")
                }
            case .verifySurfaceScale(let name, let minimumScale):
                let tree = try hostController.getSurfaceTree()
                window.update(surfaceTree: tree)
                let snapshot = try window.surfaceScaleSnapshot(surfaceTree: tree)
                guard snapshot.surfaceScale >= minimumScale else {
                    throw VerifierError.pixelCheck(
                        "\(target.name) expected surface scale >= \(minimumScale), got \(snapshot.surfaceScale)"
                    )
                }
                guard abs(snapshot.hostedLayerContentsScale - Double(snapshot.surfaceScale)) < 0.01 else {
                    throw VerifierError.pixelCheck(
                        "\(target.name) hosted layer contentsScale \(snapshot.hostedLayerContentsScale) does not match surface scale \(snapshot.surfaceScale)"
                    )
                }
                try JSONEncoder.pretty.encode(snapshot).write(
                    to: options.outputDirectory.appendingPathComponent(name)
                )
            case .verifyWindowEdgeCoverage(let name):
                window.update(surfaceTree: try hostController.getSurfaceTree())
                window.flushHostedLayer()
                pumpApp(app, for: 0.05)
                guard let windowID = swiftHostWindowID(title: window.title, minimumSize: currentSize) else {
                    throw VerifierError.capture("Swift LayerHost window was not visible for \(name)")
                }
                let captureURL = options.outputDirectory.appendingPathComponent(name)
                let capture = try captureWindow(windowID: windowID, to: captureURL)
                try verifyResizeEdgeCoverage(
                    image: capture.image,
                    contentSize: currentSize,
                    targetName: target.name,
                    artifactName: name
                )
            case .captureNativeMenu(let label, let name, let expected, let response):
                let tree = try hostController.getSurfaceTree()
                window.update(surfaceTree: tree)
                window.flushHostedLayer()
                guard let surface = tree.surfaces.first(where: {
                    $0.visible && $0.kind == .nativeMenu && $0.label == label
                }) else {
                    throw VerifierError.input("\(target.name) missing native menu surface \(label): \(tree)")
                }
                try validateNativeMenuSurface(surface, targetName: target.name)
                try writeNativeSurface(surface, screenshotName: name, outputDirectory: options.outputDirectory)
                guard let windowID = swiftHostWindowID(title: window.title, minimumSize: currentSize) else {
                    throw VerifierError.capture("Swift LayerHost window was not visible for \(name)")
                }
                let captureURL = options.outputDirectory.appendingPathComponent(name)
                let capture = try window.presentNativeMenuAndCapture(
                    surface: surface,
                    windowID: windowID,
                    to: captureURL
                )
                let stats = analyze(image: capture.image)
                guard expected.isSatisfied(by: stats) else {
                    throw VerifierError.pixelCheck("\(target.name) \(name) native menu pixels did not match \(expected): \(stats)")
                }
                switch response {
                case .accept(let index):
                    guard try hostController.acceptActivePopupMenuItem(index) else {
                        throw VerifierError.input("host did not accept active popup menu item \(index)")
                    }
                case .cancel:
                    _ = try hostController.cancelActivePopup()
                }
                runtime.pollEvents(milliseconds: 50)
                let refreshedTree = try hostController.getSurfaceTree()
                window.update(surfaceTree: refreshedTree)
                window.flushHostedLayer()
                try waitForHostFlush(runtime: runtime, session: session, app: app)
            case .captureNativeFilePicker(let label, let name, let expected, let response):
                let tree = try hostController.getSurfaceTree()
                window.update(surfaceTree: tree)
                window.flushHostedLayer()
                guard let surface = tree.surfaces.first(where: {
                    $0.visible && $0.kind == .nativeFilePicker && $0.label == label
                }) else {
                    throw VerifierError.input("\(target.name) missing native file picker surface \(label): \(tree)")
                }
                try validateNativeFilePickerSurface(surface, targetName: target.name)
                try writeNativeSurface(surface, screenshotName: name, outputDirectory: options.outputDirectory)
                guard let windowID = swiftHostWindowID(title: window.title, minimumSize: currentSize) else {
                    throw VerifierError.capture("Swift LayerHost window was not visible for \(name)")
                }
                let captureURL = options.outputDirectory.appendingPathComponent(name)
                let capture = try window.presentNativeFilePickerAndCapture(
                    surface: surface,
                    windowID: windowID,
                    to: captureURL
                )
                let stats = analyze(image: capture.image)
                guard expected.isSatisfied(by: stats) else {
                    throw VerifierError.pixelCheck("\(target.name) \(name) native file picker pixels did not match \(expected): \(stats)")
                }
                let afterPanelCloseURL = options.outputDirectory.appendingPathComponent(
                    nativeSurfaceDiagnosticName(baseName: name, suffix: "after-panel-close-before-response")
                )
                _ = try captureWindow(windowID: windowID, to: afterPanelCloseURL)
                switch response {
                case .select(let paths):
                    guard try hostController.selectActiveFilePickerFiles(paths) else {
                        throw VerifierError.input("host did not accept active file picker paths \(paths)")
                    }
                case .cancel:
                    guard try hostController.cancelActiveFilePicker() else {
                        throw VerifierError.input("host did not cancel active file picker")
                    }
                }
                runtime.pollEvents(milliseconds: 50)
                window.update(surfaceTree: try hostController.getSurfaceTree())
                window.flushHostedLayer()
                try waitForHostFlush(runtime: runtime, session: session, app: app)
            case .acceptActivePopupMenuItem(let index):
                guard try hostController.acceptActivePopupMenuItem(index) else {
                    throw VerifierError.input("host did not accept active popup menu item \(index)")
                }
                runtime.pollEvents(milliseconds: 50)
                window.update(surfaceTree: try hostController.getSurfaceTree())
                window.flushHostedLayer()
                try waitForHostFlush(runtime: runtime, session: session, app: app)
            case .cancelActivePopup:
                _ = try hostController.cancelActivePopup()
                runtime.pollEvents(milliseconds: 50)
                window.update(surfaceTree: try hostController.getSurfaceTree())
                window.flushHostedLayer()
                try waitForHostFlush(runtime: runtime, session: session, app: app)
            }
        }
    }

    private func waitForJavaScriptExpectations(
        label: String,
        script: String,
        expectations: [JavaScriptExpectation],
        runtime: any OwlBrowserRuntime,
        session: OpaquePointer,
        events: OwlBrowserSessionEvents,
        app: NSApplication
    ) throws {
        let deadline = Date().addingTimeInterval(10)
        var lastResult = ""
        var lastError = ""
        while Date() < deadline {
            runtime.pollEvents(milliseconds: 50)
            pumpApp(app, for: 0.02)
            do {
                let result = try runtime.executeJavaScript(session, script: script)
                lastResult = result
                try verifyJavaScriptExpectations(
                    result: result,
                    expectations: expectations,
                    targetName: label
                )
                return
            } catch {
                lastError = String(describing: error)
            }
        }
        throw VerifierError.input(
            "timed out waiting for \(label); lastResult=\(lastResult); lastError=\(lastError); logs=\(events.snapshot().logs)"
        )
    }

    private func waitForDevToolsJavaScriptExpectations(
        label: String,
        script: String,
        expectations: [JavaScriptExpectation],
        hostController: OwlBrowserSessionController,
        events: OwlBrowserSessionEvents,
        app: NSApplication
    ) throws {
        let deadline = Date().addingTimeInterval(10)
        var lastResult = ""
        var lastError = ""
        while Date() < deadline {
            pumpApp(app, for: 0.02)
            do {
                let result = try hostController.evaluateDevToolsJavaScript(script)
                lastResult = result
                try verifyJavaScriptExpectations(
                    result: result,
                    expectations: expectations,
                    targetName: label
                )
                return
            } catch {
                lastError = String(describing: error)
            }
        }
        throw VerifierError.input(
            "timed out waiting for \(label); lastResult=\(lastResult); lastError=\(lastError); logs=\(events.snapshot().logs)"
        )
    }

    private func waitForSurfaceTreeExpectations(
        label: String,
        expectations: [SurfaceTreeExpectation],
        runtime: any OwlBrowserRuntime,
        hostController: OwlBrowserSessionController,
        session: OpaquePointer,
        events: OwlBrowserSessionEvents,
        window: LayerHostWindow,
        app: NSApplication
    ) throws -> OwlFreshSurfaceTree {
        let deadline = Date().addingTimeInterval(10)
        var lastTree: OwlFreshSurfaceTree?
        var lastError = ""
        while Date() < deadline {
            runtime.pollEvents(milliseconds: 50)
            pumpApp(app, for: 0.02)
            do {
                let tree = try hostController.getSurfaceTree()
                lastTree = tree
                window.update(surfaceTree: tree)
                if surfaceTree(tree, satisfies: expectations) {
                    return tree
                }
            } catch {
                lastError = String(describing: error)
            }
        }
        throw VerifierError.input(
            "timed out waiting for \(label); lastTree=\(String(describing: lastTree)); lastError=\(lastError); logs=\(events.snapshot().logs)"
        )
    }

    private func waitForNoSurface(
        label: String,
        kind: OwlFreshSurfaceKind,
        surfaceLabel: String,
        runtime: any OwlBrowserRuntime,
        hostController: OwlBrowserSessionController,
        events: OwlBrowserSessionEvents,
        window: LayerHostWindow,
        app: NSApplication
    ) throws -> OwlFreshSurfaceTree {
        let deadline = Date().addingTimeInterval(10)
        var lastTree: OwlFreshSurfaceTree?
        var lastError = ""
        while Date() < deadline {
            runtime.pollEvents(milliseconds: 50)
            pumpApp(app, for: 0.02)
            do {
                let tree = try hostController.getSurfaceTree()
                lastTree = tree
                window.update(surfaceTree: tree)
                let surfaceExists = tree.surfaces.contains { surface in
                    surface.visible && surface.kind == kind && surface.label == surfaceLabel
                }
                if !surfaceExists {
                    return tree
                }
            } catch {
                lastError = String(describing: error)
            }
        }
        throw VerifierError.input(
            "timed out waiting for \(label); lastTree=\(String(describing: lastTree)); lastError=\(lastError); logs=\(events.snapshot().logs)"
        )
    }

    private func surfaceTree(
        _ tree: OwlFreshSurfaceTree,
        satisfies expectations: [SurfaceTreeExpectation]
    ) -> Bool {
        expectations.allSatisfy { expectation in
            tree.surfaces.contains { surface in
                guard surface.visible, surface.kind == expectation.kind else {
                    return false
                }
                if let label = expectation.label, surface.label != label {
                    return false
                }
                if let x = expectation.x, surface.x != x {
                    return false
                }
                if let y = expectation.y, surface.y != y {
                    return false
                }
                if let width = expectation.width, surface.width != width {
                    return false
                }
                if let height = expectation.height, surface.height != height {
                    return false
                }
                if let menuItem = expectation.menuItem,
                   !surface.menuItems.contains(where: { $0.contains(menuItem) }) {
                    return false
                }
                if let mode = expectation.filePickerMode,
                   surface.filePickerMode != mode {
                    return false
                }
                if let acceptType = expectation.filePickerAcceptType,
                   !surface.filePickerAcceptTypes.contains(acceptType) {
                    return false
                }
                return true
            }
        }
    }

    private func waitForHostFlush(
        runtime: any OwlBrowserRuntime,
        session: OpaquePointer,
        app: NSApplication
    ) throws {
        let deadline = Date().addingTimeInterval(5)
        var lastError = "host flush was not requested"
        while Date() < deadline {
            runtime.pollEvents(milliseconds: 20)
            pumpApp(app, for: 0.02)
            do {
                guard try runtime.sessionFlush(session) else {
                    lastError = "OwlFreshSession.flush returned false"
                    continue
                }
                return
            } catch {
                lastError = String(describing: error)
            }
        }
        throw VerifierError.bridge("timed out waiting for host Mojo flush: \(lastError)")
    }

    private func waitForResizeMode(
        _ expectedMode: String,
        runtime: any OwlBrowserRuntime,
        session: OpaquePointer,
        events: OwlBrowserSessionEvents,
        app: NSApplication
    ) throws {
        let script = """
        ({
          height: window.innerHeight,
          mode: window.owlResizeState?.mode || "",
          sawSmall: window.owlResizeState?.sawSmall === true,
          status: document.getElementById("status")?.textContent || "",
          width: window.innerWidth
        })
        """
        let deadline = Date().addingTimeInterval(5)
        var lastMode = ""
        var lastResult = ""
        var lastError = ""
        while Date() < deadline {
            runtime.pollEvents(milliseconds: 50)
            pumpApp(app, for: 0.02)
            do {
                let result = try runtime.executeJavaScript(session, script: script)
                lastResult = result
                let mode = try result.jsonObjectStringValue(for: "mode")
                lastMode = mode
                if mode == expectedMode {
                    return
                }
            } catch {
                lastError = String(describing: error)
            }
        }
        throw VerifierError.input(
            "expected resize mode \(expectedMode), got \(lastMode); lastResult=\(lastResult); lastError=\(lastError); logs=\(events.snapshot().logs)"
        )
    }

    private func sendKeyStroke(
        _ stroke: OwlFreshKeyEvent,
        runtime: any OwlBrowserRuntime,
        hostController: OwlBrowserSessionController
    ) throws {
        try hostController.sendKey(stroke)
        runtime.pollEvents(milliseconds: 10)
        try hostController.sendKey(OwlFreshKeyEvent(
            keyDown: false,
            keyCode: stroke.keyCode,
            text: "",
            modifiers: stroke.modifiers
        ))
        runtime.pollEvents(milliseconds: 10)
    }

    private func verifyPostInputStateIfNeeded(
        target: RenderTarget,
        runtime: any OwlBrowserRuntime,
        session: OpaquePointer
    ) throws {
        guard !target.postInputExpectations.isEmpty else {
            return
        }
        guard let script = target.postInputDiagnosticScript else {
            throw VerifierError.input("\(target.name) has post-input expectations but no diagnostic script")
        }
        let result = try runtime.executeJavaScript(session, script: script)
        try verifyJavaScriptExpectations(
            result: result,
            expectations: target.postInputExpectations,
            targetName: target.name
        )
    }

    private func writePostInputDiagnostics(
        target: RenderTarget,
        runtime: any OwlBrowserRuntime,
        session: OpaquePointer
    ) {
        writePostInputDOMState(target: target, runtime: runtime, session: session)

        let diagnosticURL = options.outputDirectory.appendingPathComponent(
            "\(target.name)-mojo-after-input.png"
        )
        do {
            let diagnostic = try runtime.captureSurfacePNG(session, to: diagnosticURL)
            let infoURL = options.outputDirectory.appendingPathComponent(
                "\(target.name)-mojo-after-input.json"
            )
            let payload = [
                "path": diagnostic.path,
                "mode": diagnostic.mode,
                "width": String(diagnostic.width),
                "height": String(diagnostic.height),
            ]
            try JSONEncoder.pretty.encode(payload).write(to: infoURL)
        } catch {
            let errorURL = options.outputDirectory.appendingPathComponent(
                "\(target.name)-mojo-after-input-error.txt"
            )
            try? String(describing: error).write(to: errorURL, atomically: true, encoding: .utf8)
        }
    }

    private func writePostInputDOMState(
        target: RenderTarget,
        runtime: any OwlBrowserRuntime,
        session: OpaquePointer
    ) {
        if let script = target.postInputDiagnosticScript {
            let stateURL = options.outputDirectory.appendingPathComponent(
                "\(target.name)-mojo-dom-state.json"
            )
            do {
                let domState = try runtime.executeJavaScript(session, script: script)
                try domState.write(to: stateURL, atomically: true, encoding: .utf8)
            } catch {
                try? String(describing: error).write(
                    to: stateURL,
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
    }
}

private extension OwlFreshKeyEvent {
    static func typing(_ character: Character) -> OwlFreshKeyEvent? {
        let scalars = String(character).unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else {
            return nil
        }
        switch scalar.value {
        case 32:
            return OwlFreshKeyEvent(keyDown: true, keyCode: 32, text: " ", modifiers: 0)
        case 48...57, 65...90:
            return OwlFreshKeyEvent(keyDown: true, keyCode: scalar.value, text: String(character), modifiers: 0)
        case 97...122:
            return OwlFreshKeyEvent(keyDown: true, keyCode: scalar.value - 32, text: String(character), modifiers: 0)
        default:
            return OwlFreshKeyEvent(keyDown: true, keyCode: scalar.value, text: String(character), modifiers: 0)
        }
    }
}

private func verifyJavaScriptExpectations(
    result: String,
    expectations: [JavaScriptExpectation],
    targetName: String
) throws {
    guard let data = result.data(using: .utf8) else {
        throw VerifierError.input("\(targetName) post-input JavaScript returned non-UTF8 data")
    }
    let object: Any
    do {
        object = try JSONSerialization.jsonObject(with: data)
    } catch {
        throw VerifierError.input("\(targetName) post-input JavaScript returned invalid JSON: \(result)")
    }
    guard let dictionary = object as? [String: Any] else {
        throw VerifierError.input("\(targetName) post-input JavaScript did not return an object: \(result)")
    }

    for expectation in expectations {
        guard let actual = dictionary[expectation.key] else {
            throw VerifierError.input("\(targetName) missing post-input field \(expectation.key): \(result)")
        }
        switch expectation.value {
        case .string(let expected):
            guard let actualString = actual as? String, actualString == expected else {
                throw VerifierError.input("\(targetName) expected \(expectation.key)=\(expected), got \(actual)")
            }
        case .bool(let expected):
            guard let actualBool = actual as? Bool, actualBool == expected else {
                throw VerifierError.input("\(targetName) expected \(expectation.key)=\(expected), got \(actual)")
            }
        }
    }
}

private final class LayerHostWindow {
    private final class CloseButtonTarget: NSObject {
        var handler: (() -> Void)?

        @objc func performClose(_ sender: Any?) {
            handler?()
        }
    }

    let title: String
    var onDevToolsCloseRequested: (() throws -> Void)?
    private let window: NSWindow
    private let contentView: NSView
    private let rootLayer: CALayer
    private var hostLayer: CALayer
    private var primaryContextID: UInt32
    private var primaryContentsScale: CGFloat
    private var popupHostLayers: [UInt64: CALayer] = [:]
    private var popupContextIDs: [UInt64: UInt32] = [:]
    private var detachedSurfaceWindows: [UInt64: DetachedSurfaceHostWindow] = [:]
    private var devToolsCloseLayer: CALayer?
    private var devToolsCloseTextLayer: CATextLayer?
    private var devToolsCloseButton: NSButton?
    private var devToolsCloseError: Error?
    private let devToolsCloseButtonTarget = CloseButtonTarget()

    init(title: String, contextID: UInt32, size: CGSize) throws {
        self.title = title

        let frame = NSRect(origin: .zero, size: size)
        let contentView = NSView(frame: frame)
        contentView.wantsLayer = true
        let rootLayer = CALayer()
        rootLayer.isGeometryFlipped = true
        rootLayer.backgroundColor = NSColor.white.cgColor
        rootLayer.frame = CGRect(origin: .zero, size: size)
        contentView.layer = rootLayer
        self.contentView = contentView
        self.rootLayer = rootLayer

        let hostLayer = try makeCALayerHost(contextID: contextID)
        hostLayer.anchorPoint = CGPoint.zero
        hostLayer.bounds = rootLayer.bounds
        hostLayer.position = CGPoint.zero
        hostLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        hostLayer.zPosition = 0
        rootLayer.addSublayer(hostLayer)
        self.hostLayer = hostLayer
        self.primaryContextID = contextID
        self.primaryContentsScale = hostLayer.contentsScale

        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = contentView
        window.backgroundColor = .white
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.sharingType = .readOnly
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()

        devToolsCloseButtonTarget.handler = { [weak self] in
            guard let self else {
                return
            }
            do {
                try self.onDevToolsCloseRequested?()
            } catch {
                self.devToolsCloseError = error
            }
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.sharingType = .readOnly
    }

    func close() {
        for detachedWindow in detachedSurfaceWindows.values {
            detachedWindow.close()
        }
        detachedSurfaceWindows.removeAll()
        window.close()
    }

    func hide() {
        window.orderOut(nil)
    }

    func resize(to size: CGSize) {
        window.setContentSize(size)
        contentView.setFrameSize(size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.frame = CGRect(origin: .zero, size: size)
        rootLayer.bounds = CGRect(origin: .zero, size: size)
        hostLayer.bounds = rootLayer.bounds
        hostLayer.position = CGPoint.zero
        for layer in popupHostLayers.values {
            layer.setNeedsLayout()
        }
        for detachedWindow in detachedSurfaceWindows.values {
            detachedWindow.flushHostedLayer()
        }
        CATransaction.commit()
        flushHostedLayer()
    }

    func update(contextID: UInt32) {
        guard contextID != primaryContextID else {
            flushHostedLayer()
            return
        }
        primaryContextID = contextID
        hostLayer.setValue(NSNumber(value: contextID), forKey: "contextId")
        flushHostedLayer()
    }

    func performDevToolsCloseButtonClick() throws {
        guard let button = devToolsCloseButton, !button.isHidden else {
            throw VerifierError.input("DevTools close button is not visible")
        }
        devToolsCloseError = nil
        button.performClick(nil)
        if let devToolsCloseError {
            throw devToolsCloseError
        }
    }

    func update(surfaceTree: OwlFreshSurfaceTree) {
        let visibleSurfaces = surfaceTree.surfaces
            .filter(\.visible)
            .sorted { lhs, rhs in
                if lhs.zIndex != rhs.zIndex {
                    return lhs.zIndex < rhs.zIndex
                }
                return lhs.surfaceId < rhs.surfaceId
            }
        guard let primary = visibleSurfaces.first(where: { $0.kind == .webView && $0.contextId != 0 }) ??
            visibleSurfaces.first(where: { $0.contextId != 0 }) else {
            flushHostedLayer()
            return
        }

        let popupOrigin = CGPoint(x: CGFloat(primary.x), y: CGFloat(primary.y))
        let primaryFrame = frame(for: primary, origin: .zero)
        let primaryScale = contentsScale(for: primary)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostLayer.isHidden = false
        hostLayer.contentsScale = primaryScale
        if primary.contextId != primaryContextID {
            primaryContextID = primary.contextId
            hostLayer.setValue(NSNumber(value: primary.contextId), forKey: "contextId")
        }
        hostLayer.frame = primaryFrame
        hostLayer.bounds = CGRect(origin: .zero, size: primaryFrame.size)
        hostLayer.position = primaryFrame.origin
        hostLayer.zPosition = CGFloat(primary.zIndex)
        primaryContentsScale = primaryScale

        let detachedSurfaces = visibleSurfaces.filter { surface in
            surface.contextId != 0 && isDetachedSurface(surface)
        }
        let activeDetachedIDs = Set(detachedSurfaces.map(\.surfaceId))
        for staleID in detachedSurfaceWindows.keys where !activeDetachedIDs.contains(staleID) {
            detachedSurfaceWindows[staleID]?.close()
            detachedSurfaceWindows[staleID] = nil
        }

        let renderPopupSurfaces = visibleSurfaces.filter { surface in
            surface.contextId != 0 && surface.surfaceId != primary.surfaceId
                && !isDetachedSurface(surface)
        }
        let activePopupIDs = Set(renderPopupSurfaces.map(\.surfaceId))
        for staleID in popupHostLayers.keys where !activePopupIDs.contains(staleID) {
            popupHostLayers[staleID]?.removeFromSuperlayer()
            popupHostLayers[staleID] = nil
            popupContextIDs[staleID] = nil
        }
        for surface in renderPopupSurfaces {
            let layer: CALayer
            if let existing = popupHostLayers[surface.surfaceId] {
                layer = existing
                if popupContextIDs[surface.surfaceId] != surface.contextId {
                    popupContextIDs[surface.surfaceId] = surface.contextId
                    layer.setValue(NSNumber(value: surface.contextId), forKey: "contextId")
                }
            } else {
                do {
                    layer = try makeCALayerHost(contextID: surface.contextId)
                    layer.anchorPoint = CGPoint.zero
                    rootLayer.addSublayer(layer)
                    popupHostLayers[surface.surfaceId] = layer
                    popupContextIDs[surface.surfaceId] = surface.contextId
                } catch {
                    continue
                }
            }
            layer.contentsScale = contentsScale(for: surface)
            let layerOrigin = surface.kind == .devTools ? CGPoint.zero : popupOrigin
            layer.frame = frame(for: surface, origin: layerOrigin)
            layer.bounds = CGRect(origin: .zero, size: layer.frame.size)
            layer.position = layer.frame.origin
            layer.zPosition = CGFloat(surface.zIndex)
            layer.isHidden = false
        }
        if let dockedDevTools = renderPopupSurfaces.first(where: { $0.kind == .devTools }) {
            updateDevToolsCloseControl(surface: dockedDevTools)
        } else {
            devToolsCloseLayer?.removeFromSuperlayer()
            devToolsCloseLayer = nil
            devToolsCloseTextLayer = nil
            devToolsCloseButton?.removeFromSuperview()
            devToolsCloseButton = nil
        }
        for surface in detachedSurfaces {
            let detachedWindow: DetachedSurfaceHostWindow
            if let existing = detachedSurfaceWindows[surface.surfaceId] {
                detachedWindow = existing
            } else {
                do {
                    detachedWindow = try DetachedSurfaceHostWindow(surface: surface)
                    detachedSurfaceWindows[surface.surfaceId] = detachedWindow
                    detachedWindow.show()
                } catch {
                    continue
                }
            }
            detachedWindow.update(surface: surface)
            detachedWindow.show()
        }
        CATransaction.commit()

        flushHostedLayer()
    }

    func surfaceScaleSnapshot(surfaceTree: OwlFreshSurfaceTree) throws -> SurfaceScaleSnapshot {
        guard let primary = primarySurface(in: surfaceTree) else {
            throw VerifierError.layerHost("cannot verify surface scale without a visible web-view surface")
        }
        return SurfaceScaleSnapshot(
            surfaceID: primary.surfaceId,
            contextID: primary.contextId,
            surfaceScale: primary.scale,
            hostedLayerContentsScale: Double(primaryContentsScale),
            popupLayerCount: popupHostLayers.count
        )
    }

    func detachAndReattachPrimaryHost(surfaceTree: OwlFreshSurfaceTree) throws {
        guard let primary = primarySurface(in: surfaceTree) else {
            throw VerifierError.layerHost("cannot detach and reattach primary host without a visible web-view surface")
        }
        let replacement = try makeCALayerHost(contextID: primary.contextId)
        replacement.anchorPoint = CGPoint.zero
        replacement.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        replacement.contentsScale = contentsScale(for: primary)
        replacement.frame = CGRect(origin: .zero, size: rootLayer.bounds.size)
        replacement.bounds = rootLayer.bounds
        replacement.position = CGPoint.zero
        replacement.zPosition = CGFloat(primary.zIndex)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostLayer.removeFromSuperlayer()
        rootLayer.insertSublayer(replacement, at: 0)
        hostLayer = replacement
        primaryContextID = primary.contextId
        primaryContentsScale = replacement.contentsScale
        CATransaction.commit()
        flushHostedLayer()
    }

    func presentNativeMenuAndCapture(
        surface: OwlFreshSurfaceInfo,
        windowID: UInt32,
        to url: URL
    ) throws -> CapturedWindow {
        guard !surface.menuItems.isEmpty else {
            throw VerifierError.input("native menu surface \(surface.label) has no menu items")
        }

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        let runner = NativeMenuRunner(surface: surface)

        guard runner.menu.numberOfItems > 0 else {
            throw VerifierError.input("native menu surface \(surface.label) produced an empty NSMenu")
        }

        let surfaceFrame = frame(for: surface, origin: .zero)
        let controlFrame = NSRect(
            x: max(0, min(contentView.bounds.width, surfaceFrame.minX)),
            y: max(0, min(contentView.bounds.height, contentView.bounds.height - surfaceFrame.maxY)),
            width: surfaceFrame.width,
            height: surfaceFrame.height
        )
        let box = NativeMenuCaptureBox()
        let captureTimer = Timer(timeInterval: 0.2, repeats: false) { _ in
            box.result = Result {
                try captureScreenRegion(
                    aroundWindowID: windowID,
                    nativeSurfaceFrame: surfaceFrame,
                    to: url
                )
            }
            runner.cancel()
        }
        RunLoop.current.add(captureTimer, forMode: .eventTracking)
        runner.run(in: contentView, bounds: controlFrame)

        if let result = box.result {
            return try result.get()
        }

        return try captureScreenRegion(
            aroundWindowID: windowID,
            nativeSurfaceFrame: surfaceFrame,
            to: url
        )
    }

    func captureDetachedSurface(
        label: String,
        minimumSize: CGSize,
        to url: URL
    ) throws -> CapturedWindow {
        guard let detachedWindow = detachedSurfaceWindows.values.first(where: { $0.label == label }) else {
            throw VerifierError.capture("detached surface window \(label) is not hosted")
        }
        detachedWindow.show()
        detachedWindow.flushHostedLayer()
        guard let windowID = swiftHostWindowID(title: detachedWindow.title, minimumSize: minimumSize) else {
            throw VerifierError.capture("detached surface window \(label) was not visible in CGWindowList")
        }
        return try captureWindow(windowID: windowID, to: url)
    }

    func presentNativeFilePickerAndCapture(
        surface: OwlFreshSurfaceInfo,
        windowID: UInt32,
        to url: URL
    ) throws -> CapturedWindow {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        let panel = NSOpenPanel()
        panel.title = "OWL File Picker"
        panel.message = "Choose a file for OWL verification"
        panel.prompt = "Choose"
        panel.canChooseFiles = !surface.filePickerUploadFolder
        panel.canChooseDirectories = surface.filePickerUploadFolder
        panel.allowsMultipleSelection = surface.filePickerAllowsMultiple
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        let box = NativeFilePickerCaptureBox()
        panel.beginSheetModal(for: window) { _ in
            box.finished = true
        }

        let surfaceFrame = frame(for: surface, origin: .zero)
        let deadline = Date().addingTimeInterval(5)
        let captureTimer = Timer(timeInterval: 0.5, repeats: false) { _ in
            box.result = Result {
                try captureScreenRegion(
                    aroundWindowID: windowID,
                    nativeSurfaceFrame: surfaceFrame,
                    to: url
                )
            }
            panel.cancel(nil)
        }
        RunLoop.current.add(captureTimer, forMode: .default)
        while box.result == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.05))
        }

        if box.result == nil {
            panel.cancel(nil)
        }
        while !box.finished && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.05))
        }

        if let result = box.result {
            return try result.get()
        }

        return try captureScreenRegion(
            aroundWindowID: windowID,
            nativeSurfaceFrame: surfaceFrame,
            to: url
        )
    }

    private func frame(for surface: OwlFreshSurfaceInfo, origin: CGPoint) -> CGRect {
        return CGRect(
            x: CGFloat(surface.x) - origin.x,
            y: CGFloat(surface.y) - origin.y,
            width: CGFloat(surface.width),
            height: CGFloat(surface.height)
        )
    }

    private func updateDevToolsCloseControl(surface: OwlFreshSurfaceInfo) {
        let surfaceFrame = frame(for: surface, origin: .zero)
        let buttonSize = CGSize(width: 32, height: 26)
        let buttonFrame = CGRect(
            x: max(surfaceFrame.minX + 8, surfaceFrame.maxX - buttonSize.width - 10),
            y: max(surfaceFrame.minY + 8, surfaceFrame.maxY - buttonSize.height - 8),
            width: buttonSize.width,
            height: buttonSize.height
        )

        let buttonLayer: CALayer
        let textLayer: CATextLayer
        if let existingButton = devToolsCloseLayer, let existingText = devToolsCloseTextLayer {
            buttonLayer = existingButton
            textLayer = existingText
        } else {
            buttonLayer = CALayer()
            buttonLayer.cornerRadius = 4
            buttonLayer.borderWidth = 1
            buttonLayer.borderColor = NSColor(calibratedWhite: 0.45, alpha: 1).cgColor
            buttonLayer.backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 0.95).cgColor
            buttonLayer.zPosition = 500

            textLayer = CATextLayer()
            textLayer.string = "X"
            textLayer.alignmentMode = .center
            textLayer.foregroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
            textLayer.fontSize = 16
            textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            textLayer.zPosition = 501
            buttonLayer.addSublayer(textLayer)
            rootLayer.addSublayer(buttonLayer)
            devToolsCloseLayer = buttonLayer
            devToolsCloseTextLayer = textLayer
        }
        buttonLayer.frame = buttonFrame
        textLayer.frame = CGRect(origin: .zero, size: buttonFrame.size)

        let button: NSButton
        if let existing = devToolsCloseButton {
            button = existing
        } else {
            button = NSButton(frame: .zero)
            button.title = ""
            button.isBordered = false
            button.target = devToolsCloseButtonTarget
            button.action = #selector(CloseButtonTarget.performClose(_:))
            button.toolTip = "Close DevTools"
            contentView.addSubview(button)
            devToolsCloseButton = button
        }
        button.frame = buttonFrame
        button.isHidden = false
    }

    private func primarySurface(in surfaceTree: OwlFreshSurfaceTree) -> OwlFreshSurfaceInfo? {
        let visibleSurfaces = surfaceTree.surfaces.filter(\.visible)
        return visibleSurfaces.first(where: { $0.kind == .webView && $0.contextId != 0 }) ??
            visibleSurfaces.first(where: { $0.contextId != 0 })
    }

    private func contentsScale(for surface: OwlFreshSurfaceInfo) -> CGFloat {
        max(CGFloat(surface.scale), 1.0)
    }

    private func isDetachedSurface(_ surface: OwlFreshSurfaceInfo) -> Bool {
        surface.kind == .devTools && surface.label == "devtools-window"
    }

    func flushHostedLayer() {
        hostLayer.setNeedsDisplay()
        hostLayer.displayIfNeeded()
        for layer in popupHostLayers.values {
            layer.setNeedsDisplay()
            layer.displayIfNeeded()
        }
        for detachedWindow in detachedSurfaceWindows.values {
            detachedWindow.flushHostedLayer()
        }
        CATransaction.flush()
    }

}

private final class DetachedSurfaceHostWindow {
    let label: String
    let title: String
    private let window: NSWindow
    private let contentView: NSView
    private let rootLayer: CALayer
    private let hostLayer: CALayer
    private var contextID: UInt32

    init(surface: OwlFreshSurfaceInfo) throws {
        self.label = surface.label
        self.title = "OWL LayerHost \(surface.label)"
        self.contextID = surface.contextId

        let size = CGSize(width: CGFloat(surface.width), height: CGFloat(surface.height))
        let frame = NSRect(origin: .zero, size: size)
        let contentView = NSView(frame: frame)
        contentView.wantsLayer = true
        let rootLayer = CALayer()
        rootLayer.isGeometryFlipped = true
        rootLayer.backgroundColor = NSColor.white.cgColor
        rootLayer.frame = CGRect(origin: .zero, size: size)
        contentView.layer = rootLayer
        self.contentView = contentView
        self.rootLayer = rootLayer

        let hostLayer = try makeCALayerHost(contextID: surface.contextId)
        hostLayer.anchorPoint = CGPoint.zero
        hostLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        hostLayer.contentsScale = max(CGFloat(surface.scale), 1.0)
        hostLayer.frame = rootLayer.bounds
        hostLayer.bounds = rootLayer.bounds
        hostLayer.position = CGPoint.zero
        rootLayer.addSublayer(hostLayer)
        self.hostLayer = hostLayer

        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = contentView
        window.backgroundColor = .white
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.sharingType = .readOnly
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
    }

    func update(surface: OwlFreshSurfaceInfo) {
        let size = CGSize(width: CGFloat(surface.width), height: CGFloat(surface.height))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if window.contentView?.bounds.size != size {
            window.setContentSize(size)
            contentView.setFrameSize(size)
            rootLayer.frame = CGRect(origin: .zero, size: size)
            rootLayer.bounds = CGRect(origin: .zero, size: size)
        }
        hostLayer.contentsScale = max(CGFloat(surface.scale), 1.0)
        hostLayer.frame = rootLayer.bounds
        hostLayer.bounds = rootLayer.bounds
        hostLayer.position = CGPoint.zero
        if contextID != surface.contextId {
            contextID = surface.contextId
            hostLayer.setValue(NSNumber(value: surface.contextId), forKey: "contextId")
        }
        CATransaction.commit()
        flushHostedLayer()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.sharingType = .readOnly
    }

    func close() {
        window.close()
    }

    func flushHostedLayer() {
        hostLayer.setNeedsDisplay()
        hostLayer.displayIfNeeded()
        CATransaction.flush()
    }
}

private func validateNativeMenuSurface(_ surface: OwlFreshSurfaceInfo, targetName: String) throws {
    guard surface.width > 0, surface.height > 0 else {
        throw VerifierError.input("\(targetName) native menu surface has empty control bounds: \(surface)")
    }

    guard surface.label == "select-menu" else {
        return
    }

    guard !surface.nativeMenuItems.isEmpty else {
        throw VerifierError.input("\(targetName) select menu missing Chrome native menu item metadata: \(surface)")
    }
    guard surface.itemFontSize > 0 else {
        throw VerifierError.input("\(targetName) select menu missing Chrome item font size: \(surface)")
    }
    guard surface.height <= 80 else {
        throw VerifierError.input("\(targetName) select menu still looks like synthesized popup bounds: \(surface)")
    }
}

private func validateNativeFilePickerSurface(_ surface: OwlFreshSurfaceInfo, targetName: String) throws {
    guard surface.label == "file-picker" else {
        throw VerifierError.input("\(targetName) native file picker has unexpected label: \(surface)")
    }
    guard surface.filePickerMode == "open" else {
        throw VerifierError.input("\(targetName) native file picker has unexpected mode: \(surface)")
    }
    guard surface.filePickerAcceptTypes.contains(".txt") else {
        throw VerifierError.input("\(targetName) native file picker missing .txt accept type: \(surface)")
    }
    guard !surface.filePickerAllowsMultiple else {
        throw VerifierError.input("\(targetName) native file picker unexpectedly allows multiple selection: \(surface)")
    }
    guard !surface.filePickerUploadFolder else {
        throw VerifierError.input("\(targetName) native file picker unexpectedly requests folder upload: \(surface)")
    }
}

private func writeNativeSurface(
    _ surface: OwlFreshSurfaceInfo,
    screenshotName: String,
    outputDirectory: URL
) throws {
    let baseName = screenshotName.hasSuffix(".png")
        ? String(screenshotName.dropLast(4))
        : screenshotName
    let url = outputDirectory.appendingPathComponent("\(baseName)-surface.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(surface).write(to: url)
}

private func nativeSurfaceDiagnosticName(baseName: String, suffix: String) -> String {
    let stem = baseName.hasSuffix(".png") ? String(baseName.dropLast(4)) : baseName
    return "\(stem)-\(suffix).png"
}

private final class NativeMenuRunner: NSObject {
    let menu: NSMenu
    private let selectedIndex: Int32
    private let itemFontSize: CGFloat
    private let rightAligned: Bool
    private var selectedMenuItemIndex: Int?

    init(surface: OwlFreshSurfaceInfo) {
        menu = NSMenu(title: surface.label)
        menu.autoenablesItems = false
        selectedIndex = surface.selectedIndex
        itemFontSize = CGFloat(
            surface.itemFontSize > 0 ? surface.itemFontSize : Float(NSFont.systemFontSize)
        )
        rightAligned = surface.rightAligned
        super.init()

        let items = surface.nativeMenuItems.isEmpty
            ? surface.menuItems.map { label in
                OwlFreshNativeMenuItem(
                    label: label,
                    toolTip: "",
                    enabled: true,
                    separator: label == "---",
                    group: false,
                    textDirection: 2,
                    hasTextDirectionOverride: false
                )
            }
            : surface.nativeMenuItems
        for item in items {
            addItem(item)
        }
    }

    func run(in view: NSView, bounds: NSRect) {
        let cell = NSPopUpButtonCell(textCell: "", pullsDown: false)
        cell.menu = menu
        if selectedIndex > -1 {
            cell.selectItem(withTag: Int(selectedIndex))
        } else {
            cell.selectItem(at: -1)
        }

        if rightAligned {
            cell.userInterfaceLayoutDirection = .rightToLeft
            menu.userInterfaceLayoutDirection = .rightToLeft
        }

        let fakeControlView = NSView(frame: bounds)
        view.addSubview(fakeControlView)
        cell.attachPopUp(withFrame: fakeControlView.bounds, in: fakeControlView)
        cell.performClick(withFrame: fakeControlView.bounds, in: fakeControlView)
        fakeControlView.removeFromSuperview()
    }

    func cancel() {
        menu.cancelTrackingWithoutAnimation()
    }

    private func addItem(_ item: OwlFreshNativeMenuItem) {
        if item.separator {
            menu.addItem(.separator())
            return
        }

        let title = item.label.isEmpty ? " " : item.label
        let menuItem = menu.addItem(
            withTitle: title,
            action: #selector(menuItemSelected(_:)),
            keyEquivalent: ""
        )
        if !item.toolTip.isEmpty {
            menuItem.toolTip = item.toolTip
        }
        menuItem.isEnabled = item.enabled && !item.group
        menuItem.target = self

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = rightAligned ? .right : .left
        let writingDirection: NSWritingDirection = item.textDirection == 1
            ? .rightToLeft
            : .leftToRight
        paragraphStyle.baseWritingDirection = writingDirection
        paragraphStyle.lineBreakMode = .byTruncatingTail

        var attributes: [NSAttributedString.Key: Any] = [
            .paragraphStyle: paragraphStyle,
            .font: NSFont.menuFont(ofSize: itemFontSize),
        ]
        if item.hasTextDirectionOverride {
            attributes[.writingDirection] = [
                NSNumber(value: writingDirection.rawValue | NSWritingDirectionFormatType.override.rawValue),
            ]
        }
        menuItem.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        menuItem.title = title.trimmingCharacters(in: .whitespaces)
        menuItem.tag = menu.numberOfItems - 1
    }

    @objc private func menuItemSelected(_ sender: NSMenuItem) {
        selectedMenuItemIndex = sender.tag
    }
}

private final class NativeMenuCaptureBox {
    var result: Result<CapturedWindow, Error>?
}

private final class NativeFilePickerCaptureBox {
    var result: Result<CapturedWindow, Error>?
    var finished = false
}

private struct CapturedWindow {
    let image: CGImage
}

private func makeCALayerHost(contextID: UInt32) throws -> CALayer {
    guard let layerClass = NSClassFromString("CALayerHost") as? NSObject.Type else {
        throw VerifierError.layerHost("CALayerHost is not available")
    }
    guard let layer = layerClass.init() as? CALayer else {
        throw VerifierError.layerHost("CALayerHost did not instantiate as CALayer")
    }
    layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 1.0
    layer.setValue(NSNumber(value: contextID), forKey: "contextId")
    layer.setValue(true, forKey: "inheritsSecurity")
    return layer
}

private extension String {
    func jsonObjectStringValue(for key: String) throws -> String {
        let data = Data(utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] as? String else {
            throw VerifierError.bridge("expected JSON object string field \(key), got \(self)")
        }
        return value
    }
}

private func pumpApp(_ app: NSApplication, for duration: TimeInterval) {
    let end = Date().addingTimeInterval(duration)
    repeat {
        if let event = app.nextEvent(
            matching: .any,
            until: Date().addingTimeInterval(0.01),
            inMode: .default,
            dequeue: true
        ) {
            app.sendEvent(event)
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    } while Date() < end
}

private func swiftHostWindowID(title: String, minimumSize: CGSize) -> UInt32? {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }

    for window in windows {
        guard (window[kCGWindowOwnerPID as String] as? Int32) == getpid(),
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? NSNumber,
              let height = bounds["Height"] as? NSNumber,
              width.doubleValue >= minimumSize.width,
              height.doubleValue >= minimumSize.height else {
            continue
        }
        let id = windowNumber(from: window)
        guard let id else {
            continue
        }
        if (window[kCGWindowName as String] as? String) == title {
            return id
        }
    }

    return nil
}

private func windowNumber(from window: [String: Any]) -> UInt32? {
    if let number = window[kCGWindowNumber as String] as? UInt32 {
        return number
    }
    if let number = window[kCGWindowNumber as String] as? Int {
        return UInt32(number)
    }
    return nil
}

private func captureWindow(windowID: UInt32, to url: URL) throws -> CapturedWindow {
    do {
        let capture = try captureWindowWithScreencapture(windowID: windowID, to: url)
        if isMostlyBlack(capture.image) {
            if let fallback = try? captureWindowWithOnScreenBounds(windowID: windowID, to: url),
               !isMostlyBlack(fallback.image) {
                return fallback
            }
            if let fallback = try? captureWindowWithCoreGraphics(windowID: windowID, to: url),
               !isMostlyBlack(fallback.image) {
                return fallback
            }
        }
        return capture
    } catch {
        return try captureWindowWithCoreGraphics(windowID: windowID, to: url)
    }
}

private func captureWindowWithCoreGraphics(windowID: UInt32, to url: URL) throws -> CapturedWindow {
    guard let image = CGWindowListCreateImage(
        .null,
        [.optionIncludingWindow],
        CGWindowID(windowID),
        [.bestResolution, .boundsIgnoreFraming]
    ) else {
        throw VerifierError.capture("CGWindowListCreateImage returned nil for windowID=\(windowID)")
    }
    try pngData(from: image).write(to: url)
    return CapturedWindow(image: image)
}

private func captureScreenRegion(
    aroundWindowID windowID: UInt32,
    nativeSurfaceFrame: CGRect,
    to url: URL
) throws -> CapturedWindow {
    guard let windowBounds = screenBounds(windowID: windowID) else {
        throw VerifierError.capture("could not resolve screen bounds for windowID=\(windowID)")
    }
    let captureBounds = nativeMenuCaptureBounds(
        hostWindowID: windowID,
        hostWindowBounds: windowBounds,
        nativeSurfaceFrame: nativeSurfaceFrame
    )
    guard let image = CGWindowListCreateImage(
        captureBounds,
        [.optionOnScreenOnly],
        kCGNullWindowID,
        [.bestResolution]
    ) else {
        throw VerifierError.capture("CGWindowListCreateImage returned nil for screen bounds \(captureBounds)")
    }
    try pngData(from: image).write(to: url)
    return CapturedWindow(image: image)
}

private func captureWindowWithOnScreenBounds(windowID: UInt32, to url: URL) throws -> CapturedWindow {
    guard let bounds = screenBounds(windowID: windowID) else {
        throw VerifierError.capture("could not resolve screen bounds for windowID=\(windowID)")
    }
    guard let image = CGWindowListCreateImage(
        bounds.integral,
        [.optionOnScreenOnly],
        kCGNullWindowID,
        [.bestResolution]
    ) else {
        throw VerifierError.capture("CGWindowListCreateImage returned nil for on-screen bounds \(bounds)")
    }
    try pngData(from: image).write(to: url)
    return CapturedWindow(image: image)
}

private func nativeMenuCaptureBounds(
    hostWindowID: UInt32,
    hostWindowBounds: CGRect,
    nativeSurfaceFrame: CGRect
) -> CGRect {
    let menuBounds = currentProcessWindowBounds(excluding: hostWindowID)
        .filter { bounds in
            bounds.width >= 24 && bounds.height >= 24 &&
                bounds.width <= 1_200 && bounds.height <= 1_200
        }
    if !menuBounds.isEmpty {
        return menuBounds
            .reduce(hostWindowBounds) { $0.union($1) }
            .insetBy(dx: -18, dy: -18)
            .integral
    }

    let xPadding = max(CGFloat(360), nativeSurfaceFrame.width + 96)
    let yPadding = max(CGFloat(260), nativeSurfaceFrame.height + 96)
    return hostWindowBounds
        .insetBy(dx: -xPadding, dy: -yPadding)
        .integral
}

private func captureWindowWithScreencapture(windowID: UInt32, to url: URL) throws -> CapturedWindow {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-l\(windowID)", url.path]
    process.standardOutput = Pipe()
    let stderr = Pipe()
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw VerifierError.capture("screencapture failed with status \(process.terminationStatus) windowID=\(windowID) \(errorText)")
    }

    let data = try Data(contentsOf: url)
    guard let image = loadImage(from: data) else {
        throw VerifierError.capture("screencapture returned invalid PNG data")
    }
    return CapturedWindow(image: image)
}

private func screenBounds(windowID: UInt32) -> CGRect? {
    guard let windows = CGWindowListCopyWindowInfo(
        [.optionIncludingWindow],
        CGWindowID(windowID)
    ) as? [[String: Any]] else {
        return nil
    }
    for window in windows where windowNumber(from: window) == windowID {
        return screenBounds(from: window)
    }
    return nil
}

private func currentProcessWindowBounds(excluding excludedWindowID: UInt32) -> [CGRect] {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return []
    }

    return windows.compactMap { window in
        guard (window[kCGWindowOwnerPID as String] as? Int32) == getpid(),
              windowNumber(from: window) != excludedWindowID,
              let bounds = screenBounds(from: window) else {
            return nil
        }
        return bounds
    }
}

private func screenBounds(from window: [String: Any]) -> CGRect? {
    guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let x = bounds["X"] as? NSNumber,
          let y = bounds["Y"] as? NSNumber,
          let width = bounds["Width"] as? NSNumber,
          let height = bounds["Height"] as? NSNumber else {
        return nil
    }
    return CGRect(
        x: CGFloat(truncating: x),
        y: CGFloat(truncating: y),
        width: CGFloat(truncating: width),
        height: CGFloat(truncating: height)
    )
}

private func pngData(from image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
        throw VerifierError.pngWrite("could not create PNG destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw VerifierError.pngWrite("could not finalize PNG data")
    }
    return data as Data
}

private struct RGBPixel: CustomStringConvertible {
    let r: Int
    let g: Int
    let b: Int

    var description: String {
        "rgb(\(r),\(g),\(b))"
    }
}

private struct ImagePixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func colorAt(x: Int, y: Int) throws -> RGBPixel {
        guard x >= 0, x < width, y >= 0, y < height else {
            throw VerifierError.pixelCheck("pixel sample out of bounds x=\(x) y=\(y) image=\(width)x\(height)")
        }
        let offset = ((y * width) + x) * 4
        return RGBPixel(
            r: Int(bytes[offset]),
            g: Int(bytes[offset + 1]),
            b: Int(bytes[offset + 2])
        )
    }
}

private enum ResizeEdgeColor: String {
    case redTop
    case greenRight
    case blueBottom
    case yellowLeft

    func matches(_ pixel: RGBPixel) -> Bool {
        switch self {
        case .redTop:
            pixel.r >= 220 && pixel.g <= 80 && pixel.b <= 80
        case .greenRight:
            pixel.r <= 90 && pixel.g >= 150 && pixel.b <= 120
        case .blueBottom:
            pixel.r <= 90 && pixel.g <= 140 && pixel.b >= 180
        case .yellowLeft:
            pixel.r >= 220 && pixel.g >= 180 && pixel.b <= 90
        }
    }
}

private func verifyResizeEdgeCoverage(
    image: CGImage,
    contentSize: CGSize,
    targetName: String,
    artifactName: String
) throws {
    let pixels = renderPixels(from: image)
    let expectedWidth = Int(contentSize.width.rounded())
    let expectedContentHeight = Int(contentSize.height.rounded())
    guard pixels.width == expectedWidth else {
        throw VerifierError.pixelCheck(
            "\(targetName) \(artifactName) expected captured window width \(expectedWidth), got \(pixels.width)"
        )
    }
    let titlebarHeight = pixels.height - expectedContentHeight
    guard titlebarHeight >= 0, titlebarHeight <= 80 else {
        throw VerifierError.pixelCheck(
            "\(targetName) \(artifactName) expected content height \(expectedContentHeight) inside captured window \(pixels.width)x\(pixels.height), got titlebar delta \(titlebarHeight)"
        )
    }

    let centerX = pixels.width / 2
    let centerY = titlebarHeight + expectedContentHeight / 2
    let samples: [(String, ResizeEdgeColor, Int, Int)] = [
        ("top", .redTop, centerX, titlebarHeight + 8),
        ("right", .greenRight, pixels.width - 8, centerY),
        ("bottom", .blueBottom, centerX, pixels.height - 8),
        ("left", .yellowLeft, 8, centerY),
    ]
    for (edge, expected, x, y) in samples {
        let pixel = try pixels.colorAt(x: x, y: y)
        guard expected.matches(pixel) else {
            throw VerifierError.pixelCheck(
                "\(targetName) \(artifactName) expected \(expected.rawValue) on \(edge) edge at x=\(x) y=\(y), got \(pixel). This indicates the Chromium surface did not cover the Swift host edge."
            )
        }
    }
}

private enum ExpectedPixel: Hashable {
    case red
    case green
    case blue
    case yellow
    case dark
    case light
    case nonWhite
}

private extension Set where Element == ExpectedPixel {
    func isSatisfied(by stats: PixelStats) -> Bool {
        allSatisfy { expected in
            switch expected {
            case .red:
                stats.redPixels > 12_000
            case .green:
                stats.greenPixels > 12_000
            case .blue:
                stats.bluePixels > 8_000
            case .yellow:
                stats.yellowPixels > 20_000
            case .dark:
                stats.darkPixels > 1_000
            case .light:
                stats.lightPixels > 20_000
            case .nonWhite:
                stats.nonWhitePixels > 10_000
            }
        }
    }
}

private func renderPixels(from image: CGImage) -> ImagePixels {
    let width = image.width
    let height = image.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue |
        CGImageAlphaInfo.premultipliedLast.rawValue

    pixels.withUnsafeMutableBytes { buffer in
        if let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    return ImagePixels(width: width, height: height, bytes: pixels)
}

private func analyze(image: CGImage) -> PixelStats {
    let bytesPerPixel = 4
    let rendered = renderPixels(from: image)

    var red = 0
    var green = 0
    var blue = 0
    var yellow = 0
    var dark = 0
    var light = 0
    var nonWhite = 0

    for offset in stride(from: 0, to: rendered.bytes.count, by: bytesPerPixel) {
        let r = Int(rendered.bytes[offset])
        let g = Int(rendered.bytes[offset + 1])
        let b = Int(rendered.bytes[offset + 2])

        if r >= 220, g <= 70, b <= 70 {
            red += 1
        }
        if r <= 90, g >= 150, b <= 120 {
            green += 1
        }
        if r <= 90, g <= 130, b >= 180 {
            blue += 1
        }
        if r >= 220, g >= 180, b <= 90 {
            yellow += 1
        }
        if r < 70, g < 70, b < 70 {
            dark += 1
        }
        if r > 230, g > 230, b > 230 {
            light += 1
        }
        if r < 245 || g < 245 || b < 245 {
            nonWhite += 1
        }
    }

    return PixelStats(
        width: rendered.width,
        height: rendered.height,
        redPixels: red,
        greenPixels: green,
        bluePixels: blue,
        yellowPixels: yellow,
        darkPixels: dark,
        lightPixels: light,
        nonWhitePixels: nonWhite
    )
}

private func isMostlyBlack(_ image: CGImage) -> Bool {
    let stats = analyze(image: image)
    return stats.darkPixels > (stats.width * stats.height * 95 / 100)
}

private func loadImage(from data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
        return nil
    }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

private func processCommandLine(pid: Int32) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", "\(pid)", "-ww", "-o", "command="]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return ""
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func containsRemoteDebuggingArgument(_ command: String) -> Bool {
    command.contains("--remote-debugging-port") ||
        command.contains("--remote-debugging-pipe") ||
        command.contains("--remote-allow-origins")
}

private func hasDevToolsActivePort(profileDirectory: URL) -> Bool {
    FileManager.default.fileExists(
        atPath: profileDirectory.appendingPathComponent("DevToolsActivePort").path
    )
}

private func terminateHostProcessIfNeeded(pid: Int32) {
    guard pid > 0, kill(pid, 0) == 0 else {
        return
    }

    _ = kill(pid, SIGTERM)
    let deadline = Date().addingTimeInterval(1.0)
    while Date() < deadline {
        if kill(pid, 0) != 0 {
            return
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }

    if kill(pid, 0) == 0 {
        _ = kill(pid, SIGKILL)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private func renderGeneratedTransportReport(summary: Summary) -> String {
    let rows = summary.captures.map { capture in
        """
              <tr>
                <td><code>\(escapeHTML(capture.name))</code></td>
                <td>\(capture.generatedTransportCallCount)</td>
                <td><code>\(escapeHTML(capture.generatedTransportTracePath))</code></td>
              </tr>
        """
    }.joined(separator: "\n")

    return """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>OWL Generated Transport Report</title>
      <style>
        html, body { margin: 0; background: #f7f7f7; color: #141414; font: 16px -apple-system, BlinkMacSystemFont, sans-serif; }
        main { width: 1120px; margin: 0 auto; padding: 32px 0 48px; }
        h1 { margin: 0 0 12px; font-size: 34px; letter-spacing: 0; }
        .status { border: 4px solid #141414; padding: 18px 22px; background: rgb(0, 204, 82); font-weight: 900; font-size: 30px; }
        .grid { display: grid; grid-template-columns: 230px 1fr; gap: 8px 18px; margin: 18px 0 26px; }
        .label { font-weight: 800; }
        table { width: 100%; border-collapse: collapse; background: white; border: 4px solid #141414; }
        th, td { border: 2px solid #141414; padding: 10px 12px; text-align: left; vertical-align: top; }
        th { background: #0059ff; color: white; font-weight: 900; }
        code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 14px; }
      </style>
    </head>
    <body>
      <main>
        <h1>OWL Generated Transport Report</h1>
        <div class="status">PASS: Swift host requests used the generated Mojo transport surface.</div>
        <div class="grid">
          <div class="label">Control transport</div><div><code>\(escapeHTML(summary.controlTransport))</code></div>
          <div class="label">Swift host transport</div><div><code>\(escapeHTML(summary.swiftHostTransport))</code></div>
          <div class="label">Mojo runtime</div><div><code>\(escapeHTML(summary.mojoRuntime))</code></div>
          <div class="label">Binding checksum</div><div><code>\(escapeHTML(summary.mojoBindingSourceChecksum))</code></div>
          <div class="label">Binding declarations</div><div><code>\(summary.mojoBindingDeclarationCount)</code></div>
          <div class="label">DevTools active port</div><div><code>\(summary.devToolsActivePortFound)</code></div>
          <div class="label">Remote debugging args</div><div><code>\(summary.remoteDebuggingArgumentFound)</code></div>
        </div>
        <table>
          <thead>
            <tr><th>Capture</th><th>Generated transport calls</th><th>Trace artifact</th></tr>
          </thead>
          <tbody>
    \(rows)
          </tbody>
        </table>
      </main>
    </body>
    </html>
    """

}

private func escapeHTML(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private enum Fixtures {
    static let canvasFixture = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>OWL LayerHost canvas fixture</title>
      <style>
        html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: rgb(248,248,248); }
        canvas { display: block; width: 960px; height: 640px; }
      </style>
    </head>
    <body>
      <canvas id="fixture" width="960" height="640"></canvas>
      <script>
        const canvas = document.getElementById("fixture");
        const context = canvas.getContext("2d");
        context.fillStyle = "rgb(248,248,248)";
        context.fillRect(0, 0, canvas.width, canvas.height);
        context.fillStyle = "rgb(255,0,0)";
        context.fillRect(48, 56, 180, 140);
        context.fillStyle = "rgb(0,204,68)";
        context.fillRect(288, 56, 180, 140);
        context.fillStyle = "rgb(0,89,255)";
        context.fillRect(528, 56, 180, 140);
        context.fillStyle = "rgb(20,20,20)";
        context.font = "40px -apple-system, BlinkMacSystemFont, sans-serif";
        context.fillText("OWL_LAYER_HOST_SENTINEL", 48, 292);
      </script>
    </body>
    </html>
    """

    static let inputFixture = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>OWL LayerHost input fixture</title>
      <style>
        html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: rgb(248,248,248); }
        #target {
          position: absolute;
          left: 48px;
          top: 56px;
          width: 244px;
          height: 148px;
          background: rgb(180, 180, 180);
        }
        #status {
          position: absolute;
          left: 48px;
          top: 260px;
          font: 42px -apple-system, BlinkMacSystemFont, sans-serif;
          color: rgb(20,20,20);
        }
        body.ready #target {
          background: rgb(255, 0, 0);
        }
        body.ready.clicked #target {
          background: rgb(255, 210, 0);
        }
      </style>
    </head>
    <body>
      <button id="target" aria-label="OWL input target"></button>
      <div id="status">OWL_INPUT_BOOTING</div>
      <script>
        const status = document.getElementById("status");
        const markInput = () => {
          document.body.classList.add("clicked");
          status.textContent = "OWL_INPUT_CLICKED";
        };
        for (const eventName of ["pointermove", "pointerdown", "pointerup", "mousemove", "mousedown", "mouseup", "click"]) {
          document.addEventListener(eventName, markInput);
        }
        document.addEventListener("keydown", markInput);
        document.body.classList.add("ready");
        status.textContent = "OWL_INPUT_READY";
      </script>
    </body>
    </html>
    """

    static let formFixture = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>OWL LayerHost form fixture</title>
      <style>
        html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: rgb(248,248,248); }
        body { font: 30px -apple-system, BlinkMacSystemFont, sans-serif; color: rgb(20,20,20); }
        #banner {
          position: absolute;
          left: 48px;
          top: 40px;
          width: 864px;
          height: 58px;
          background: rgb(0, 89, 255);
          color: white;
          display: flex;
          align-items: center;
          padding-left: 22px;
          box-sizing: border-box;
          font-weight: 700;
        }
        #nameInput {
          position: absolute;
          left: 48px;
          top: 116px;
          width: 380px;
          height: 64px;
          box-sizing: border-box;
          border: 4px solid rgb(20,20,20);
          border-radius: 0;
          font: 30px -apple-system, BlinkMacSystemFont, sans-serif;
          padding: 0 16px;
          color: rgb(20,20,20);
          background: white;
        }
        #typed {
          position: absolute;
          left: 456px;
          top: 127px;
          width: 420px;
          height: 48px;
          font-weight: 700;
        }
        #agreeLabel {
          position: absolute;
          left: 48px;
          top: 218px;
          height: 58px;
          display: flex;
          align-items: center;
          gap: 14px;
          font-weight: 700;
        }
        #agree {
          width: 32px;
          height: 32px;
        }
        #submit {
          position: absolute;
          left: 48px;
          top: 298px;
          width: 220px;
          height: 72px;
          border: 4px solid rgb(20,20,20);
          background: rgb(255, 210, 0);
          color: rgb(20,20,20);
          font: 30px -apple-system, BlinkMacSystemFont, sans-serif;
          font-weight: 800;
        }
        #status {
          position: absolute;
          left: 300px;
          top: 314px;
          width: 560px;
          height: 42px;
          font-weight: 800;
        }
        #result {
          position: absolute;
          left: 48px;
          top: 408px;
          width: 864px;
          height: 144px;
          box-sizing: border-box;
          border: 4px solid rgb(20,20,20);
          background: rgb(238,238,238);
          display: flex;
          align-items: center;
          padding-left: 28px;
          font-size: 40px;
          font-weight: 900;
        }
        body.submitted #result {
          background: rgb(0, 204, 82);
        }
        body.submitted #nameInput,
        body.submitted #typed,
        body.submitted #agreeLabel,
        body.submitted #submit {
          display: none;
        }
        body.submitted #status {
          left: 48px;
          top: 128px;
          width: 864px;
          height: 72px;
          display: flex;
          align-items: center;
          box-sizing: border-box;
          padding-left: 28px;
          background: rgb(255, 210, 0);
          font-size: 46px;
        }
        body.submitted #result {
          top: 220px;
          height: 250px;
        }
      </style>
    </head>
    <body class="ready">
      <div id="banner">HELLO_OWL_FORM_READY</div>
      <input id="nameInput" aria-label="Hello OWL input" autocomplete="off" spellcheck="false" autofocus>
      <div id="typed">typed: EMPTY</div>
      <label id="agreeLabel"><input id="agree" type="checkbox">check path active</label>
      <button id="submit" type="button">Submit</button>
      <div id="status">HELLO_OWL_WAITING</div>
      <div id="result">HELLO_OWL_NOT_SUBMITTED</div>
      <script>
        const input = document.getElementById("nameInput");
        const agree = document.getElementById("agree");
        const submit = document.getElementById("submit");
        const typed = document.getElementById("typed");
        const status = document.getElementById("status");
        const result = document.getElementById("result");

        const updateTyped = () => {
          typed.textContent = "typed: " + (input.value || "EMPTY");
        };
        const submitForm = () => {
          if (input.value === "hello owl" && agree.checked) {
            input.blur();
            submit.blur();
            document.body.classList.add("submitted");
            status.textContent = "HELLO_OWL_SUBMITTED";
            result.textContent = "HELLO_OWL_SUBMITTED: " + input.value;
          } else {
            status.textContent = "HELLO_OWL_INCOMPLETE";
          }
        };

        input.addEventListener("input", updateTyped);
        submit.addEventListener("click", submitForm);
        input.focus();
        updateTyped();
      </script>
    </body>
    </html>
    """

    static let modifierFixture = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>OWL LayerHost modifier fixture</title>
      <style>
        html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: rgb(248,248,248); }
        body { font: 30px -apple-system, BlinkMacSystemFont, sans-serif; color: rgb(20,20,20); }
        #banner {
          position: absolute;
          left: 48px;
          top: 40px;
          width: 864px;
          height: 58px;
          background: rgb(0, 89, 255);
          color: white;
          display: flex;
          align-items: center;
          padding-left: 22px;
          box-sizing: border-box;
          font-weight: 700;
        }
        #modInput {
          position: absolute;
          left: 48px;
          top: 116px;
          width: 380px;
          height: 64px;
          box-sizing: border-box;
          border: 4px solid rgb(20,20,20);
          border-radius: 0;
          font: 30px -apple-system, BlinkMacSystemFont, sans-serif;
          padding: 0 16px;
          color: rgb(20,20,20);
          background: white;
        }
        #typed {
          position: absolute;
          left: 456px;
          top: 127px;
          width: 420px;
          height: 48px;
          font-weight: 700;
        }
        #modifiers {
          position: absolute;
          left: 48px;
          top: 218px;
          width: 864px;
          display: grid;
          grid-template-columns: repeat(4, 1fr);
          gap: 12px;
        }
        .chip {
          height: 70px;
          box-sizing: border-box;
          border: 4px solid rgb(20,20,20);
          background: rgb(238,238,238);
          display: flex;
          align-items: center;
          justify-content: center;
          font-weight: 900;
        }
        .chip.ok {
          background: rgb(255, 210, 0);
        }
        #status {
          position: absolute;
          left: 48px;
          top: 340px;
          width: 864px;
          height: 72px;
          display: flex;
          align-items: center;
          box-sizing: border-box;
          padding-left: 28px;
          background: rgb(238,238,238);
          border: 4px solid rgb(20,20,20);
          font-size: 42px;
          font-weight: 900;
        }
        body.done #status {
          background: rgb(0, 204, 82);
        }
        #result {
          position: absolute;
          left: 48px;
          top: 452px;
          width: 864px;
          height: 96px;
          box-sizing: border-box;
          border: 4px solid rgb(20,20,20);
          background: white;
          display: flex;
          align-items: center;
          padding-left: 28px;
          font-size: 38px;
          font-weight: 900;
        }
      </style>
    </head>
    <body class="ready">
      <div id="banner">OWL_MODIFIER_FORM_READY</div>
      <input id="modInput" aria-label="OWL modifier input" autocomplete="off" spellcheck="false" autofocus>
      <div id="typed">typed: EMPTY</div>
      <div id="modifiers">
        <div id="cmd" class="chip">CMD</div>
        <div id="opt" class="chip">OPT</div>
        <div id="ctrl" class="chip">CTRL</div>
        <div id="shift" class="chip">SHIFT</div>
      </div>
      <div id="status">OWL_MODIFIERS_WAITING</div>
      <div id="result">value: EMPTY</div>
      <script>
        const input = document.getElementById("modInput");
        const typed = document.getElementById("typed");
        const status = document.getElementById("status");
        const result = document.getElementById("result");
        const state = {
          commandSeen: false,
          optionSeen: false,
          controlSeen: false,
          shiftSeen: false
        };
        window.owlModifierState = state;

        const setChip = (id, ok) => {
          document.getElementById(id).classList.toggle("ok", ok);
        };
        const render = () => {
          typed.textContent = "typed: " + (input.value || "EMPTY");
          result.textContent = "value: " + (input.value || "EMPTY");
          setChip("cmd", state.commandSeen);
          setChip("opt", state.optionSeen);
          setChip("ctrl", state.controlSeen);
          setChip("shift", state.shiftSeen);
          if (
            input.value === "plainS" &&
            state.commandSeen &&
            state.optionSeen &&
            state.controlSeen &&
            state.shiftSeen
          ) {
            input.blur();
            document.body.classList.add("done");
            status.textContent = "OWL_MODIFIERS_OK";
          }
        };

        input.addEventListener("input", render);
        document.addEventListener("keydown", (event) => {
          if (event.metaKey) {
            state.commandSeen = true;
          }
          if (event.altKey) {
            state.optionSeen = true;
          }
          if (event.ctrlKey) {
            state.controlSeen = true;
          }
          if (event.shiftKey) {
            state.shiftSeen = true;
          }
          render();
        });
        input.focus();
        render();
      </script>
    </body>
    </html>
    """

    static let resizeFixture = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>OWL LayerHost resize fixture</title>
      <style>
        html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: rgb(248,248,248); }
        body { font: 30px -apple-system, BlinkMacSystemFont, sans-serif; color: rgb(20,20,20); }
        .edge {
          position: fixed;
          z-index: 9999;
          pointer-events: none;
        }
        #edgeTop {
          left: 0;
          top: 0;
          right: 0;
          height: 18px;
          background: rgb(255, 0, 0);
        }
        #edgeRight {
          right: 0;
          top: 0;
          bottom: 0;
          width: 18px;
          background: rgb(0, 204, 82);
        }
        #edgeBottom {
          left: 0;
          right: 0;
          bottom: 0;
          height: 18px;
          background: rgb(0, 89, 255);
        }
        #edgeLeft {
          left: 0;
          top: 0;
          bottom: 0;
          width: 18px;
          background: rgb(255, 210, 0);
        }
        #frame {
          position: absolute;
          left: 32px;
          top: 32px;
          right: 32px;
          bottom: 32px;
          border: 6px solid rgb(20,20,20);
          background: rgb(248,248,248);
          box-sizing: border-box;
        }
        #banner {
          position: absolute;
          left: 64px;
          top: 56px;
          right: 64px;
          height: 64px;
          background: rgb(0, 89, 255);
          color: white;
          display: flex;
          align-items: center;
          padding-left: 22px;
          box-sizing: border-box;
          font-weight: 900;
        }
        #size {
          position: absolute;
          left: 64px;
          top: 150px;
          width: 390px;
          height: 82px;
          border: 4px solid rgb(20,20,20);
          background: white;
          display: flex;
          align-items: center;
          padding-left: 22px;
          box-sizing: border-box;
          font-size: 40px;
          font-weight: 900;
        }
        #status {
          position: absolute;
          left: 64px;
          top: 260px;
          right: 64px;
          height: 94px;
          border: 4px solid rgb(20,20,20);
          background: rgb(238,238,238);
          display: flex;
          align-items: center;
          padding-left: 22px;
          box-sizing: border-box;
          font-size: 44px;
          font-weight: 900;
        }
        #marker {
          position: absolute;
          left: 64px;
          right: 64px;
          bottom: 58px;
          height: 92px;
          border: 4px solid rgb(20,20,20);
          background: white;
          display: flex;
          align-items: center;
          padding-left: 22px;
          box-sizing: border-box;
          font-weight: 900;
        }
        body.small #banner,
        body.restored #banner,
        body.small #status,
        body.restored #status {
          background: rgb(0, 204, 82);
        }
        body.small #size,
        body.restored #marker {
          background: rgb(255, 210, 0);
        }
        body.restored #size,
        body.small #marker {
          background: rgb(255, 210, 0);
        }
      </style>
    </head>
    <body>
      <div id="edgeTop" class="edge"></div>
      <div id="edgeRight" class="edge"></div>
      <div id="edgeBottom" class="edge"></div>
      <div id="edgeLeft" class="edge"></div>
      <div id="frame"></div>
      <div id="banner">OWL_RESIZE_READY</div>
      <div id="size">0 x 0</div>
      <div id="status">OWL_RESIZE_WAITING</div>
      <div id="marker">edge marker tracks viewport</div>
      <script>
        const size = document.getElementById("size");
        const status = document.getElementById("status");
        const banner = document.getElementById("banner");
        const marker = document.getElementById("marker");
        const state = {
          sawSmall: false
        };

        const update = () => {
          const width = window.innerWidth;
          const height = window.innerHeight;
          let mode = "initial";
          let label = "OWL_RESIZE_READY";
          if (width <= 760 && height <= 540) {
            mode = "small";
            label = "OWL_RESIZE_SMALL_OK";
            state.sawSmall = true;
          } else if (state.sawSmall && width >= 900 && height >= 600) {
            mode = "restored";
            label = "OWL_RESIZE_ROUNDTRIP_OK";
          }
          document.body.className = mode;
          size.textContent = `${width} x ${height}`;
          status.textContent = label;
          banner.textContent = label;
          marker.textContent = `mode: ${mode}`;
          window.owlResizeState = { width, height, mode, status: label, sawSmall: state.sawSmall };
        };

        let lastWidth = 0;
        let lastHeight = 0;
        const tick = () => {
          if (window.innerWidth !== lastWidth || window.innerHeight !== lastHeight) {
            lastWidth = window.innerWidth;
            lastHeight = window.innerHeight;
            update();
          }
          requestAnimationFrame(tick);
        };

        window.addEventListener("resize", update);
        update();
        setInterval(update, 50);
        requestAnimationFrame(tick);
      </script>
    </body>
    </html>
    """

    static let scrollFixture = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>OWL LayerHost scroll fixture</title>
      <style>
        html, body { margin: 0; width: 100%; min-height: 2500px; background: rgb(248,248,248); }
        body { font: 30px -apple-system, BlinkMacSystemFont, sans-serif; color: rgb(20,20,20); }
        #header {
          position: sticky;
          left: 48px;
          top: 0;
          margin-left: 48px;
          margin-top: 0;
          width: 864px;
          height: 82px;
          border: 4px solid rgb(20,20,20);
          background: rgb(0, 89, 255);
          color: white;
          display: flex;
          align-items: center;
          padding-left: 24px;
          box-sizing: border-box;
          font-size: 42px;
          font-weight: 900;
          z-index: 3;
        }
        #status {
          position: sticky;
          left: 48px;
          top: 82px;
          margin-left: 48px;
          width: 864px;
          height: 84px;
          border: 4px solid rgb(20,20,20);
          background: rgb(238,238,238);
          display: flex;
          align-items: center;
          padding-left: 24px;
          box-sizing: border-box;
          font-size: 42px;
          font-weight: 900;
          z-index: 3;
        }
        #after {
          position: sticky;
          left: 48px;
          top: 166px;
          margin-left: 48px;
          width: 864px;
          height: 94px;
          border: 4px solid rgb(20,20,20);
          background: white;
          display: flex;
          align-items: center;
          padding-left: 24px;
          box-sizing: border-box;
          font-weight: 900;
          z-index: 3;
        }
        #lines {
          margin-left: 48px;
          margin-top: 170px;
          width: 864px;
        }
        .line {
          height: 144px;
          border: 4px solid rgb(20,20,20);
          background: white;
          box-sizing: border-box;
          display: flex;
          align-items: center;
          padding-left: 24px;
          margin-bottom: 16px;
          font-weight: 900;
        }
        .line:nth-child(even) {
          background: rgb(238,238,238);
        }
        .line.current {
          background: rgb(255, 210, 0);
        }
        body.scrolled #header,
        body.scrolled #status {
          background: rgb(0, 204, 82);
          color: rgb(20,20,20);
        }
        body.scrolled #after {
          background: rgb(255, 210, 0);
        }
      </style>
    </head>
    <body>
      <div id="header">OWL_SCROLL_LINE_READY</div>
      <div id="status">OWL_SCROLL_TOP</div>
      <div id="after">scroll delta not seen</div>
      <div id="lines"></div>
      <script>
        const header = document.getElementById("header");
        const status = document.getElementById("status");
        const after = document.getElementById("after");
        const lines = document.getElementById("lines");
        const lineCount = 14;
        for (let index = 1; index <= lineCount; index++) {
          const line = document.createElement("div");
          const label = `LINE_${String(index).padStart(2, "0")}`;
          line.id = label;
          line.className = "line";
          line.textContent = `${label} content row ${index}: distinct scroll payload`;
          lines.appendChild(line);
        }

        const update = () => {
          const y = Math.round(window.scrollY);
          const firstVisibleIndex = Math.max(1, Math.min(lineCount, Math.floor(y / 160) + 1));
          const firstVisibleLine = `LINE_${String(firstVisibleIndex).padStart(2, "0")}`;
          const ok = y >= 850 && firstVisibleLine === "LINE_06";
          for (const line of document.querySelectorAll(".line")) {
            line.classList.toggle("current", line.id === firstVisibleLine);
          }
          document.body.classList.toggle("scrolled", ok);
          header.textContent = ok ? "OWL_SCROLL_LINE_OK" : "OWL_SCROLL_LINE_READY";
          status.textContent = ok ? "OWL_SCROLL_LINE_OK" : "OWL_SCROLL_TOP";
          after.textContent = `scrollY: ${y} first visible: ${firstVisibleLine}`;
          window.owlScrollState = { y, firstVisibleLine, ok };
        };

        window.addEventListener("scroll", update);
        update();
      </script>
    </body>
    </html>
    """

    static let textEditingFixture = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>OWL LayerHost text and selection fixture</title>
      <style>
        html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: rgb(248,248,248); }
        body { font: 26px -apple-system, BlinkMacSystemFont, sans-serif; color: rgb(20,20,20); }
        #banner {
          position: absolute;
          left: 48px;
          top: 32px;
          width: 864px;
          height: 54px;
          background: rgb(0, 89, 255);
          color: white;
          display: flex;
          align-items: center;
          padding-left: 22px;
          box-sizing: border-box;
          font-weight: 800;
        }
        input {
          position: absolute;
          left: 48px;
          width: 500px;
          height: 58px;
          box-sizing: border-box;
          border: 4px solid rgb(20,20,20);
          border-radius: 0;
          font: 30px -apple-system, BlinkMacSystemFont, sans-serif;
          padding: 0 16px;
          color: rgb(20,20,20);
          background: white;
        }
        #editInput { top: 122px; }
        #selectionInput { top: 342px; }
        .value {
          position: absolute;
          left: 576px;
          width: 336px;
          height: 42px;
          font-weight: 900;
        }
        #value { top: 132px; }
        #range { top: 352px; }
        .steps {
          position: absolute;
          left: 48px;
          width: 864px;
          display: grid;
          grid-template-columns: repeat(3, 1fr);
          gap: 12px;
        }
        #editSteps { top: 198px; }
        #selectionSteps { top: 418px; }
        .step {
          height: 62px;
          box-sizing: border-box;
          border: 4px solid rgb(20,20,20);
          background: rgb(238,238,238);
          display: flex;
          align-items: center;
          justify-content: center;
          font-weight: 900;
        }
        .step.ok {
          background: rgb(255, 210, 0);
        }
        .sectionLabel {
          position: absolute;
          left: 48px;
          width: 864px;
          height: 24px;
          font-size: 22px;
          font-weight: 900;
        }
        #editLabel { top: 94px; }
        #selectionLabel { top: 310px; }
        #status {
          position: absolute;
          left: 48px;
          top: 488px;
          width: 864px;
          height: 62px;
          border: 4px solid rgb(20,20,20);
          background: rgb(238,238,238);
          display: flex;
          align-items: center;
          padding-left: 24px;
          box-sizing: border-box;
          font-size: 36px;
          font-weight: 900;
        }
        #result {
          position: absolute;
          left: 48px;
          top: 560px;
          width: 864px;
          height: 44px;
          border: 4px solid rgb(20,20,20);
          background: white;
          display: flex;
          align-items: center;
          padding-left: 24px;
          box-sizing: border-box;
          font-size: 26px;
          font-weight: 900;
        }
        body.done #status,
        body.done #result {
          background: rgb(0, 204, 82);
        }
      </style>
    </head>
    <body class="ready">
      <div id="banner">OWL_TEXT_SELECTION_READY</div>
      <div id="editLabel" class="sectionLabel">caret editing</div>
      <input id="editInput" aria-label="OWL text editing input" autocomplete="off" spellcheck="false" autofocus>
      <div id="value" class="value">edit: EMPTY</div>
      <div id="editSteps" class="steps">
        <div id="step-type" class="step">TYPE</div>
        <div id="step-edit" class="step">EDIT</div>
        <div id="step-insert" class="step">INSERT</div>
      </div>
      <div id="selectionLabel" class="sectionLabel">selection replacement</div>
      <input id="selectionInput" aria-label="OWL selection input" autocomplete="off" spellcheck="false">
      <div id="range" class="value">range: 0-0</div>
      <div id="selectionSteps" class="steps">
        <div id="step-selection-type" class="step">TYPE</div>
        <div id="step-selection-range" class="step">RANGE</div>
        <div id="step-selection-replace" class="step">REPLACE</div>
      </div>
      <div id="status">OWL_TEXT_SELECTION_WAITING</div>
      <div id="result">values pending</div>
      <script>
        const editInput = document.getElementById("editInput");
        const selectionInput = document.getElementById("selectionInput");
        const value = document.getElementById("value");
        const range = document.getElementById("range");
        const status = document.getElementById("status");
        const result = document.getElementById("result");
        const state = {
          sawTyped: false,
          sawIntermediate: false,
          sawFinal: false,
          sawSelectionTyped: false,
          sawSelection: false,
          sawSelectionReplacement: false
        };
        window.owlTextEditState = state;

        const mark = (id, ok) => {
          document.getElementById(id).classList.toggle("ok", ok);
        };
        const render = () => {
          if (editInput.value === "abcdef") {
            state.sawTyped = true;
          }
          if (editInput.value === "abcZf") {
            state.sawIntermediate = true;
          }
          if (state.sawIntermediate && editInput.value === "abcZfinalf") {
            state.sawFinal = true;
          }

          const selectionStart = selectionInput.selectionStart ?? 0;
          const selectionEnd = selectionInput.selectionEnd ?? 0;
          if (selectionInput.value === "selection") {
            state.sawSelectionTyped = true;
          }
          if (selectionInput.value === "selection" && selectionStart === 6 && selectionEnd === 9) {
            state.sawSelection = true;
          }
          if (state.sawSelection && selectionInput.value === "selectXYZ") {
            state.sawSelectionReplacement = true;
          }

          value.textContent = "edit: " + (editInput.value || "EMPTY");
          range.textContent = `range: ${selectionStart}-${selectionEnd}`;
          result.textContent = `edit=${editInput.value || "EMPTY"} selection=${selectionInput.value || "EMPTY"}`;
          mark("step-type", state.sawTyped);
          mark("step-edit", state.sawIntermediate);
          mark("step-insert", state.sawFinal);
          mark("step-selection-type", state.sawSelectionTyped);
          mark("step-selection-range", state.sawSelection);
          mark("step-selection-replace", state.sawSelectionReplacement);
          if (state.sawFinal && state.sawSelectionReplacement) {
            document.body.classList.add("done");
            status.textContent = "OWL_TEXT_SELECTION_OK";
          }
        };

        editInput.addEventListener("input", render);
        selectionInput.addEventListener("input", render);
        selectionInput.addEventListener("keyup", render);
        selectionInput.addEventListener("select", render);
        document.addEventListener("selectionchange", render);
        editInput.focus();
        render();
      </script>
    </body>
    </html>
    """

    static let widgetFixture = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>OWL LayerHost widget fixture</title>
      <style>
        html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: rgb(248,248,248); }
        body { font: 26px -apple-system, BlinkMacSystemFont, sans-serif; color: rgb(20,20,20); }
        #banner {
          position: absolute;
          left: 48px;
          top: 34px;
          width: 864px;
          height: 58px;
          background: rgb(0, 89, 255);
          color: white;
          display: flex;
          align-items: center;
          padding-left: 22px;
          box-sizing: border-box;
          font-weight: 900;
        }
        label {
          position: absolute;
          left: 48px;
          font-weight: 900;
        }
        #selectLabel { top: 112px; }
        #contextLabel { top: 266px; }
        #colorLabel { top: 418px; }
        #nativeSelect {
          position: absolute;
          left: 48px;
          top: 142px;
          width: 360px;
          height: 112px;
          font: 28px -apple-system, BlinkMacSystemFont, sans-serif;
        }
        #selectState,
        #colorState {
          position: absolute;
          left: 360px;
          width: 520px;
          height: 58px;
          display: flex;
          align-items: center;
          font-weight: 900;
        }
        #selectState { top: 142px; }
        #colorState { top: 448px; }
        #contextZone {
          position: absolute;
          left: 48px;
          top: 296px;
          width: 864px;
          height: 88px;
          border: 4px solid rgb(20,20,20);
          box-sizing: border-box;
          background: white;
          display: flex;
          align-items: center;
          padding-left: 24px;
          font-weight: 900;
        }
        #colorInput {
          position: absolute;
          left: 48px;
          top: 448px;
          width: 250px;
          height: 58px;
        }
        #status {
          position: absolute;
          left: 48px;
          top: 540px;
          width: 864px;
          height: 70px;
          border: 4px solid rgb(20,20,20);
          box-sizing: border-box;
          background: rgb(238,238,238);
          display: flex;
          align-items: center;
          padding-left: 24px;
          font-size: 34px;
          font-weight: 900;
        }
        .ok {
          background: rgb(255, 210, 0) !important;
        }
        body.done #status {
          background: rgb(0, 204, 82);
        }
      </style>
    </head>
    <body>
      <div id="banner">OWL_WIDGETS_READY</div>
      <label id="selectLabel" for="nativeSelect">native select</label>
      <select id="nativeSelect" size="3">
        <option value="alpha">ALPHA_WIDGET_OPTION</option>
        <option value="beta">BETA_WIDGET_OPTION</option>
        <option value="gamma">GAMMA_WIDGET_OPTION</option>
      </select>
      <div id="selectState">select: alpha</div>
      <label id="contextLabel" for="contextZone">context menu target</label>
      <div id="contextZone">right click here</div>
      <label id="colorLabel" for="colorInput">color input</label>
      <input id="colorInput" type="color" value="#0059ff">
      <div id="colorState">color: not clicked</div>
      <div id="status">OWL_WIDGETS_WAITING</div>
      <script>
        const state = {
          ready: true,
          colorClicked: false,
          colorFocused: false,
          contextSeen: false
        };
        window.owlWidgetState = state;

        const select = document.getElementById("nativeSelect");
        const selectState = document.getElementById("selectState");
        const contextZone = document.getElementById("contextZone");
        const colorInput = document.getElementById("colorInput");
        const colorState = document.getElementById("colorState");
        const status = document.getElementById("status");

        const render = () => {
          selectState.textContent = "select: " + select.value;
          selectState.classList.toggle("ok", select.value === "beta");
          contextZone.textContent = state.contextSeen ? "OWL_CONTEXT_MENU_SEEN" : "right click here";
          contextZone.classList.toggle("ok", state.contextSeen);
          colorState.textContent = state.colorClicked ? "color input clicked and focused" : "color: not clicked";
          colorState.classList.toggle("ok", state.colorClicked && state.colorFocused);
          if (select.value === "beta" && state.contextSeen && state.colorClicked && state.colorFocused) {
            document.body.classList.add("done");
            status.textContent = "OWL_WIDGETS_OK";
          }
        };

        select.addEventListener("change", render);
        select.addEventListener("input", render);
        contextZone.addEventListener("contextmenu", (event) => {
          event.preventDefault();
          state.contextSeen = true;
          render();
        });
        colorInput.addEventListener("focus", () => {
          state.colorFocused = true;
          render();
        });
        colorInput.addEventListener("click", (event) => {
          event.preventDefault();
          state.colorClicked = true;
          state.colorFocused = true;
          colorInput.focus();
          render();
        });
        colorInput.addEventListener("input", render);
        render();
      </script>
    </body>
    </html>
    """

    static let nativePopupFixture = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>OWL LayerHost native popup fixture</title>
      <style>
        html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: rgb(248,248,248); }
        body { font: 26px -apple-system, BlinkMacSystemFont, sans-serif; color: rgb(20,20,20); }
        #banner {
          position: absolute;
          left: 48px;
          top: 34px;
          width: 864px;
          height: 58px;
          background: rgb(0, 89, 255);
          color: white;
          display: flex;
          align-items: center;
          padding-left: 22px;
          box-sizing: border-box;
          font-weight: 900;
        }
        label {
          position: absolute;
          left: 48px;
          font-weight: 900;
        }
        #selectLabel { top: 112px; }
        #contextLabel { top: 266px; }
        #nativeSelect {
          position: absolute;
          left: 48px;
          top: 142px;
          width: 280px;
          height: 56px;
          box-sizing: border-box;
          border: 4px solid rgb(20,20,20);
          border-radius: 0;
          background: white;
          color: rgb(20,20,20);
          font: 24px -apple-system, BlinkMacSystemFont, sans-serif;
          font-weight: 900;
        }
        #selectState {
          position: absolute;
          left: 440px;
          top: 142px;
          width: 520px;
          height: 58px;
          display: flex;
          align-items: center;
          font-weight: 900;
        }
        #contextZone {
          position: absolute;
          left: 48px;
          top: 296px;
          width: 864px;
          height: 88px;
          border: 4px solid rgb(20,20,20);
          box-sizing: border-box;
          background: white;
          display: flex;
          align-items: center;
          padding-left: 24px;
          font-weight: 900;
        }
        #status {
          position: absolute;
          left: 48px;
          top: 540px;
          width: 864px;
          height: 70px;
          border: 4px solid rgb(20,20,20);
          box-sizing: border-box;
          background: rgb(238,238,238);
          display: flex;
          align-items: center;
          padding-left: 24px;
          font-size: 34px;
          font-weight: 900;
        }
        .ok {
          background: rgb(255, 210, 0) !important;
        }
        body.done #status {
          background: rgb(0, 204, 82);
        }
      </style>
    </head>
    <body>
      <div id="banner">OWL_NATIVE_POPUPS_READY</div>
      <label id="selectLabel" for="nativeSelect">collapsed select</label>
      <select id="nativeSelect">
        <option value="alpha">ALPHA_NATIVE_OPTION</option>
        <option value="beta">BETA_NATIVE_OPTION</option>
        <option value="gamma">GAMMA_NATIVE_OPTION</option>
      </select>
      <div id="selectState">select: alpha</div>
      <label id="contextLabel" for="contextZone">context menu target</label>
      <div id="contextZone">right click here</div>
      <div id="status">OWL_NATIVE_POPUPS_WAITING</div>
      <script>
        const state = {
          ready: true,
          contextSeen: false
        };
        window.owlNativePopupState = state;

        const select = document.getElementById("nativeSelect");
        const selectState = document.getElementById("selectState");
        const contextZone = document.getElementById("contextZone");
        const status = document.getElementById("status");

        const render = () => {
          selectState.textContent = "select: " + select.value;
          selectState.classList.toggle("ok", select.value === "beta");
          contextZone.textContent = state.contextSeen ? "OWL_CONTEXT_MENU_SEEN" : "right click here";
          contextZone.classList.toggle("ok", state.contextSeen);
          if (select.value === "beta" && state.contextSeen) {
            document.body.classList.add("done");
            status.textContent = "OWL_NATIVE_POPUPS_OK";
          }
        };

        select.addEventListener("change", render);
        select.addEventListener("input", render);
        contextZone.addEventListener("contextmenu", () => {
          state.contextSeen = true;
          render();
        });
        render();
      </script>
    </body>
    </html>
    """

    static let plainNativeSelectFixture = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Plain native select</title>
      <style>
        html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: white; }
        body { font: 26px -apple-system, BlinkMacSystemFont, sans-serif; color: rgb(20,20,20); }
        #banner {
          position: absolute;
          left: 48px;
          top: 34px;
          width: 864px;
          height: 58px;
          background: rgb(0, 89, 255);
          color: white;
          display: flex;
          align-items: center;
          padding-left: 22px;
          box-sizing: border-box;
          font-weight: 900;
        }
        #selectLabel {
          position: absolute;
          left: 48px;
          top: 112px;
          font-weight: 900;
        }
        #selectMount {
          position: absolute;
          left: 48px;
          top: 146px;
        }
        #selectState {
          position: absolute;
          left: 48px;
          top: 224px;
          width: 864px;
          height: 70px;
          border: 4px solid rgb(20,20,20);
          box-sizing: border-box;
          background: rgb(238,238,238);
          display: flex;
          align-items: center;
          padding-left: 24px;
          font-weight: 900;
        }
        body.done #selectState {
          background: rgb(0, 204, 82);
        }
      </style>
    </head>
    <body>
      <div id="banner">PLAIN_NATIVE_SELECT_READY</div>
      <label id="selectLabel" for="plainSelect">browser default select, no select CSS</label>
      <div id="selectMount">
        <select id="plainSelect">
          <option value="alpha">Alpha native option</option>
          <option value="beta">Beta native option</option>
          <option value="gamma">Gamma native option</option>
        </select>
      </div>
      <div id="selectState">select: alpha</div>
        <script>
          window.owlPlainNativeSelectState = { ready: true, changed: false };
          const select = document.getElementById("plainSelect");
          const selectState = document.getElementById("selectState");
          const render = () => {
            selectState.textContent = "select: " + select.value;
            if (select.value === "beta") {
              window.owlPlainNativeSelectState.changed = true;
              document.body.classList.add("done");
            }
          };
          select.addEventListener("change", render);
          select.addEventListener("input", render);
          render();
        </script>
    </body>
    </html>
    """

    static let filePickerFixture = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>OWL native file picker fixture</title>
      <style>
        html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: rgb(248,248,248); }
        body { font: 28px -apple-system, BlinkMacSystemFont, sans-serif; color: rgb(20,20,20); }
        #banner {
          position: absolute;
          left: 48px;
          top: 40px;
          width: 864px;
          height: 58px;
          background: rgb(0, 89, 255);
          color: white;
          display: flex;
          align-items: center;
          padding-left: 22px;
          box-sizing: border-box;
          font-weight: 900;
        }
        #fileLabel {
          position: absolute;
          left: 48px;
          top: 124px;
          font-weight: 900;
        }
        #fileInput {
          position: absolute;
          left: 48px;
          top: 152px;
          width: 460px;
          height: 42px;
          font: 20px -apple-system, BlinkMacSystemFont, sans-serif;
        }
        #status {
          position: absolute;
          left: 48px;
          top: 258px;
          width: 864px;
          height: 92px;
          border: 4px solid rgb(20,20,20);
          box-sizing: border-box;
          background: rgb(255, 210, 0);
          display: flex;
          align-items: center;
          padding-left: 24px;
          font-size: 36px;
          font-weight: 900;
        }
        #details {
          position: absolute;
          left: 48px;
          top: 388px;
          width: 864px;
          height: 120px;
          border: 4px solid rgb(20,20,20);
          box-sizing: border-box;
          background: white;
          padding: 18px 24px;
          font-weight: 800;
        }
        body.ready #status {
          background: rgb(255, 210, 0);
        }
        body.canceled #status,
        body.selected #status {
          background: rgb(0, 204, 82);
        }
      </style>
    </head>
    <body class="ready">
      <div id="banner">OWL_FILE_PICKER_READY</div>
      <label id="fileLabel" for="fileInput">native file picker</label>
      <input id="fileInput" type="file" accept=".txt,text/plain">
      <div id="status">OWL_FILE_PICKER_WAITING</div>
      <div id="details">accept: .txt, text/plain<br>selection: empty</div>
      <script>
        const input = document.getElementById("fileInput");
        const status = document.getElementById("status");
        const details = document.getElementById("details");
        const state = {
          ready: true,
          cancelSeen: false,
          changeSeen: false
        };
        window.owlFilePickerState = state;

        input.addEventListener("click", () => {
          status.textContent = "OWL_FILE_PICKER_OPENING";
        });
        input.addEventListener("cancel", () => {
          state.cancelSeen = true;
          document.body.classList.add("canceled");
          status.textContent = "OWL_FILE_PICKER_CANCELED";
          details.textContent = "selection: canceled, files=" + input.files.length;
        });
        input.addEventListener("change", () => {
          state.changeSeen = true;
          document.body.classList.add("selected");
          status.textContent = "OWL_FILE_PICKER_SELECTED";
          details.textContent = "selection changed, files=" + input.files.length;
        });
      </script>
    </body>
    </html>
    """

    static let devToolsFixture = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>OWL DevTools Fixture</title>
      <style>
        html, body {
          margin: 0;
          width: 100%;
          height: 100%;
          overflow: hidden;
          background: rgb(248,248,248);
        }
        body {
          color: rgb(20,20,20);
          font: 18px -apple-system, BlinkMacSystemFont, sans-serif;
        }
        #viewport {
          position: absolute;
          inset: 18px;
          border: 10px solid rgb(20,20,20);
          box-sizing: border-box;
          background:
            linear-gradient(90deg, rgba(0, 92, 230, 0.16), rgba(255,255,255,0) 38%),
            rgb(255, 255, 255);
        }
        #banner {
          position: absolute;
          left: 36px;
          top: 32px;
          right: 36px;
          min-height: 54px;
          background: rgb(0, 92, 230);
          color: white;
          display: flex;
          align-items: center;
          padding: 8px 18px;
          box-sizing: border-box;
          font-size: 26px;
          font-weight: 900;
        }
        #dimensions {
          position: absolute;
          left: 36px;
          top: 110px;
          right: 36px;
          height: 80px;
          border: 6px solid rgb(20,20,20);
          box-sizing: border-box;
          background: rgb(255, 210, 0);
          display: flex;
          align-items: center;
          padding-left: 18px;
          font-size: 28px;
          font-weight: 900;
        }
        #target {
          position: absolute;
          left: 36px;
          top: 224px;
          right: 36px;
          bottom: 36px;
          min-height: 90px;
          border: 6px solid rgb(20,20,20);
          box-sizing: border-box;
          background: rgb(255, 255, 255);
          padding: 18px;
          font-size: 22px;
          font-weight: 800;
        }
        #resizeLog {
          position: absolute;
          right: 16px;
          bottom: 12px;
          font-size: 18px;
          font-weight: 900;
        }
      </style>
    </head>
    <body>
      <div id="viewport">
        <div id="banner">OWL_DEVTOOLS_PAGE_READY</div>
        <div id="dimensions">size: pending</div>
        <div id="target">DevTools should dock beside this bordered page without covering it.</div>
        <div id="resizeLog">resizes: 0</div>
      </div>
      <script>
        const dimensions = document.getElementById("dimensions");
        const resizeLog = document.getElementById("resizeLog");
        const state = {
          ready: true,
          resizeCount: 0,
          bounds: null,
          measure() {
            this.bounds = {
              innerWidth: window.innerWidth,
              innerHeight: window.innerHeight,
              size: `${window.innerWidth}x${window.innerHeight}`,
              devicePixelRatio: window.devicePixelRatio
            };
            dimensions.textContent = `size: ${this.bounds.size}`;
            resizeLog.textContent = `resizes: ${this.resizeCount}`;
            return this.bounds;
          }
        };
        window.owlDevToolsFixture = state;
        window.addEventListener("resize", () => {
          state.resizeCount += 1;
          state.measure();
        });
        state.measure();
      </script>
    </body>
    </html>
    """
}
