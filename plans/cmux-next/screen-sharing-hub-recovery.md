# Device hub startup recovery

An authenticated account and a ready device hub are different states. Identity loading can fail before a DeviceHub exists; treating a nil hub as signed out hides that failure and strands the sharing entry paths.

DeviceHubService keeps one cancellable identity-load/retry task for the current account and hub address. The already-pinned Rust retry pacer chooses exponential, jittered delays from one second to a thirty-second cap. There is no identity-ready notification to await. Success, sign-out, removal, account/address replacement and service teardown end the task. A unique load id fences late platform results even if they ignore cancellation.

The observable hub box carries a startup error until recovery or stop. Screen Sharing Home and Settings > Devices use the existing localized failure presentation; debug.device_hub reports the safe platform error code as last_error even before a hub exists. These are three distinct presentations: signed out retains Sign In, initialization failure shows the existing failure message while retrying, and a constructed hub resumes its own connection state. No new layout, animation or controls are introduced.

Detector: DeviceHubStartupRecoveryTests injects a failing platform loader and manual clock. It verifies debug and visible state, increasing retry delays without account changes, cancellation on sign-out, clearing on recovery, and rejection of a stale result after account replacement. Platform keys remain Secure Enclave backed; tests alone inject software keys.

Capture prerequisite evidence remains separate: account auth success is not identity success, hub readiness is not a live frame, and debug connect/approve calls are not counted user clicks. The host-specific evidence in cmuxterm-hq#10775 must establish the actual host failure before changing any platform identity behavior.

Observable test fixtures nested in a suite must be accessible to the macro's generated extension: do not declare the nested type private. The fleet test-target compile detects this access-control failure; an app-only compile does not compile these fixtures and is insufficient evidence.

Native test fixtures must import the modules that own the types they construct; a support module does not re-export its dependencies. Give multi-statement optional-return test closures an explicit result type when inference fails. Detector: the fleet test-target compile caught the missing CmuxNextWakeups import and DeviceHub? closure result in CmuxRemoteConfigDeadlineTests; app-only compilation could not detect either. Compile failures are never expected-red runtime regression evidence.
