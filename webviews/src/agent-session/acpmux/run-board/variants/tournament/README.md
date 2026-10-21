# Run board top-two tournament

The tournament surface mounts the Compare and Timeline candidates against the exact same `runBoardFixture` and `replayedBoardFixture` at one normal gallery width. The reviewer score receipt is:

| Candidate   | Score | Decision                                                            |
| ----------- | ----: | ------------------------------------------------------------------- |
| Compare     | 28/35 | Top two: strongest matrix, evidence ledger and explicit review path |
| Timeline    | 28/35 | Top two: strongest replay narrative and artifact provenance         |
| Ops Console | 25/35 | Reference only: useful operations context, with less review detail  |

Compare and Timeline advance together because they expose complementary evidence and decision paths at the same score. The placement rail deliberately reports `cloud-vm → Freestyle (current)`, `Huge Blue adapter: pending`, and `account eligibility: control-plane contract pending`. The provider/admission gap is therefore visible without implying that Huge Blue routing exists.

The next backend seam is the control-plane admission contract: resolve account eligibility and adapter readiness into a provider placement result that the run owner can attach to each attempt. Until that seam exists, this gallery view remains an honest pending-state judge.

The deterministic gallery markers are documented in `tournament.gallery.tsx`; the remote gallery matrix is the capture path, with no local browser or native build.
