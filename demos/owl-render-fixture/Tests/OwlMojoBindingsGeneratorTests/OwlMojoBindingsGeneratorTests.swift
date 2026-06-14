import XCTest
import OwlMojoBindingsGenerated
@testable import OwlMojoBindingsGeneratorCore

final class OwlMojoBindingsGeneratorTests: XCTestCase {
    func testParserReadsEnumsStructsAndInterfaces() throws {
        let file = try MojoParser.parse(source: sampleMojo)

        XCTAssertEqual(file.module, "content.mojom")
        XCTAssertEqual(file.declarations.count, 5)

        guard case .enumeration(let mouseKind) = file.declarations[0] else {
            return XCTFail("expected enum")
        }
        XCTAssertEqual(mouseKind.name, "OwlFreshMouseKind")
        XCTAssertEqual(mouseKind.cases.map(\.name), ["kDown", "kWheel"])
        XCTAssertEqual(mouseKind.cases.map(\.rawValue), [0, 3])

        guard case .structure(let event) = file.declarations[1] else {
            return XCTFail("expected struct")
        }
        XCTAssertEqual(event.fields.map(\.name), ["kind", "delta_x"])
        XCTAssertEqual(event.fields.map { $0.type.swiftName }, ["OwlFreshMouseKind", "Float"])

        guard case .interface(let session) = file.declarations[2] else {
            return XCTFail("expected interface")
        }
        XCTAssertEqual(session.name, "OwlFreshSession")
        XCTAssertEqual(session.methods.map(\.name), ["BindWebView", "BindInput", "Flush"])
        XCTAssertEqual(session.methods[0].parameters.map(\.name), ["web_view"])
        XCTAssertEqual(session.methods[0].parameters.first?.type.mojoName, "pending_receiver<OwlFreshWebView>")
        XCTAssertEqual(session.methods[0].parameters.first?.type.swiftName, "OwlFreshWebViewReceiver")
        XCTAssertEqual(session.methods[2].responseParameters.map(\.name), ["ok"])

        guard case .interface(let webView) = file.declarations[3] else {
            return XCTFail("expected web view interface")
        }
        XCTAssertEqual(webView.methods.map(\.name), ["Navigate", "Resize"])
        XCTAssertEqual(webView.methods[1].parameters.map(\.name), ["width", "height", "scale"])
    }

    func testGeneratorEmitsSwiftTypesAndSchemaChecksum() throws {
        let file = try MojoParser.parse(source: sampleMojo)
        let result = MojoSwiftGenerator.generate(file: file, source: sampleMojo)

        XCTAssertTrue(result.swift.contains("public enum OwlFreshMouseKind: UInt32"))
        XCTAssertTrue(result.swift.contains("case down = 0"))
        XCTAssertTrue(result.swift.contains("public struct OwlFreshMouseEvent"))
        XCTAssertTrue(result.swift.contains("public let deltaX: Float"))
        XCTAssertTrue(result.swift.contains("public struct MojoPendingReceiver<Interface>"))
        XCTAssertTrue(result.swift.contains("public final class OwlFreshMojoPipeHandleAllocator"))
        XCTAssertTrue(result.swift.contains("public typealias OwlFreshWebViewReceiver"))
        XCTAssertTrue(result.swift.contains("public struct OwlFreshWebViewResizeRequest"))
        XCTAssertTrue(result.swift.contains("func resize(_ request: OwlFreshWebViewResizeRequest)"))
        XCTAssertTrue(result.swift.contains("public final class GeneratedOwlFreshSessionMojoTransport"))
        XCTAssertTrue(result.swift.contains("public final class GeneratedOwlFreshWebViewMojoTransport"))
        XCTAssertTrue(result.swift.contains("public final class OwlFreshMojoTransportRecorder"))
        XCTAssertTrue(result.swift.contains("public protocol OwlFreshMojoPipeBindings"))
        XCTAssertTrue(result.swift.contains("public final class GeneratedOwlFreshMojoPipeBoundSinks"))
        XCTAssertTrue(result.swift.contains("public static let sourceChecksum = \"\(result.checksum)\""))
    }

    func testReportShowsPassStatusAndGeneratedDeclarations() throws {
        let file = try MojoParser.parse(source: sampleMojo)
        let result = MojoSwiftGenerator.generate(file: file, source: sampleMojo)
        let report = BindingsReportRenderer.render(
            file: file,
            result: result,
            status: .passed,
            mojomPath: "Mojo/OwlFresh.mojom",
            swiftPath: "Sources/OwlLayerHostVerifier/OwlFresh.generated.swift"
        )

        XCTAssertTrue(report.contains("PASS"))
        XCTAssertTrue(report.contains("OwlFreshMouseKind"))
        XCTAssertTrue(report.contains(result.checksum))
        XCTAssertTrue(report.contains("protocol OwlFreshSessionMojoInterface"))
        XCTAssertTrue(report.contains("pending_receiver&lt;OwlFreshWebView&gt; web_view -&gt; OwlFreshWebViewReceiver webView"))
    }

    func testGeneratedTransportsShareRecorderAndForwardCalls() async throws {
        let sink = FakeOwlFreshSink()
        let recorder = OwlFreshMojoTransportRecorder()
        let session = GeneratedOwlFreshSessionMojoTransport(sink: sink, recorder: recorder)
        let webView = GeneratedOwlFreshWebViewMojoTransport(sink: sink, recorder: recorder)
        let input = GeneratedOwlFreshInputMojoTransport(sink: sink, recorder: recorder)
        let surfaceTree = GeneratedOwlFreshSurfaceTreeHostMojoTransport(sink: sink, recorder: recorder)
        let nativeSurface = GeneratedOwlFreshNativeSurfaceHostMojoTransport(sink: sink, recorder: recorder)
        let devTools = GeneratedOwlFreshDevToolsHostMojoTransport(sink: sink, recorder: recorder)

        session.bindWebView(OwlFreshWebViewReceiver(handle: 10))
        webView.navigate("https://example.com/")
        webView.resize(OwlFreshWebViewResizeRequest(width: 960, height: 640, scale: 1.0))
        input.sendMouse(OwlFreshMouseEvent(
            kind: .wheel,
            x: 520,
            y: 520,
            button: 0,
            clickCount: 0,
            deltaX: 0,
            deltaY: -900,
            modifiers: 0
        ))
        input.sendKey(OwlFreshKeyEvent(keyDown: true, keyCode: 83, text: "S", modifiers: 1))
        let flushed = try await session.flush()
        let tree = try await surfaceTree.getSurfaceTree()
        let accepted = try await nativeSurface.acceptActivePopupMenuItem(1)
        let canceled = try await nativeSurface.cancelActivePopup()
        let fileSelected = try await nativeSurface.selectActiveFilePickerFiles(["/tmp/owl.txt"])
        let fileCanceled = try await nativeSurface.cancelActiveFilePicker()
        let devToolsOpened = try await devTools.openDevTools(.bottom)
        let devToolsResult = try await devTools.evaluateDevToolsJavaScript("window.owlDevTools")
        let devToolsClosed = try await devTools.closeDevTools()

        XCTAssertTrue(flushed)
        XCTAssertEqual(tree.generation, 7)
        XCTAssertTrue(accepted)
        XCTAssertTrue(canceled)
        XCTAssertTrue(fileSelected)
        XCTAssertTrue(fileCanceled)
        XCTAssertTrue(devToolsOpened)
        XCTAssertEqual(devToolsResult, "{\"proof\":true}")
        XCTAssertTrue(devToolsClosed)
        XCTAssertEqual(sink.calls, [
            "bindWebView",
            "navigate",
            "resize",
            "sendMouse",
            "sendKey",
            "flush",
            "getSurfaceTree",
            "acceptActivePopupMenuItem",
            "cancelActivePopup",
            "selectActiveFilePickerFiles",
            "cancelActiveFilePicker",
            "openDevTools",
            "evaluateDevToolsJavaScript",
            "closeDevTools",
        ])
        XCTAssertEqual(session.recordedCalls.map(\.method), [
            "bindWebView",
            "navigate",
            "resize",
            "sendMouse",
            "sendKey",
            "flush",
            "getSurfaceTree",
            "acceptActivePopupMenuItem",
            "cancelActivePopup",
            "selectActiveFilePickerFiles",
            "cancelActiveFilePicker",
            "openDevTools",
            "evaluateDevToolsJavaScript",
            "closeDevTools",
        ])
        XCTAssertEqual(session.recordedCalls.map(\.interface), [
            "OwlFreshSession",
            "OwlFreshWebView",
            "OwlFreshWebView",
            "OwlFreshInput",
            "OwlFreshInput",
            "OwlFreshSession",
            "OwlFreshSurfaceTreeHost",
            "OwlFreshNativeSurfaceHost",
            "OwlFreshNativeSurfaceHost",
            "OwlFreshNativeSurfaceHost",
            "OwlFreshNativeSurfaceHost",
            "OwlFreshDevToolsHost",
            "OwlFreshDevToolsHost",
            "OwlFreshDevToolsHost",
        ])
        XCTAssertEqual(webView.recordedCalls, session.recordedCalls)
        XCTAssertEqual(session.recordedCalls[0].payloadType, "OwlFreshWebViewReceiver")
        XCTAssertEqual(session.recordedCalls[2].payloadType, "OwlFreshWebViewResizeRequest")
        XCTAssertEqual(session.recordedCalls[3].payloadType, "OwlFreshMouseEvent")
        XCTAssertTrue(session.recordedCalls[4].payloadSummary.contains("keyCode: 83"))
        XCTAssertEqual(session.recordedCalls[5].payloadType, "Void")
        XCTAssertEqual(session.recordedCalls[6].payloadType, "Void")
        XCTAssertEqual(session.recordedCalls[7].payloadType, "UInt32")
        XCTAssertEqual(session.recordedCalls[9].payloadType, "[String]")
        XCTAssertEqual(session.recordedCalls[11].payloadType, "OwlFreshDevToolsMode")
        XCTAssertEqual(session.recordedCalls[12].payloadType, "String")
    }

    func testGeneratedPipeBoundSinksForwardTypedCalls() async throws {
        let pipe = FakePipeBindings()
        let recorder = OwlFreshMojoTransportRecorder()
        let allocator = OwlFreshMojoPipeHandleAllocator()
        let sinks = GeneratedOwlFreshMojoPipeBoundSinks(session: nil, pipe: pipe)
        let session = GeneratedOwlFreshSessionMojoTransport(sink: sinks, recorder: recorder)
        let webView = GeneratedOwlFreshWebViewMojoTransport(sink: sinks, recorder: recorder)
        let input = GeneratedOwlFreshInputMojoTransport(sink: sinks, recorder: recorder)
        let surfaceTree = GeneratedOwlFreshSurfaceTreeHostMojoTransport(sink: sinks, recorder: recorder)
        let nativeSurface = GeneratedOwlFreshNativeSurfaceHostMojoTransport(sink: sinks, recorder: recorder)
        let devTools = GeneratedOwlFreshDevToolsHostMojoTransport(sink: sinks, recorder: recorder)

        let profile: OwlFreshProfileReceiver = allocator.makeReceiver(OwlFreshProfileMojoInterfaceMarker.self)
        let webViewReceiver: OwlFreshWebViewReceiver = allocator.makeReceiver(OwlFreshWebViewMojoInterfaceMarker.self)
        let inputReceiver: OwlFreshInputReceiver = allocator.makeReceiver(OwlFreshInputMojoInterfaceMarker.self)
        let surfaceTreeReceiver: OwlFreshSurfaceTreeHostReceiver = allocator.makeReceiver(OwlFreshSurfaceTreeHostMojoInterfaceMarker.self)
        let nativeSurfaceHost: OwlFreshNativeSurfaceHostReceiver = allocator.makeReceiver(OwlFreshNativeSurfaceHostMojoInterfaceMarker.self)
        let devToolsHost: OwlFreshDevToolsHostReceiver = allocator.makeReceiver(OwlFreshDevToolsHostMojoInterfaceMarker.self)
        let client: OwlFreshClientRemote = allocator.makeRemote(OwlFreshClientMojoInterfaceMarker.self)

        session.bindProfile(profile)
        try sinks.throwIfFailed()
        session.bindWebView(webViewReceiver)
        try sinks.throwIfFailed()
        session.bindInput(inputReceiver)
        try sinks.throwIfFailed()
        session.bindSurfaceTree(surfaceTreeReceiver)
        try sinks.throwIfFailed()
        session.bindNativeSurfaceHost(nativeSurfaceHost)
        try sinks.throwIfFailed()
        session.bindDevToolsHost(devToolsHost)
        try sinks.throwIfFailed()
        session.setClient(client)
        try sinks.throwIfFailed()
        webView.navigate("https://example.com/")
        try sinks.throwIfFailed()
        webView.resize(OwlFreshWebViewResizeRequest(width: 640, height: 480, scale: 2.0))
        try sinks.throwIfFailed()
        input.sendKey(OwlFreshKeyEvent(keyDown: true, keyCode: 36, text: "\n", modifiers: 0))
        try sinks.throwIfFailed()
        let ok = try await session.flush()
        let tree = try await surfaceTree.getSurfaceTree()
        let accepted = try await nativeSurface.acceptActivePopupMenuItem(2)
        let selected = try await nativeSurface.selectActiveFilePickerFiles(["/tmp/owl.txt"])
        let devToolsOpened = try await devTools.openDevTools(.window)
        let devToolsResult = try await devTools.evaluateDevToolsJavaScript("window.owlDevTools")

        XCTAssertTrue(ok)
        XCTAssertEqual(tree.generation, 42)
        XCTAssertTrue(accepted)
        XCTAssertTrue(selected)
        XCTAssertTrue(devToolsOpened)
        XCTAssertEqual(devToolsResult, "{\"proof\":true}")
        XCTAssertEqual(
            [
                profile.handle,
                webViewReceiver.handle,
                inputReceiver.handle,
                surfaceTreeReceiver.handle,
                nativeSurfaceHost.handle,
                devToolsHost.handle,
                client.handle,
            ],
            [1, 2, 3, 4, 5, 6, 7]
        )
        XCTAssertEqual(pipe.calls, [
            "sessionBindProfile:1",
            "sessionBindWebView:2",
            "sessionBindInput:3",
            "sessionBindSurfaceTree:4",
            "sessionBindNativeSurfaceHost:5",
            "sessionBindDevToolsHost:6",
            "sessionSetClient:7",
            "webViewNavigate:https://example.com/",
            "webViewResize:640x480@2.0",
            "inputSendKey:36:\n",
            "sessionFlush",
            "surfaceTreeHostGetSurfaceTree",
            "nativeSurfaceHostAcceptActivePopupMenuItem:2",
            "nativeSurfaceHostSelectActiveFilePickerFiles:/tmp/owl.txt",
            "devToolsHostOpenDevTools:3",
            "devToolsHostEvaluateDevToolsJavaScript:window.owlDevTools",
        ])
        XCTAssertEqual(recorder.recordedCalls.map(\.interface), [
            "OwlFreshSession",
            "OwlFreshSession",
            "OwlFreshSession",
            "OwlFreshSession",
            "OwlFreshSession",
            "OwlFreshSession",
            "OwlFreshSession",
            "OwlFreshWebView",
            "OwlFreshWebView",
            "OwlFreshInput",
            "OwlFreshSession",
            "OwlFreshSurfaceTreeHost",
            "OwlFreshNativeSurfaceHost",
            "OwlFreshNativeSurfaceHost",
            "OwlFreshDevToolsHost",
            "OwlFreshDevToolsHost",
        ])
    }

    func testGeneratedSurfaceTreeDecodesWrappedUnsignedContextID() throws {
        let json = """
        {
          "generation": 1,
          "surfaces": [
            {
              "surfaceId": 2,
              "parentSurfaceId": 0,
              "kind": 0,
              "contextId": -603416498,
              "x": 0,
              "y": 0,
              "width": 960,
              "height": 640,
              "scale": 1,
              "zIndex": 0,
              "visible": true,
              "menuItems": [],
              "nativeMenuItems": [],
              "selectedIndex": -1,
              "itemFontSize": 0,
              "rightAligned": false,
              "filePickerMode": "",
              "filePickerAcceptTypes": [],
              "filePickerAllowsMultiple": false,
              "filePickerUploadFolder": false,
              "label": "web-view"
            }
          ]
        }
        """.data(using: .utf8)!

        let tree = try JSONDecoder().decode(OwlFreshSurfaceTree.self, from: json)

        XCTAssertEqual(tree.surfaces.first?.contextId, UInt32(bitPattern: Int32(-603_416_498)))
        XCTAssertEqual(tree.surfaces.first?.contextId, 3_691_550_798)
    }

    private let sampleMojo = """
    module content.mojom;

    enum OwlFreshMouseKind {
      kDown = 0,
      kWheel = 3,
    };

    struct OwlFreshMouseEvent {
      OwlFreshMouseKind kind;
      float delta_x;
    };

    interface OwlFreshSession {
      BindWebView(pending_receiver<OwlFreshWebView> web_view);
      BindInput(pending_receiver<OwlFreshInput> input);
      Flush() => (bool ok);
    };

    interface OwlFreshWebView {
      Navigate(string url);
      Resize(uint32 width, uint32 height, float scale);
    };

    interface OwlFreshInput {
      SendMouse(OwlFreshMouseEvent event);
    };
    """
}

private final class FakeOwlFreshSink:
    OwlFreshSessionMojoSink,
    OwlFreshProfileMojoSink,
    OwlFreshWebViewMojoSink,
    OwlFreshInputMojoSink,
    OwlFreshSurfaceTreeHostMojoSink,
    OwlFreshNativeSurfaceHostMojoSink,
    OwlFreshDevToolsHostMojoSink
{
    var calls: [String] = []

    func setClient(_ client: OwlFreshClientRemote) {
        calls.append("setClient")
    }

    func bindProfile(_ profile: OwlFreshProfileReceiver) {
        calls.append("bindProfile")
    }

    func bindWebView(_ webView: OwlFreshWebViewReceiver) {
        calls.append("bindWebView")
    }

    func bindInput(_ input: OwlFreshInputReceiver) {
        calls.append("bindInput")
    }

    func bindSurfaceTree(_ surfaceTree: OwlFreshSurfaceTreeHostReceiver) {
        calls.append("bindSurfaceTree")
    }

    func bindNativeSurfaceHost(_ nativeSurfaceHost: OwlFreshNativeSurfaceHostReceiver) {
        calls.append("bindNativeSurfaceHost")
    }

    func bindDevToolsHost(_ devtoolsHost: OwlFreshDevToolsHostReceiver) {
        calls.append("bindDevToolsHost")
    }

    func navigate(_ url: String) {
        calls.append("navigate")
    }

    func resize(_ request: OwlFreshWebViewResizeRequest) {
        calls.append("resize")
    }

    func setFocus(_ focused: Bool) {
        calls.append("setFocus")
    }

    func sendMouse(_ event: OwlFreshMouseEvent) {
        calls.append("sendMouse")
    }

    func sendKey(_ event: OwlFreshKeyEvent) {
        calls.append("sendKey")
    }

    func getPath() async throws -> String {
        calls.append("getPath")
        return "/tmp/owl-profile"
    }

    func flush() async throws -> Bool {
        calls.append("flush")
        return true
    }

    func captureSurface() async throws -> OwlFreshCaptureResult {
        calls.append("captureSurface")
        return OwlFreshCaptureResult(png: [], width: 0, height: 0, captureMode: "fake", error: "")
    }

    func getSurfaceTree() async throws -> OwlFreshSurfaceTree {
        calls.append("getSurfaceTree")
        return OwlFreshSurfaceTree(generation: 7, surfaces: [])
    }

    func acceptActivePopupMenuItem(_ index: UInt32) async throws -> Bool {
        calls.append("acceptActivePopupMenuItem")
        return index == 1
    }

    func cancelActivePopup() async throws -> Bool {
        calls.append("cancelActivePopup")
        return true
    }

    func selectActiveFilePickerFiles(_ paths: [String]) async throws -> Bool {
        calls.append("selectActiveFilePickerFiles")
        return paths.count == 1
    }

    func cancelActiveFilePicker() async throws -> Bool {
        calls.append("cancelActiveFilePicker")
        return true
    }

    func openDevTools(_ mode: OwlFreshDevToolsMode) async throws -> Bool {
        calls.append("openDevTools")
        return true
    }

    func closeDevTools() async throws -> Bool {
        calls.append("closeDevTools")
        return true
    }

    func evaluateDevToolsJavaScript(_ script: String) async throws -> String {
        calls.append("evaluateDevToolsJavaScript")
        return "{\"proof\":true}"
    }
}

private final class FakePipeBindings: OwlFreshMojoPipeBindings {
    var calls: [String] = []

    func sessionSetClient(_ session: OpaquePointer?, client: OwlFreshClientRemote) throws {
        calls.append("sessionSetClient:\(client.handle)")
    }

    func sessionBindProfile(_ session: OpaquePointer?, profile: OwlFreshProfileReceiver) throws {
        calls.append("sessionBindProfile:\(profile.handle)")
    }

    func sessionBindWebView(_ session: OpaquePointer?, webView: OwlFreshWebViewReceiver) throws {
        calls.append("sessionBindWebView:\(webView.handle)")
    }

    func sessionBindInput(_ session: OpaquePointer?, input: OwlFreshInputReceiver) throws {
        calls.append("sessionBindInput:\(input.handle)")
    }

    func sessionBindSurfaceTree(_ session: OpaquePointer?, surfaceTree: OwlFreshSurfaceTreeHostReceiver) throws {
        calls.append("sessionBindSurfaceTree:\(surfaceTree.handle)")
    }

    func sessionBindNativeSurfaceHost(_ session: OpaquePointer?, nativeSurfaceHost: OwlFreshNativeSurfaceHostReceiver) throws {
        calls.append("sessionBindNativeSurfaceHost:\(nativeSurfaceHost.handle)")
    }

    func sessionBindDevToolsHost(_ session: OpaquePointer?, devtoolsHost: OwlFreshDevToolsHostReceiver) throws {
        calls.append("sessionBindDevToolsHost:\(devtoolsHost.handle)")
    }

    func sessionFlush(_ session: OpaquePointer?) throws -> Bool {
        calls.append("sessionFlush")
        return true
    }

    func profileGetPath(_ session: OpaquePointer?) throws -> String {
        calls.append("profileGetPath")
        return "/tmp/owl-profile"
    }

    func webViewNavigate(_ session: OpaquePointer?, url: String) throws {
        calls.append("webViewNavigate:\(url)")
    }

    func webViewResize(_ session: OpaquePointer?, request: OwlFreshWebViewResizeRequest) throws {
        calls.append("webViewResize:\(request.width)x\(request.height)@\(request.scale)")
    }

    func webViewSetFocus(_ session: OpaquePointer?, focused: Bool) throws {
        calls.append("webViewSetFocus:\(focused)")
    }

    func inputSendMouse(_ session: OpaquePointer?, event: OwlFreshMouseEvent) throws {
        calls.append("inputSendMouse:\(event.kind.rawValue)")
    }

    func inputSendKey(_ session: OpaquePointer?, event: OwlFreshKeyEvent) throws {
        calls.append("inputSendKey:\(event.keyCode):\(event.text)")
    }

    func surfaceTreeHostCaptureSurface(_ session: OpaquePointer?) throws -> OwlFreshCaptureResult {
        calls.append("surfaceTreeHostCaptureSurface")
        return OwlFreshCaptureResult(png: [1, 2, 3], width: 1, height: 1, captureMode: "fake", error: "")
    }

    func surfaceTreeHostGetSurfaceTree(_ session: OpaquePointer?) throws -> OwlFreshSurfaceTree {
        calls.append("surfaceTreeHostGetSurfaceTree")
        return OwlFreshSurfaceTree(generation: 42, surfaces: [])
    }

    func nativeSurfaceHostAcceptActivePopupMenuItem(_ session: OpaquePointer?, index: UInt32) throws -> Bool {
        calls.append("nativeSurfaceHostAcceptActivePopupMenuItem:\(index)")
        return true
    }

    func nativeSurfaceHostCancelActivePopup(_ session: OpaquePointer?) throws -> Bool {
        calls.append("nativeSurfaceHostCancelActivePopup")
        return true
    }

    func nativeSurfaceHostSelectActiveFilePickerFiles(_ session: OpaquePointer?, paths: [String]) throws -> Bool {
        calls.append("nativeSurfaceHostSelectActiveFilePickerFiles:\(paths.joined(separator: ","))")
        return true
    }

    func nativeSurfaceHostCancelActiveFilePicker(_ session: OpaquePointer?) throws -> Bool {
        calls.append("nativeSurfaceHostCancelActiveFilePicker")
        return true
    }

    func devToolsHostOpenDevTools(_ session: OpaquePointer?, mode: OwlFreshDevToolsMode) throws -> Bool {
        calls.append("devToolsHostOpenDevTools:\(mode.rawValue)")
        return true
    }

    func devToolsHostCloseDevTools(_ session: OpaquePointer?) throws -> Bool {
        calls.append("devToolsHostCloseDevTools")
        return true
    }

    func devToolsHostEvaluateDevToolsJavaScript(_ session: OpaquePointer?, script: String) throws -> String {
        calls.append("devToolsHostEvaluateDevToolsJavaScript:\(script)")
        return "{\"proof\":true}"
    }
}
