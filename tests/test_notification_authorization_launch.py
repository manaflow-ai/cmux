"""Execute the launch authorization owners with isolated framework boundaries.

No NSApplication, windows, socket, defaults, or notification daemon are opened.
The Swift method bodies come from the checkout under test; this is focused
behavior proof, not an app-host or AppKit display integration test.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def declaration(source, marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


class AuthorizationLaunchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='cmux-auth-launch-')
        store = (ROOT / 'Sources/TerminalNotificationStore.swift').read_text()
        settings = (ROOT / 'Sources/TerminalNotificationStoreSettings.swift').read_text()
        package = ROOT / 'Packages/macOS/CmuxNotifications/Sources/CmuxNotifications'
        extra = ''
        for name in ('NotificationAuthorizationState', 'NotificationAuthorizationRefreshCoordinator'):
            path = package / (name + '.swift')
            if path.exists():
                extra += '\n'.join(x for x in path.read_text().splitlines() if 'import ' not in x) + '\n'
        if not (package / 'NotificationAuthorizationState.swift').exists():
            extra += declaration(settings, 'enum NotificationAuthorizationState') + '\n'
        extra += declaration((package / 'UserNotificationAuthorizationStatus.swift').read_text(),
                             'public enum UserNotificationAuthorizationStatus')
        # The framework bridge initializer isn't used by this headless boundary.
        
        names = ['func markWindowSetupComplete()', 'func refreshAuthorizationStatus()',
                 'private func ensureAuthorization(', 'private func requestAuthorizationIfNeeded(',
                 'static func authorizationState(', 'static func shouldRequestAuthorization(',
                 'private static func shouldDeferAutomaticAuthorizationRequest(']
        bodies = '\n'.join(declaration(store, name) for name in names)
        if 'private func publishAuthorizationState(' in store:
            bodies += '\n' + declaration(store, 'private func publishAuthorizationState(')
        if 'private func completeAuthorizationRefresh(' in store:
            bodies += '\n' + declaration(store, 'private func completeAuthorizationRefresh(')
        gate_start = store.index('    private var isWindowSetupComplete') if '    private var isWindowSetupComplete' in store else -1
        gate = store[gate_start:store.index('    private var hasRequestedAutomaticAuthorization', gate_start)] if gate_start >= 0 else ''
        if 'private lazy var authorizationRefreshCoordinator' in store:
            start = store.index('    private lazy var authorizationRefreshCoordinator')
            gate = store[start:store.index('    private var hasRequestedAutomaticAuthorization', start)]
        if gate_start >= 0: gate += '\n var readyForTesting: Bool { isWindowSetupComplete }\n'
        window = (ROOT / 'Sources/App/CmuxMainWindow.swift').read_text()
        if 'func whenInitialDisplayCompletes(' in window:
            start = window.index('    private var initialDisplayCompletion')
            lifecycle = ('@MainActor final class Window: FakeWindow {\n'
                         + window[start:window.index('    private var isSoftHiddenForVisibilityController', start)]
                         + '\n}')
            trigger = 'let window = Window(); window.whenInitialDisplayCompletes { signal += 1 }; window.displayIfNeeded(); precondition(signal == 0); window.isVisible = true; window.displayIfNeeded(); precondition(window.events == ["layout", "display", "layout", "display"]); precondition(signal == 1); window.display(); precondition(signal == 1)'
            trigger = '''
            if mode.hasPrefix("window-late-") {
                let window = Window(); window.isVisible = true
                if mode == "window-late-display" { window.display() } else { window.displayIfNeeded() }
                let events = window.events
                window.whenInitialDisplayCompletes { signal += 1 }
                precondition(signal == 1, "completed initial display was lost before registration")
                precondition(window.events == events, "late registration required another redraw")
                window.whenInitialDisplayCompletes { signal += 10 }
                window.display(); window.displayIfNeeded()
                precondition(signal == 1, "completion delivered more than once")
                return
            }
            if mode == "window-before" {
                let window = Window(); window.isVisible = true
                window.whenInitialDisplayCompletes { signal += 1 }
                precondition(signal == 0, "registration inferred a display")
                window.contentView = nil; window.display(); precondition(signal == 0)
                window.contentView = true; window.display(); precondition(signal == 1)
                return
            }
            if mode == "window-lifetime" {
                weak var released: Window?
                do {
                    let window = Window(); released = window
                    window.whenInitialDisplayCompletes { signal += 1 }
                }
                precondition(released == nil && signal == 0, "pending readiness retained a window or delivered after release")
                return
            }
            ''' + trigger
        else:
            delegate = (ROOT / 'Sources/AppDelegate.swift').read_text()
            lifecycle = ('@MainActor final class Owner { var didScheduleNotificationWindowSetupSignal = false\n'
                         + declaration(delegate, 'private func markNotificationWindowSetupCompleteAfterLayout()').replace('private func', 'func') + '\n}')
            trigger = 'let owner = Owner(); owner.markNotificationWindowSetupCompleteAfterLayout(); pumpRunLoop(); precondition(!TerminalNotificationStore.shared.readyForTesting, "gate opened without a window layout/display")'
        template = (ROOT / 'tests/fixtures/notification_authorization_launch.swift').read_text()
        generated = template.replace('// TYPES', extra).replace('// GATE', gate).replace('// BODIES', bodies).replace('// LIFECYCLE', lifecycle).replace('// WINDOW TEST', trigger)
        source = Path(cls.temp.name) / 'main.swift'
        source.write_text(generated)
        cls.binary = Path(cls.temp.name) / 'launch-tests'
        result = subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(source), '-o', str(cls.binary)], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_case(self, case):
        result = subprocess.run([str(self.binary), case], capture_output=True, text=True,
                                env={**os.environ, 'SWIFT_BACKTRACE': 'disable'}, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_window_completion_requires_display(self): self.run_case('window')
    def test_late_registration_after_display_without_redraw(self): self.run_case('window-late-display')
    def test_late_registration_after_display_if_needed_without_redraw(self): self.run_case('window-late-if-needed')
    def test_registration_before_display_and_without_content_stays_closed(self): self.run_case('window-before')
    def test_pending_readiness_does_not_retain_window(self): self.run_case('window-lifetime')
    def test_early_native_status_does_not_publish(self): self.run_case('status')
    def test_early_grant_does_not_publish(self): self.run_case('grant')
    def test_early_failure_does_not_publish(self): self.run_case('failure')
    def test_early_denial_callback_does_not_publish(self): self.run_case('request-denied')
    def test_early_error_callback_does_not_publish(self): self.run_case('request-error')
    def test_post_setup_and_noop_publication(self): self.run_case('post')


if __name__ == '__main__':
    unittest.main()
