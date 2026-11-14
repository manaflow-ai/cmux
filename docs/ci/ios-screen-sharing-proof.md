# iOS Screen Sharing proof

Leo: “the buttons are a future optional potential; the other ways (command palette and chevron) shoukd work still. and the protocol should be good still. across ios too.”

This manual proof exercises the iOS app in a new simulator and a physical managed Mac running an unchanged, completed capture bundle from the same source. It does not prove a physical iPhone. The optional Session Info buttons and the old live UI test rig are outside its scope.

Dispatch `ios-screen-sharing-proof.yml` on `feat-cmux-next` with the landed full `ref`, completed `mac_job`, and its `artifact_sha256`. The workflow checks ancestry before running that source, uses the protected `ios-e2e` account, and takes the runner's GUI token with `glaeda-canonical-root take-gui --wait 900`. A missing helper or any nonzero admission result ends the attempt. A give-way result is a scheduling receipt, not permission to bypass the token. Job completion releases it.

The runner must have Secure Enclave support, an installed fleet artifact client and `axe`, and the existing screen-recording/accessibility grants. The proof does not grant permissions, change a keychain search list, re-sign the Mac app, or add a software device identity. A reused capture tag with a prior device identity or restored account is refused. Use a fresh run-owned capture tag when building the artifact.

The simulator starts from Settings and taps Screen Sharing and the exact unique host row. Host approval is setup. Success requires the bound session to connect, positive video FPS, OCR of the host InputProbe title in the phone's captured pixels, a fresh random key challenge delivered from the phone's software keyboard to the host probe, and mounted Close followed by no host session. Stop during cleanup cannot satisfy the Stop phase. The host's existing sign-out RPC must finish and read back signed out; cleanup failures prevent success.

Only the allowlisted receipt is archived. Account/device identifiers, raw screenshots, app logs and input logs remain private and temporary. A missing archive, queued job, timeout, or partial phase is never a successful proof. `tests/test_ios_screen_sharing_proof.py` detects false success from blank video, stale input, surviving sessions, failed cleanup, wrong artifacts and unsafe receipt values. The workflow is an explicit manual proof, not a new PR CI gate.
