// Non-invoking canary for the Sleepy Mode "Lock Mac" mechanism
// (https://github.com/manaflow-ai/cmux/issues/9730): macOS 26 removed the
// CGSession binary the lock used to shell out to, so the app now calls
// SACLockScreenImmediate from login.framework in-process (see
// SystemCommandRunner.lockScreenImmediate). The unit-test canary
// (SleepyPowerControlsLockTests.loginFrameworkLockResolvesOnThisMacOS) runs on
// the macOS 15 app-host runners; this script runs the same resolution check on
// the macOS 26 CI runner, where the removal class actually manifests. It only
// resolves the symbol — it never invokes it, so it cannot lock the runner.
import Darwin

guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY) else {
    fputs("FAIL: dlopen(login.framework) returned nil on this macOS\n", stderr)
    exit(1)
}
guard dlsym(handle, "SACLockScreenImmediate") != nil else {
    fputs("FAIL: SACLockScreenImmediate does not resolve on this macOS — the Sleepy Mode Lock Mac mechanism is broken here (see issue #9730)\n", stderr)
    exit(1)
}
print("OK: SACLockScreenImmediate resolves on this macOS")
