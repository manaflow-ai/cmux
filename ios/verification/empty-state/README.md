# Empty workspace layout proof

The hosted `ios-empty-state-proof.yml` workflow compiles the unmodified production
`MobileWorkspaceListEmptyRow.swift` and `MobilePairingCopy.swift` at two pinned
commits. It links the real `CmuxMobileSupport` package, uses the workspace table's
hosting margins and sizing proposal, and executes the same XCUITest on an
isolated iPhone simulator for each version.

The original version must fail the compact-button geometry assertion. The fixed
version must show readable labels, accept two Retry taps, and open the native
documentation sheet. Each run exports screenshots, button frames, video, source
digests, and an XCTest result bundle. Build or launch failures are not accepted
as reproduction evidence.

This verifies the production component inside a focused UIKit host. The header
and tab bar are fixture chrome. The retry callback increments a visible counter;
it does not establish a network connection. Full-app compilation, live Mac
recovery, physical-device behavior, large text, and rotation need separate
verification. This harness avoids the unrelated Iroh archive checksum failure
that blocked the full-app test on 2026-09-25.
