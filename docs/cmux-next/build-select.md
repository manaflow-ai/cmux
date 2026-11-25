# Build selection: the cheapest build per change

Leo, 2026-11-24: "i guess if he's complaining, we can also examine if his recent prs have actually needed
dev builds? examine better architecture potentially. more hot swapping whether it be gui or phone."

## What 25 recent iPhone-lane PRs needed

`scripts/cmux-next/build_select.py BASE HEAD` run over 25 recent PRs (#48532 to #53213), compared with the
controller's jobs for each head:

| Class | PRs | Mac build needed | Seen on the fleet |
|---|---|---|---|
| Docs, config, review tools | 12 (#49277, #49282, #49314, #50968, #52871, #52875, #52876, #52940, #53102, #53156, #53165, #53213) | none | iPhone try build-ahead on every review.sh/backend-only head; 17 and 23 min Mac ci-steps on #52875, #53102 |
| iPhone only | 2 (#53007, #53134) | none (iPhone: yes) | #53007: a full Mac `cmux` build queued 3 h+ from review.sh, plus 3 simulator steps |
| Mac app | 11 (#48532, #48722, #50034, #52926, #52947, #52948, #52966, #53091, #53160, #53163, #53164) | yes | 5 of these need it only for cmux-mobile-host (built from cmux-next-ios/rust) or a few Swift files; #53091's web and Rust parts were swappable |

## Gaps and what this change does

1. review.sh asked the fleet for a Mac build of every head, iPhone-only or not. Now it asks
   `build_select.py`; when `mac` is `none` it builds the merge base with `--any-tag`, which a build
   the fleet already made answers. `CNX_REVIEW_MAC_BUILD=head` keeps the old behavior.
2. cmux-next-ios-kit.yml's path filter (also the trigger for the controller's iPhone try build-ahead)
   matched `cmux-next-ios/scripts/**` and `cmux-next-ios/backend/**`. Review tools and the mobile worker
   no longer start it; the four scripts the iPhone build reads stay in.
3. live_apply.py calls cmux-next-ios/rust `ios-only`, but the Mac bundles cmux-mobile-host built from it.
   build_select floors live_apply's verdict with hot-apply.py's `bundled_inputs`.

## Next pieces

- (c, rest) Feed `build_select` into the controller's dev-build intake (hq ci-client swap_first): an
  iPhone-only plan with empty swap layers should reuse the base build, not queue one. Key Mac builds on
  the tree of Mac inputs, not the whole commit tree, so the dedupe works across iPhone-only commits.
- (a) Mac GUI: cmux-mobile-host is the largest remaining rebuild cause in this sample. Swap it like the
  daemon (a helper binary beside bin/, restarted by the app) so a mobile-host change is `swap`.
  Swift view-body edits already go through swift-live; stored properties and manifests still rebuild.
- (b) iPhone: markdown and artifact previews already render in WKWebView (CmuxMobileMarkdown,
  CmuxMobileArtifacts). Serve those web bundles from a dev server (as webviews does on the Mac) in a
  debug build, so web-only iPhone changes need no simulator build.
