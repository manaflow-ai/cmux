# Empty workspace layout proof

The hosted `ios-empty-state-proof.yml` workflow compiles the unmodified production
`MobileWorkspaceListEmptyRow.swift`, `MobilePairingCopy.swift`, and
`WorkspaceListUITableView.swift` at two pinned
commits. It links the real `CmuxMobileSupport` package, uses the workspace table's
hosting margins and sizing proposal, including disabled self-sizing
invalidation and zero estimated heights, and executes the same XCUITest on an
isolated iPhone simulator for each version.

The selected scenario is a constrained measurement probe: it measures the
displayed hosted cell with a one-point initial height, then gives its content
the production effectively-unlimited fitting proposal. Keeping the measured
view's layout state reproduces the vertical capsules in the original source.
This deliberately differs from the full coordinator's separate sizing-cell
lifecycle; it demonstrates the component failure and the fix under identical
inputs, but does not establish the full app's trigger. A cold launch with a
separate sizing cell did not reproduce the issue and is not accepted as before
evidence. The original user screenshot remains the full-app symptom evidence.

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
