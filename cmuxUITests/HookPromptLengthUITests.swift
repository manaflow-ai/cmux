import Foundation
import XCTest

/// Exercises the bundled hook CLI, app ingestion, durable event log, and events CLI.
/// Run only on a hosted test runner: this launches the test application.
final class HookPromptLengthUITests: XCTestCase {
    func testOriginalPromptLengthSurvivesCompactionAndEventStorage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-length-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The app runs outside the runner sandbox; its socket must still be
        // reachable by the sandboxed probe. Keep the UNIX path below sun_path.
        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("h\(UUID().uuidString.prefix(6))").path
        XCTAssertLessThan(socketPath.utf8.count, 104)
        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: socketPath + ".lock")
        }
        let products = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let appURL = try XCTUnwrap(["cmux DEV", "cmux"].map {
            products.appendingPathComponent("\($0).app")
        }.first { FileManager.default.isExecutableFile(atPath:
            $0.appendingPathComponent("Contents/MacOS/\($0.deletingPathExtension().lastPathComponent)").path
        ) })
        let cli = appURL.appendingPathComponent("Contents/Resources/bin/cmux").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cli))
        let appDiagnosticsURL = root.appendingPathComponent("app-diagnostics.json")
        // Launch the app binary directly so this socket-only test does not
        // require foreground activation. The socket and app home live in the
        // runner-owned fixture paths, which are accessible to both processes.
        let app = Process()
        app.executableURL = appURL.appendingPathComponent(
            "Contents/MacOS/\(appURL.deletingPathExtension().lastPathComponent)"
        )
        app.arguments = ["-socketControlMode", "allowAll", "-NSAppSleepDisabled", "YES"]
        var appEnvironment = ProcessInfo.processInfo.environment
        appEnvironment["HOME"] = root.path
        appEnvironment["CFFIXED_USER_HOME"] = root.path
        appEnvironment["XDG_CONFIG_HOME"] = root.appendingPathComponent(".config").path
        appEnvironment["CMUX_SOCKET_PATH"] = socketPath
        appEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        appEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        appEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        appEnvironment["CMUX_TAG"] = "ui-tests-14024-hook-length"
        appEnvironment["CMUX_UI_TEST_PROCESS"] = "1"
        appEnvironment["CMUX_UI_TEST_MODE"] = "1"
        appEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = appDiagnosticsURL.path
        app.environment = appEnvironment
        app.standardOutput = FileHandle.nullDevice
        app.standardError = FileHandle.nullDevice
        try app.run()
        defer { if app.isRunning { app.terminate() } }
        let output = root.appendingPathComponent("result.txt")
        _ = FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = try pythonExecutable()
        process.arguments = ["-c", Self.probe, cli, socketPath, root.path,
            root.appendingPathComponent(".cmuxterm/events.jsonl").path]
        process.standardOutput = handle
        process.standardError = handle
        let finished = expectation(description: "hook and events CLI probe finished")
        process.terminationHandler = { _ in finished.fulfill() }
        try process.run()
        wait(for: [finished], timeout: 180)
        if process.isRunning { process.terminate() }
        var diagnostics = (try? String(contentsOf: output, encoding: .utf8)) ?? "missing probe output"
        if !process.isRunning && process.terminationStatus != 0 {
            diagnostics += "\nappRunning=\(app.isRunning)"
            if !app.isRunning { diagnostics += " appExit=\(app.terminationStatus)" }
            diagnostics += "\n" + ((try? String(contentsOf: appDiagnosticsURL, encoding: .utf8)) ?? "missing app diagnostics")
        }
        XCTAssertFalse(process.isRunning, diagnostics)
        if !process.isRunning { XCTAssertEqual(process.terminationStatus, 0, diagnostics) }
        let attachment = XCTAttachment(string: diagnostics)
        attachment.name = "14024-prompt-length-results"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// `/usr/bin/python3` is an xcrun shim that refuses the XCTest sandbox.
    private func pythonExecutable() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let developerDirectory: String
        if let selected = environment["DEVELOPER_DIR"], !selected.isEmpty {
            developerDirectory = selected
        } else {
            let selector = Process()
            let output = Pipe()
            selector.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            selector.arguments = ["-p"]
            selector.standardOutput = output
            try selector.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            selector.waitUntilExit()
            XCTAssertEqual(selector.terminationStatus, 0)
            developerDirectory = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let python = URL(fileURLWithPath: developerDirectory)
            .appendingPathComponent("usr/bin/python3").resolvingSymlinksInPath()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: python.path))
        return python
    }

    private static let probe = #"""
import base64, json, pathlib, socket, subprocess, sys, time, uuid
cli, sock, root, log_path = sys.argv[1:]
prefix = 'hook-length-' + uuid.uuid4().hex
env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': root,
       'CMUX_SOCKET_PATH': sock, 'CMUX_CLI_SENTRY_DISABLED': '1',
       'CMUX_CLAUDE_HOOK_SENTRY_DISABLED': '1',
       'CMUX_CLAUDE_HOOK_STATE_PATH': root + '/sessions.json'}

def rpc(method, params):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(15)
        connection.connect(sock)
        connection.sendall((json.dumps({'id': str(uuid.uuid4()), 'method': method, 'params': params}) + '\n').encode())
        result = json.loads(connection.makefile().readline())
        assert result.get('ok'), (method, result.get('error'))
        return result['result']

deadline = time.monotonic() + 60
last_socket_error = None
while True:
    try:
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(2)
            connection.connect(sock)
            connection.sendall(b'ping\n')
            if connection.makefile().readline().strip() == 'PONG':
                break
    except (OSError, TimeoutError) as error:
        last_socket_error = str(error)
    assert time.monotonic() < deadline, ('isolated control socket did not become ready', last_socket_error, pathlib.Path(sock).exists())
    time.sleep(0.05)

workspace = rpc('workspace.create', {'focus': False})['workspace_id']
surfaces = rpc('surface.list', {'workspace_id': workspace})['surfaces']
surface = surfaces[0]['id']
env.update(CMUX_WORKSPACE_ID=workspace, CMUX_SURFACE_ID=surface)
expected = {}
expected_surfaces = {}
sentinels = ['PRIVATE_PROMPT_', 'PRIVATE_TOOL_', 'PRIVATE_CONTEXT_']

def hook(label, prompt, source='claude', nested=False):
    session = prefix + '-' + label
    payload = {'session_id': session, 'hook_event_name': 'UserPromptSubmit', 'cwd': root,
               'prompt_length': -123, 'tool_input': {'command': 'PRIVATE_TOOL_' + label, 'prompt_length': 123456}}
    if prompt is not None:
        if nested:
            payload['data'] = {'prompt': prompt}
        else:
            payload['prompt'] = prompt
    args = ['hooks', 'claude', 'prompt-submit'] if source == 'claude' else [
        'hooks', 'feed', '--source', 'claude', '--event', 'UserPromptSubmit']
    result = subprocess.run([cli, '--socket', sock] + args, input=json.dumps(payload),
                            env=env, text=True, capture_output=True, timeout=20)
    assert result.returncode == 0, (label, result.returncode)
    workstream_id = 'cmux-feed-v1:' + base64.b64encode(b'claude').decode() + ':' + base64.b64encode(session.encode()).decode()
    # Generic hooks feed historically omits surface_id; Claude prompt-submit
    # is the attributed entrypoint in #14024. Never borrow another surface.
    expected_surfaces[workstream_id] = surface if source == 'claude' else None
    return workstream_id

for label, prompt, length in [
    ('long', 'PRIVATE_PROMPT_' + 'x' * (18635 - 15), 18635),
    ('short', 'PRIVATE_PROMPT_' + 'x' * (85 - 15), 85),
    ('unicode', '\u00e9\u4e2de\u0301\U0001f469\u200d\U0001f4bb' * 100, 400),
    ('empty', '', 0), ('whitespace', ' \n\t ', 4), ('missing', None, None),
]:
    if label in ('long', 'short'):
        assert len(prompt.encode('utf-8')) == length
    expected[hook(label, prompt)] = length
expected[hook('generic', 'PRIVATE_PROMPT_' + 'g' * 985, source='feed')] = 1000
expected[hook('generic-missing', None, source='feed')] = None
expected[hook('nested', 'PRIVATE_PROMPT_' + 'n' * 985, nested=True)] = 1000

def push(label, fields, length, event_name='UserPromptSubmit'):
    session = prefix + '-' + label
    event = {'session_id': session, 'hook_event_name': event_name, '_source': 'claude',
             'workspace_id': workspace, 'surface_id': surface,
             '_opencode_request_id': session, **fields}
    rpc('feed.push', {'event': event, 'wait_timeout_seconds': 0})
    expected[session] = length
    expected_surfaces[session] = surface

for index, invalid in enumerate([-1, True, False, 1.5, '18635', None, [], {}, 1048577, 1e100]):
    push('invalid-' + str(index), {'tool_input': {'prompt': 'PRIVATE_PROMPT_bad', 'prompt_length': invalid}}, None)
push('legacy', {'tool_input': {'prompt': 'PRIVATE_PROMPT_legacy'}}, None)
push('no-prompt', {}, None)
push('length-only', {'prompt_length': 18635}, 18635)
push('max-length', {'prompt_length': 1048576}, 1048576)
push('scalar-precedence', {'tool_input': 'PRIVATE_PROMPT_scalar', 'prompt_length': 999}, None)
push('context-precedence', {'context': {'lastUserMessage': 'PRIVATE_CONTEXT_original'}, 'prompt_length': 999}, None)
push('precedence', {'tool_input': {'prompt': 'PRIVATE_PROMPT_first'}, 'prompt_length': 999}, None)
push('tool', {'tool_input': {'command': 'PRIVATE_TOOL_echo', 'prompt_length': 18635}}, None, 'PreToolUse')

deadline = time.monotonic() + 60
while True:
    result = subprocess.run([cli, '--socket', sock, 'events', '--after', '0',
        '--name', 'agent.hook.UserPromptSubmit', '--name', 'agent.hook.PreToolUse',
        '--no-ack', '--no-heartbeat', '--timeout', '3'], env=env, text=True,
        capture_output=True, timeout=15)
    timed_out = result.returncode != 0 and any(marker in result.stderr for marker in ('Timed out waiting for a matching event', 'Event stream closed', 'event stream closed'))
    assert result.returncode == 0 or timed_out, ('events CLI', result.returncode, result.stderr)
    assert not any(secret in result.stdout for secret in sentinels), 'CLI stdout leaked test content'
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    # Debug-library diagnostics are not event frames. Malformed JSON frames
    # still fail decoding, and every expected session remains mandatory.
    frames = [json.loads(line) for line in lines if line.startswith('{')]
    diagnostic_line_count = sum(not line.startswith('{') for line in lines)
    ours = [frame for frame in frames if frame.get('payload', {}).get('session_id') in expected]
    if {frame['payload']['session_id'] for frame in ours} == set(expected) or time.monotonic() >= deadline:
        break
seen = set()
for frame in ours:
    payload = frame['payload']
    session = payload['session_id']
    seen.add(session)
    assert payload.get('prompt_length') == expected[session], (session, payload.get('prompt_length'), expected[session])
    if expected[session] is None:
        assert 'prompt_length' not in payload, session
    assert frame['workspace_id'] == workspace and frame['surface_id'] == expected_surfaces[session], session
    assert payload['workspace_id'] == workspace and payload['surface_id'] == expected_surfaces[session], session
    assert payload.get('tool_input') is None and payload.get('context') is None, session
    assert payload.get('extra_fields') is None, session
    assert not any(secret in json.dumps(frame) for secret in sentinels), session
    if expected[session] == 18635 and 'tool_input_length' in payload:
        assert payload['tool_input_length'] < 1000, 'tool JSON length must keep its existing meaning'
assert seen == set(expected), ('missing own sessions', sorted(set(expected) - seen))

# The durable telemetry record must match the CLI frame, including identity and redaction.
deadline = time.monotonic() + 10
stored = {}
while time.monotonic() < deadline:
    if pathlib.Path(log_path).exists():
        for line in pathlib.Path(log_path).read_text().splitlines():
            try:
                frame = json.loads(line)
            except json.JSONDecodeError:
                continue
            if frame.get('payload', {}).get('session_id') in expected and frame.get('name', '').startswith('agent.hook.'):
                stored[frame['id']] = frame
    if all(frame['id'] in stored for frame in ours):
        break
    time.sleep(0.05)
for frame in ours:
    assert stored.get(frame['id']) == frame, ('durable event mismatch', frame['payload']['session_id'])
print(json.dumps({'cases': len(expected), 'stream_frames': len(ours), 'durable_frames': len(stored),
                  'ascii_lengths': [18635, 85], 'unicode_graphemes': 400,
                  'redaction': 'passed', 'session_surface_association': 'passed',
                  'non_json_stdout_lines': diagnostic_line_count}, sort_keys=True))
"""#
}
