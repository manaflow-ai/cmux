# Voice Input Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add voice input to cmux so the user can switch workspaces/tabs, dictate text into the terminal, and execute commands entirely by speaking.

**Architecture:** A native Swift `VoiceInputController` manages a WebSocket session with the OpenAI Realtime API. It captures audio via `AVAudioEngine`, streams PCM16 to the API, and dispatches incoming tool calls (`switch_workspace`, `switch_tab`, `type_text`, `execute_command`) through the existing `TabManager` and `TerminalPanel` infrastructure. No browser component is used.

**Tech Stack:** Swift / SwiftUI, `AVAudioEngine` (audio capture), `URLSessionWebSocketTask` (WebSocket), OpenAI Realtime API (WebSocket endpoint), macOS Keychain (`SecItem` APIs), `XCTest`

---

## File Map

| File | Role |
|------|------|
| `Sources/App/Voice/VoiceInputState.swift` | `@Observable` state model — activity, transcript |
| `Sources/App/Voice/VoiceKeychainStore.swift` | Read/write API key to macOS Keychain |
| `Sources/App/Voice/VoiceToolDefinitions.swift` | Tool JSON schemas + call protocol |
| `Sources/App/Voice/VoiceRealtimeTransport.swift` | WebSocket client to OpenAI Realtime API |
| `Sources/App/Voice/VoiceToolExecutor.swift` | Dispatches tool calls to TabManager / TerminalPanel |
| `Sources/App/Voice/VoiceInputController.swift` | Top-level coordinator: audio + session lifecycle |
| `Sources/App/Voice/VoiceSettingsView.swift` | SwiftUI settings view (API key, model, activation) |
| `cmuxTests/Voice/VoiceInputStateTests.swift` | Unit tests: state transitions |
| `cmuxTests/Voice/VoiceToolDefinitionsTests.swift` | Unit tests: schema generation |
| `cmuxTests/Voice/VoiceRealtimeTransportTests.swift` | Unit tests: message serialization / parsing |
| `Sources/SettingsNavigation.swift` | Add `.voice` case to `SettingsNavigationTarget` enum |
| `Sources/KeyboardShortcutSettings.swift` | Add `toggleVoiceInput` action to `Action` enum |
| `Sources/cmuxApp.swift` | Instantiate controller; add toolbar mic indicator |
| `Resources/Localizable.xcstrings` | New localized strings |

---

## Task 1: VoiceInputState — observable state model

**Files:**
- Create: `Sources/App/Voice/VoiceInputState.swift`
- Create: `cmuxTests/Voice/VoiceInputStateTests.swift`

- [ ] **Step 1: Write the failing test**

Create `cmuxTests/Voice/VoiceInputStateTests.swift`:

```swift
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class VoiceInputStateTests: XCTestCase {
    func testInitialStateIsIdle() {
        let state = VoiceInputState()
        XCTAssertFalse(state.isActive)
        XCTAssertEqual(state.activity, .idle)
        XCTAssertEqual(state.transcript, "")
    }

    func testSetActivityUpdatesValue() {
        let state = VoiceInputState()
        state.activity = .listening
        XCTAssertEqual(state.activity, .listening)
    }

    func testIsActiveReflectsNonIdleConnectedState() {
        let state = VoiceInputState()
        state.isActive = true
        XCTAssertTrue(state.isActive)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild -scheme cmux-unit -destination 'platform=macOS' -only-testing cmuxTests/Voice/VoiceInputStateTests 2>&1 | tail -20
```

Expected: compile error — `VoiceInputState` not defined.

- [ ] **Step 3: Create VoiceInputState.swift**

Create `Sources/App/Voice/VoiceInputState.swift`:

```swift
import Foundation
import Observation

enum VoiceActivity: Equatable {
    case idle
    case connecting
    case listening
    case processing
    case executing
    case error(String)
}

@Observable
final class VoiceInputState {
    var isActive: Bool = false
    var activity: VoiceActivity = .idle
    var transcript: String = ""
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -scheme cmux-unit -destination 'platform=macOS' -only-testing cmuxTests/Voice/VoiceInputStateTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/App/Voice/VoiceInputState.swift cmuxTests/Voice/VoiceInputStateTests.swift
git commit -m "feat(voice): add VoiceInputState observable model"
```

---

## Task 2: VoiceKeychainStore — API key storage

**Files:**
- Create: `Sources/App/Voice/VoiceKeychainStore.swift`

No unit test: Keychain operations require the OS and entitlements; they are verified during integration in Task 8. The store is covered by an error-path unit test below.

- [ ] **Step 1: Create VoiceKeychainStore.swift**

```swift
import Foundation
import Security

struct VoiceKeychainStore {
    private static let service = "com.manaflow.cmux.voice"
    private static let account = "openai-api-key"

    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VoiceKeychainError.saveFailed(status)
        }
    }

    static func load() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return nil }
        return key
    }

    static func delete() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum VoiceKeychainError: LocalizedError {
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Keychain save failed with status \(status)"
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/App/Voice/VoiceKeychainStore.swift
git commit -m "feat(voice): add VoiceKeychainStore for API key"
```

---

## Task 3: VoiceToolDefinitions — tool schemas and call types

**Files:**
- Create: `Sources/App/Voice/VoiceToolDefinitions.swift`
- Create: `cmuxTests/Voice/VoiceToolDefinitionsTests.swift`

- [ ] **Step 1: Write failing tests**

Create `cmuxTests/Voice/VoiceToolDefinitionsTests.swift`:

```swift
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class VoiceToolDefinitionsTests: XCTestCase {
    func testAllToolsHaveNames() {
        let tools = VoiceToolDefinitions.all
        XCTAssertFalse(tools.isEmpty)
        for tool in tools {
            XCTAssertFalse(tool.name.isEmpty, "Tool at index has empty name")
        }
    }

    func testToolNamesMatchExpected() {
        let names = Set(VoiceToolDefinitions.all.map(\.name))
        XCTAssertTrue(names.contains("get_app_state"))
        XCTAssertTrue(names.contains("switch_workspace"))
        XCTAssertTrue(names.contains("switch_tab"))
        XCTAssertTrue(names.contains("type_text"))
        XCTAssertTrue(names.contains("execute_command"))
    }

    func testSwitchWorkspaceSchemaHasIdParameter() {
        let tool = VoiceToolDefinitions.all.first(where: { $0.name == "switch_workspace" })!
        XCTAssertEqual(tool.parameters.properties?["id"]?.type, "string")
        XCTAssertTrue(tool.parameters.required?.contains("id") ?? false)
    }

    func testParseToolCallDecoding() throws {
        let json = """
        {"call_id":"call_abc","name":"type_text","arguments":"{\\"text\\":\\"hello\\"}"}
        """
        let call = try JSONDecoder().decode(VoiceToolCall.self, from: Data(json.utf8))
        XCTAssertEqual(call.callId, "call_abc")
        XCTAssertEqual(call.name, "type_text")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild -scheme cmux-unit -destination 'platform=macOS' -only-testing cmuxTests/Voice/VoiceToolDefinitionsTests 2>&1 | tail -10
```

Expected: compile error — types not defined.

- [ ] **Step 3: Create VoiceToolDefinitions.swift**

```swift
import Foundation

// MARK: - Schema types

struct VoiceToolSchema: Codable {
    var type: String
    var properties: [String: VoiceToolProperty]?
    var required: [String]?
}

struct VoiceToolProperty: Codable {
    var type: String
    var description: String?
}

// MARK: - Tool definition

struct VoiceToolDefinition: Codable {
    let type: String
    let name: String
    let description: String
    let parameters: VoiceToolSchema

    init(name: String, description: String, parameters: VoiceToolSchema) {
        self.type = "function"
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

// MARK: - Tool call from server

struct VoiceToolCall: Decodable {
    let callId: String
    let name: String
    let arguments: String

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case name
        case arguments
    }
}

// MARK: - All tools

enum VoiceToolDefinitions {
    static let all: [VoiceToolDefinition] = [
        VoiceToolDefinition(
            name: "get_app_state",
            description: "Returns the list of open workspaces and tabs. Call this before any navigation action.",
            parameters: VoiceToolSchema(type: "object", properties: [:], required: [])
        ),
        VoiceToolDefinition(
            name: "switch_workspace",
            description: "Switch to a workspace by its id.",
            parameters: VoiceToolSchema(
                type: "object",
                properties: ["id": VoiceToolProperty(type: "string", description: "Workspace UUID from get_app_state")],
                required: ["id"]
            )
        ),
        VoiceToolDefinition(
            name: "switch_tab",
            description: "Switch to a tab by its id in the current workspace.",
            parameters: VoiceToolSchema(
                type: "object",
                properties: ["id": VoiceToolProperty(type: "string", description: "Tab UUID from get_app_state")],
                required: ["id"]
            )
        ),
        VoiceToolDefinition(
            name: "type_text",
            description: "Inject text into the active terminal without pressing Enter.",
            parameters: VoiceToolSchema(
                type: "object",
                properties: ["text": VoiceToolProperty(type: "string", description: "Text to inject")],
                required: ["text"]
            )
        ),
        VoiceToolDefinition(
            name: "execute_command",
            description: "Inject text into the active terminal and press Enter to run it.",
            parameters: VoiceToolSchema(
                type: "object",
                properties: ["command": VoiceToolProperty(type: "string", description: "Command to run")],
                required: ["command"]
            )
        ),
    ]
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -scheme cmux-unit -destination 'platform=macOS' -only-testing cmuxTests/Voice/VoiceToolDefinitionsTests 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/App/Voice/VoiceToolDefinitions.swift cmuxTests/Voice/VoiceToolDefinitionsTests.swift
git commit -m "feat(voice): add VoiceToolDefinitions with JSON schemas"
```

---

## Task 4: VoiceRealtimeTransport — WebSocket client

**Files:**
- Create: `Sources/App/Voice/VoiceRealtimeTransport.swift`
- Create: `cmuxTests/Voice/VoiceRealtimeTransportTests.swift`

- [ ] **Step 1: Write failing tests**

Create `cmuxTests/Voice/VoiceRealtimeTransportTests.swift`:

```swift
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class VoiceRealtimeTransportTests: XCTestCase {
    func testSessionUpdateEncoding() throws {
        let event = RealtimeClientEvent.sessionUpdate(
            model: "gpt-4o-realtime-preview",
            instructions: "test",
            tools: VoiceToolDefinitions.all
        )
        let data = try JSONEncoder().encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "session.update")
        let session = json["session"] as? [String: Any]
        XCTAssertEqual(session?["model"] as? String, "gpt-4o-realtime-preview")
    }

    func testAudioAppendEncoding() throws {
        let audio = Data([0x01, 0x02])
        let event = RealtimeClientEvent.audioAppend(audio)
        let data = try JSONEncoder().encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "input_audio_buffer.append")
        XCTAssertFalse((json["audio"] as? String ?? "").isEmpty)
    }

    func testFunctionCallOutputEncoding() throws {
        let event = RealtimeClientEvent.functionCallOutput(callId: "call_abc", output: #"{"ok":true}"#)
        let data = try JSONEncoder().encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "conversation.item.create")
        let item = json["item"] as? [String: Any]
        XCTAssertEqual(item?["type"] as? String, "function_call_output")
        XCTAssertEqual(item?["call_id"] as? String, "call_abc")
    }

    func testServerEventParsingFunctionCallDone() throws {
        let json = """
        {
          "type": "response.function_call_arguments.done",
          "call_id": "call_xyz",
          "name": "switch_workspace",
          "arguments": "{\\"id\\":\\"uuid-here\\"}"
        }
        """
        let event = try JSONDecoder().decode(RealtimeServerEvent.self, from: Data(json.utf8))
        guard case .functionCallDone(let call) = event else {
            XCTFail("Expected .functionCallDone"); return
        }
        XCTAssertEqual(call.callId, "call_xyz")
        XCTAssertEqual(call.name, "switch_workspace")
    }

    func testServerEventParsingUnknownIsIgnored() throws {
        let json = """{"type":"session.created","session":{}}"""
        let event = try JSONDecoder().decode(RealtimeServerEvent.self, from: Data(json.utf8))
        guard case .other = event else {
            XCTFail("Expected .other"); return
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild -scheme cmux-unit -destination 'platform=macOS' -only-testing cmuxTests/Voice/VoiceRealtimeTransportTests 2>&1 | tail -10
```

Expected: compile error.

- [ ] **Step 3: Create VoiceRealtimeTransport.swift**

```swift
import Foundation
import AVFoundation

// MARK: - Client events (outbound)

enum RealtimeClientEvent: Encodable {
    case sessionUpdate(model: String, instructions: String, tools: [VoiceToolDefinition])
    case audioAppend(Data)
    case functionCallOutput(callId: String, output: String)
    case responseCreate

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sessionUpdate(let model, let instructions, let tools):
            try container.encode("session.update", forKey: .type)
            var sessionContainer = container.nestedContainer(keyedBy: SessionKeys.self, forKey: .session)
            try sessionContainer.encode(model, forKey: .model)
            try sessionContainer.encode(["text"], forKey: .modalities)
            try sessionContainer.encode(instructions, forKey: .instructions)
            try sessionContainer.encode(tools, forKey: .tools)
            try sessionContainer.encode("auto", forKey: .toolChoice)
            try sessionContainer.encode("pcm16", forKey: .inputAudioFormat)
            let vad = ServerVadConfig(
                type: "server_vad",
                threshold: 0.5,
                prefixPaddingMs: 300,
                silenceDurationMs: 200,
                createResponse: true,
                interruptResponse: false
            )
            try sessionContainer.encode(vad, forKey: .turnDetection)
        case .audioAppend(let data):
            try container.encode("input_audio_buffer.append", forKey: .type)
            try container.encode(data.base64EncodedString(), forKey: .audio)
        case .functionCallOutput(let callId, let output):
            try container.encode("conversation.item.create", forKey: .type)
            var itemContainer = container.nestedContainer(keyedBy: ItemKeys.self, forKey: .item)
            try itemContainer.encode("function_call_output", forKey: .type)
            try itemContainer.encode(callId, forKey: .callId)
            try itemContainer.encode(output, forKey: .output)
        case .responseCreate:
            try container.encode("response.create", forKey: .type)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, session, audio, item
    }
    enum SessionKeys: String, CodingKey {
        case model, modalities, instructions, tools, toolChoice = "tool_choice"
        case inputAudioFormat = "input_audio_format"
        case turnDetection = "turn_detection"
    }
    enum ItemKeys: String, CodingKey {
        case type, callId = "call_id", output
    }

    private struct ServerVadConfig: Encodable {
        let type: String
        let threshold: Double
        let prefixPaddingMs: Int
        let silenceDurationMs: Int
        let createResponse: Bool
        let interruptResponse: Bool

        enum CodingKeys: String, CodingKey {
            case type, threshold
            case prefixPaddingMs = "prefix_padding_ms"
            case silenceDurationMs = "silence_duration_ms"
            case createResponse = "create_response"
            case interruptResponse = "interrupt_response"
        }
    }
}

// MARK: - Server events (inbound)

enum RealtimeServerEvent: Decodable {
    case functionCallDone(VoiceToolCall)
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKey.self)
        let type_ = try container.decode(String.self, forKey: .type)
        if type_ == "response.function_call_arguments.done" {
            let call = try VoiceToolCall(from: decoder)
            self = .functionCallDone(call)
        } else {
            self = .other
        }
    }

    enum TypeKey: String, CodingKey { case type }
}

// MARK: - Transport

@MainActor
final class VoiceRealtimeTransport: NSObject {
    enum ConnectionState { case disconnected, connecting, connected, failed(Error) }

    private let endpoint = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview")!

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    var onToolCall: ((VoiceToolCall) -> Void)?
    var onStateChange: ((ConnectionState) -> Void)?

    func connect(apiKey: String) {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let session = URLSession(configuration: .default, delegate: nil, delegateQueue: .main)
        urlSession = session
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        onStateChange?(.connecting)
        task.resume()
        receiveLoop()
    }

    func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession = nil
        onStateChange?(.disconnected)
    }

    func send(_ event: RealtimeClientEvent) {
        guard let task = webSocketTask else { return }
        guard let data = try? JSONEncoder().encode(event) else { return }
        task.send(.string(String(data: data, encoding: .utf8)!)) { _ in }
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .failure(let error):
                    self.onStateChange?(.failed(error))
                case .success(let message):
                    self.onStateChange?(.connected)
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8),
                       let event = try? JSONDecoder().decode(RealtimeServerEvent.self, from: data),
                       case .functionCallDone(let call) = event {
                        self.onToolCall?(call)
                    }
                    self.receiveLoop()
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -scheme cmux-unit -destination 'platform=macOS' -only-testing cmuxTests/Voice/VoiceRealtimeTransportTests 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/App/Voice/VoiceRealtimeTransport.swift cmuxTests/Voice/VoiceRealtimeTransportTests.swift
git commit -m "feat(voice): add VoiceRealtimeTransport WebSocket client"
```

---

## Task 5: VoiceToolExecutor — dispatch to TabManager / TerminalPanel

**Files:**
- Create: `Sources/App/Voice/VoiceToolExecutor.swift`

No unit test for this task: `VoiceToolExecutor` dispatches directly to `TabManager` and `TerminalPanel`, which require the full AppKit/Ghostty stack. The dispatch logic is exercised in manual dogfood testing (Task 10).

- [ ] **Step 1: Create VoiceToolExecutor.swift**

```swift
import Foundation

@MainActor
final class VoiceToolExecutor {
    private weak var tabManager: TabManager?

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    func execute(call: VoiceToolCall) -> String {
        guard let tabManager else {
            return #"{"ok":false,"error":"tabManager unavailable"}"#
        }
        switch call.name {
        case "get_app_state":
            return getAppState(tabManager: tabManager)
        case "switch_workspace":
            return switchWorkspace(args: call.arguments, tabManager: tabManager)
        case "switch_tab":
            return switchTab(args: call.arguments, tabManager: tabManager)
        case "type_text":
            return typeText(args: call.arguments, tabManager: tabManager)
        case "execute_command":
            return executeCommand(args: call.arguments, tabManager: tabManager)
        default:
            return #"{"ok":false,"error":"unknown tool"}"#
        }
    }

    // MARK: - Tool implementations

    private func getAppState(tabManager: TabManager) -> String {
        struct WorkspaceSnapshot: Encodable {
            let id: String
            let title: String
            let isActive: Bool
        }
        let snapshots = tabManager.tabs.map {
            WorkspaceSnapshot(
                id: $0.id.uuidString,
                title: $0.customTitle ?? $0.title,
                isActive: $0.id == tabManager.selectedWorkspace?.id
            )
        }
        struct StateResult: Encodable {
            let workspaces: [WorkspaceSnapshot]
            let activeWorkspaceId: String?
        }
        let result = StateResult(
            workspaces: snapshots,
            activeWorkspaceId: tabManager.selectedWorkspace?.id.uuidString
        )
        return (try? String(data: JSONEncoder().encode(result), encoding: .utf8)) ?? #"{"ok":false}"#
    }

    private func switchWorkspace(args: String, tabManager: TabManager) -> String {
        guard let id = parseStringArg("id", from: args),
              let uuid = UUID(uuidString: id),
              let workspace = tabManager.tabs.first(where: { $0.id == uuid })
        else {
            return #"{"ok":false,"error":"workspace not found"}"#
        }
        tabManager.selectWorkspace(workspace)
        return #"{"ok":true}"#
    }

    private func switchTab(args: String, tabManager: TabManager) -> String {
        guard let id = parseStringArg("id", from: args),
              let uuid = UUID(uuidString: id),
              let tab = tabManager.tabs.first(where: { $0.id == uuid })
        else {
            return #"{"ok":false,"error":"tab not found"}"#
        }
        tabManager.selectTab(tab)
        return #"{"ok":true}"#
    }

    private func typeText(args: String, tabManager: TabManager) -> String {
        guard let text = parseStringArg("text", from: args),
              let panel = tabManager.selectedTerminalPanel
        else {
            return #"{"ok":false,"error":"no active terminal"}"#
        }
        panel.sendText(text)
        return #"{"ok":true}"#
    }

    private func executeCommand(args: String, tabManager: TabManager) -> String {
        guard let command = parseStringArg("command", from: args),
              let panel = tabManager.selectedTerminalPanel
        else {
            return #"{"ok":false,"error":"no active terminal"}"#
        }
        panel.sendInput(command)
        return #"{"ok":true}"#
    }

    // MARK: - Helpers

    private func parseStringArg(_ key: String, from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = dict[key] as? String
        else { return nil }
        return value
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/App/Voice/VoiceToolExecutor.swift
git commit -m "feat(voice): add VoiceToolExecutor dispatch layer"
```

---

## Task 6: VoiceInputController — audio capture + session coordinator

**Files:**
- Create: `Sources/App/Voice/VoiceInputController.swift`

- [ ] **Step 1: Create VoiceInputController.swift**

```swift
import Foundation
import AVFoundation

@MainActor
final class VoiceInputController {
    let state = VoiceInputState()
    private let transport = VoiceRealtimeTransport()
    private let executor: VoiceToolExecutor
    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24000,
        channels: 1,
        interleaved: true
    )!

    private let model: String
    private let instructions = """
        You are a voice controller for cmux, a macOS terminal app. Use only the registered tools \
        to act on the app. Call get_app_state first when you need to know what workspaces or tabs \
        are open. When the user says 'type X', use type_text. When they say 'run X' or 'execute X', \
        use execute_command. Keep any spoken reply to one short sentence. Do not invent capabilities.
        """

    init(tabManager: TabManager, model: String = "gpt-4o-realtime-preview") {
        self.executor = VoiceToolExecutor(tabManager: tabManager)
        self.model = model
        transport.onStateChange = { [weak self] state in
            self?.handleTransportStateChange(state)
        }
        transport.onToolCall = { [weak self] call in
            self?.handleToolCall(call)
        }
    }

    // MARK: - Public

    func activate() {
        guard !state.isActive else { return }
        guard let apiKey = VoiceKeychainStore.load(), !apiKey.isEmpty else {
            state.activity = .error("No API key set — open Settings > Voice to add your OpenAI key.")
            return
        }
        state.isActive = true
        state.activity = .connecting
        transport.connect(apiKey: apiKey)
        transport.send(.sessionUpdate(
            model: model,
            instructions: instructions,
            tools: VoiceToolDefinitions.all
        ))
        startAudioCapture()
    }

    func deactivate() {
        stopAudioCapture()
        transport.disconnect()
        state.isActive = false
        state.activity = .idle
        state.transcript = ""
    }

    func toggle() {
        if state.isActive { deactivate() } else { activate() }
    }

    // MARK: - Audio

    private func startAudioCapture() {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            state.activity = .error("Audio format conversion not available.")
            return
        }
        // Capture conv and targetFormat locally so the tap closure (background thread)
        // never touches @MainActor-isolated properties.
        let localTargetFormat = targetFormat

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let raw = Self.convertPCM(buffer, using: conv, targetFormat: localTargetFormat) else { return }
            Task { @MainActor [weak self] in
                self?.transport.send(.audioAppend(raw))
            }
        }

        do {
            try engine.start()
            audioEngine = engine
            state.activity = .listening
        } catch {
            state.activity = .error("Microphone start failed: \(error.localizedDescription)")
        }
    }

    private func stopAudioCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    // Static: called from background tap thread — no self access allowed.
    private static func convertPCM(
        _ inputBuffer: AVAudioPCMBuffer,
        using conv: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> Data? {
        let capacity = AVAudioFrameCount(
            Double(inputBuffer.frameLength) * targetFormat.sampleRate / inputBuffer.format.sampleRate + 1
        )
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return nil }

        var error: NSError?
        var inputConsumed = false
        conv.convert(to: outputBuffer, error: &error) { _, status in
            if inputConsumed {
                status.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            status.pointee = .haveData
            return inputBuffer
        }

        guard error == nil,
              outputBuffer.frameLength > 0,
              let channelData = outputBuffer.int16ChannelData
        else { return nil }

        let frameCount = Int(outputBuffer.frameLength)
        return Data(bytes: channelData[0], count: frameCount * 2)
    }

    // MARK: - Tool calls

    private func handleToolCall(_ call: VoiceToolCall) {
        state.activity = .executing
        let result = executor.execute(call: call)
        transport.send(.functionCallOutput(callId: call.callId, output: result))
        transport.send(.responseCreate)
        state.activity = .listening
    }

    // MARK: - Transport state

    private func handleTransportStateChange(_ connectionState: VoiceRealtimeTransport.ConnectionState) {
        switch connectionState {
        case .connected:
            if state.activity == .connecting { state.activity = .listening }
        case .failed(let error):
            state.activity = .error(error.localizedDescription)
            state.isActive = false
            stopAudioCapture()
        case .disconnected:
            if state.isActive { state.activity = .idle }
        case .connecting:
            state.activity = .connecting
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/App/Voice/VoiceInputController.swift
git commit -m "feat(voice): add VoiceInputController audio + session coordinator"
```

---

## Task 7: VoiceSettingsView — settings UI

**Files:**
- Create: `Sources/App/Voice/VoiceSettingsView.swift`

- [ ] **Step 1: Create VoiceSettingsView.swift**

```swift
import SwiftUI

struct VoiceSettingsView: View {
    @State private var apiKeyInput: String = ""
    @State private var isKeyMasked: Bool = true
    @State private var saveStatus: String = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    if isKeyMasked {
                        SecureField(
                            String(localized: "settings.voice.apiKeyPlaceholder",
                                   defaultValue: "sk-…"),
                            text: $apiKeyInput
                        )
                    } else {
                        TextField(
                            String(localized: "settings.voice.apiKeyPlaceholder",
                                   defaultValue: "sk-…"),
                            text: $apiKeyInput
                        )
                    }
                    Button {
                        isKeyMasked.toggle()
                    } label: {
                        Image(systemName: isKeyMasked ? "eye" : "eye.slash")
                    }
                    .buttonStyle(.plain)
                }
                HStack {
                    Button(String(localized: "settings.voice.saveKey",
                                  defaultValue: "Save API Key")) {
                        saveKey()
                    }
                    if !saveStatus.isEmpty {
                        Text(saveStatus)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                Button(String(localized: "settings.voice.clearKey",
                              defaultValue: "Clear API Key"),
                       role: .destructive) {
                    clearKey()
                }
            } header: {
                Text(String(localized: "settings.voice.apiKeySection",
                            defaultValue: "OpenAI API Key"))
            } footer: {
                Text(String(localized: "settings.voice.apiKeyFooter",
                            defaultValue: "Your key is stored in the macOS Keychain and never leaves your device."))
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if let existing = VoiceKeychainStore.load() {
                apiKeyInput = existing
            }
        }
    }

    private func saveKey() {
        do {
            try VoiceKeychainStore.save(apiKeyInput)
            saveStatus = String(localized: "settings.voice.saved", defaultValue: "Saved")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveStatus = "" }
        } catch {
            saveStatus = error.localizedDescription
        }
    }

    private func clearKey() {
        VoiceKeychainStore.delete()
        apiKeyInput = ""
        saveStatus = String(localized: "settings.voice.cleared", defaultValue: "Cleared")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveStatus = "" }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/App/Voice/VoiceSettingsView.swift
git commit -m "feat(voice): add VoiceSettingsView"
```

---

## Task 8: SettingsNavigation — add Voice tab

**Files:**
- Modify: `Sources/SettingsNavigation.swift`

- [ ] **Step 1: Add `.voice` to `SettingsNavigationTarget`**

In `Sources/SettingsNavigation.swift`, find the `enum SettingsNavigationTarget` declaration (line ~3) and add `case voice` alongside the existing cases. Add a localized title in the `var title` switch:

```swift
// In the enum, add after `.reset`:
case voice

// In var title switch, add:
case .voice:
    return String(localized: "settings.section.voice", defaultValue: "Voice")
```

Find the `CaseIterable` iteration where the navigation list is built. It is likely in a `List` or `ForEach` over `SettingsNavigationTarget.allCases` — no extra wiring is needed since the enum is `CaseIterable`.

Find where each case is rendered in the sidebar (look for a `switch self` or `switch target` that maps cases to views). Add a branch for `.voice` that renders `VoiceSettingsView()`.

- [ ] **Step 2: Find the settings view router**

```bash
grep -n "case .account\|case .terminal\|case .app\|SettingsNavigation" /Users/joehe/workspace/learning/cmux-voice-support/Sources/SettingsNavigation.swift | head -30
```

This shows where the view router is. Add `.voice` alongside the other cases, routing to `VoiceSettingsView()`.

- [ ] **Step 3: Build to confirm it compiles**

```bash
xcodebuild -scheme cmux-unit -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -10
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add Sources/SettingsNavigation.swift
git commit -m "feat(voice): add Voice tab to Settings navigation"
```

---

## Task 9: KeyboardShortcutSettings — voice toggle shortcut

**Files:**
- Modify: `Sources/KeyboardShortcutSettings.swift`

- [ ] **Step 1: Add `toggleVoiceInput` to the Action enum**

In `Sources/KeyboardShortcutSettings.swift`, find the `Action` enum (around line 62). Add the new case after `jumpToUnread`:

```swift
case toggleVoiceInput
```

- [ ] **Step 2: Add a label in the `var label` switch**

Find the `var label` computed property in `Action`. Add:

```swift
case .toggleVoiceInput:
    return String(localized: "shortcut.toggleVoiceInput.label", defaultValue: "Toggle Voice Input")
```

- [ ] **Step 3: Mark it as a public shortcut action**

Find `var isPublicShortcutAction` and make sure `.toggleVoiceInput` is included (if the property whitelists specific cases, add it; if it uses a denylist or returns `true` by default, no change needed):

```bash
grep -n "isPublicShortcutAction" /Users/joehe/workspace/learning/cmux-voice-support/Sources/KeyboardShortcutSettings.swift | head -10
```

Read the pattern and follow it exactly.

- [ ] **Step 4: Build to confirm it compiles**

```bash
xcodebuild -scheme cmux-unit -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -10
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add Sources/KeyboardShortcutSettings.swift
git commit -m "feat(voice): add toggleVoiceInput keyboard shortcut action"
```

---

## Task 10: cmuxApp integration — controller lifecycle + toolbar indicator

**Files:**
- Modify: `Sources/cmuxApp.swift`

- [ ] **Step 1: Add `VoiceInputController` as a `@State` property**

In the `cmuxApp` struct (the `@main` entry point), add:

```swift
@State private var voiceController: VoiceInputController?
```

- [ ] **Step 2: Initialize the controller once `tabManager` is ready**

Find the `body: some Scene` computed property. Inside the `WindowGroup` closure, add an `.onAppear` or use `init()`. The `tabManager` `@StateObject` is already available. Initialize the controller in `init()` after `_tabManager` is set:

```swift
// At the end of cmuxApp.init(), after existing setup:
// (voiceController is set in onAppear since @StateObject is not ready in init)
```

Add to the `WindowGroup` content view (the outermost view in `body`):

```swift
.onAppear {
    if voiceController == nil {
        voiceController = VoiceInputController(tabManager: tabManager)
    }
}
```

- [ ] **Step 3: Add toolbar mic button**

Find where `.toolbar` modifiers are applied to the main content view (search for `ToolbarItem` in `cmuxApp.swift`). Add:

```swift
ToolbarItem(placement: .automatic) {
    if let vc = voiceController {
        Button {
            vc.toggle()
        } label: {
            Image(systemName: micIconName(for: vc.state.activity))
                .foregroundStyle(micColor(for: vc.state.activity))
                .accessibilityLabel(
                    String(localized: "toolbar.voice.toggle",
                           defaultValue: "Toggle Voice Input")
                )
        }
        .help(String(localized: "toolbar.voice.help",
                     defaultValue: "Start or stop voice control (⌘ /)"))
    }
}
```

Add these helpers inside the `cmuxApp` struct (or in an extension at the bottom of the file):

```swift
private func micIconName(for activity: VoiceActivity) -> String {
    switch activity {
    case .idle: return "mic"
    case .connecting: return "mic"
    case .listening: return "mic.fill"
    case .processing, .executing: return "mic.fill"
    case .error: return "mic.slash"
    }
}

private func micColor(for activity: VoiceActivity) -> Color {
    switch activity {
    case .idle, .connecting: return .secondary
    case .listening, .executing, .processing: return .green
    case .error: return .red
    }
}
```

- [ ] **Step 4: Wire the `toggleVoiceInput` shortcut action**

Find where other `KeyboardShortcutSettings.Action` cases are handled in `AppDelegate` (search for `performKeyEquivalent` or the shortcut dispatch table). Add a handler for `.toggleVoiceInput` that calls `voiceController?.toggle()` on the main actor. Pass `voiceController` to `appDelegate` via the existing `appDelegate.configure(...)` call, or look up the app-level controller via a shared reference.

Inspect the existing shortcut dispatch to find the exact pattern. A common pattern is:

```bash
grep -n "case .jumpToUnread\|case .showNotifications\|shortcutAction" /Users/joehe/workspace/learning/cmux-voice-support/Sources/AppDelegate.swift | head -15
```

Follow that same pattern for `.toggleVoiceInput`.

- [ ] **Step 5: Build the full Debug app**

```bash
./scripts/reload.sh --tag voice-input
```

Check the output for `App path:` and use that path to open the app manually.

- [ ] **Step 6: Dogfood check**

Open the built app, go to Settings > Voice, add an OpenAI API key. Click the mic button in the toolbar. Say "switch to workspace 1". Confirm the workspace switches. Say "type echo hello". Confirm the text appears in the terminal. Say "run echo hello". Confirm it executes.

- [ ] **Step 7: Commit**

```bash
git add Sources/cmuxApp.swift
git commit -m "feat(voice): integrate VoiceInputController into cmuxApp"
```

---

## Task 11: Localizable.xcstrings — add new strings

**Files:**
- Modify: `Resources/Localizable.xcstrings`

- [ ] **Step 1: Add all new localized strings**

Open `Resources/Localizable.xcstrings` and add the following keys for English. Japanese translations are left as empty strings to be filled in later (following the existing pattern for in-progress translations):

```
settings.section.voice          → "Voice"
settings.voice.apiKeySection    → "OpenAI API Key"
settings.voice.apiKeyPlaceholder→ "sk-…"
settings.voice.apiKeyFooter     → "Your key is stored in the macOS Keychain and never leaves your device."
settings.voice.saveKey          → "Save API Key"
settings.voice.clearKey         → "Clear API Key"
settings.voice.saved            → "Saved"
settings.voice.cleared          → "Cleared"
shortcut.toggleVoiceInput.label → "Toggle Voice Input"
toolbar.voice.toggle            → "Toggle Voice Input"
toolbar.voice.help              → "Start or stop voice control"
```

Use the existing JSON structure in `Localizable.xcstrings` as the template. Each entry follows:

```json
"key.name" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "English text"
      }
    }
  }
}
```

- [ ] **Step 2: Build to verify no missing-string warnings**

```bash
./scripts/reload.sh --tag voice-input
```

Check for any localization warnings in the build output.

- [ ] **Step 3: Commit**

```bash
git add Resources/Localizable.xcstrings
git commit -m "feat(voice): add localized strings for Voice settings and toolbar"
```

---

## Done

After Task 11, the feature is complete. Run a full dogfood session:

1. Open the tagged Debug app
2. Settings > Voice — set OpenAI API key
3. Click the mic icon (or trigger the shortcut) — toolbar turns green
4. Say "what workspaces are open" — AI responds silently via `get_app_state`
5. Say "switch to workspace 2" — workspace switches
6. Say "type git status" — text appears in terminal
7. Say "run git status" — command executes
8. Click mic icon again — session ends, toolbar returns to idle

Then run the regression test suite:

```bash
xcodebuild -scheme cmux-unit -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`
