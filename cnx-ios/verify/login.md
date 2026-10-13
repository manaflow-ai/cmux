# Login verification (welcome redesign)

Date: 2026-10-13. Branch `feat-cnx-ios-login`. Evidence (git-ignored) is in
`cnx-ios/verify/evidence/2026-10-13/login/`.

## Feedback

"I dislike everything in the login screen that comes above the continue
buttons. Examples of login screens I like are Claude's and ChatGPT."

## References

Neither app's signed-out screen was in `~/Downloads/cmux-native-references/`
(all captures there are signed in), so the references come from public galleries:

- Claude iOS welcome (Refero, via Pinterest): "✳ Claude" wordmark at the top, one
  serif headline ("Do your best work with Claude"), then the sign-in controls and
  legal text. Nothing else.
- ChatGPT iOS welcome (Banani): one centered "ChatGPT ●" line on a plain field
  that cycles a few words, then a stack of equal pills: Continue with Apple
  (white, first), Continue with Google, Sign up with email, Log in.

Both are copied into `evidence/.../refs/` only for the comparison strip.

## Before and after

- Before: a 40 pt mark, a mono "terminal" card typing lines and a chat bubble
  on a 6 s loop, a leading-aligned headline and a second line of feature copy.
- After: the cmux chevron (60 pt, the app icon's cyan-to-indigo gradient with a
  soft glow) and one centered line, "Your Macs, in your pocket.", centered in the
  space above the buttons. The button stack is unchanged in order and size
  (Apple first, then Google, GitHub, email; all 52 pt capsules), as in ChatGPT.
- Launch to welcome: the launch mark becomes the hero mark. Welcome draws the
  mark at the launch screen's size and center on its first frame (the root
  swaps without a fade). The mark then glides up, shrinks 72 → 60 and takes the
  gradient. The headline un-blurs and rises, and the buttons stagger in. After
  that, a slow glow breathe is the only motion. Reduce Motion uses crossfades.
- Email sheet, light mode: the field and code boxes were the same gray as the
  sheet and were invisible. The sheet is now white in light, as in Claude and
  ChatGPT; dark is unchanged.

## How it was run

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
verify/build.sh <ios26 udid> <ios27 udid>          # xcodegen + simulator build + install
verify/record-login.sh <udid> s27 verify/evidence/2026-10-13/login   # welcome + email, dark and light
CNX_CLEAR_AUTH=1 CNX_MOCK_AUTH=1 CNX_RECORD_CODEC=hevc \
  verify/record.sh <udid> .../s27-code-dark.mp4 6 dark -cnx-email name@example.com
verify/login-montage.sh verify/evidence/2026-10-13/login 2.58   # strips
```

The simulators were headless `cnx-login-ios26` (iOS 26.5) and `cnx-login-ios27`
(iOS 27.0), both iPhone 17 Pro. Simulator.app was never opened. Every run
launched signed out with `CNX_CLEAR_AUTH=1`.

## Results

| Strip | Shows | Result |
| --- | --- | --- |
| `cmp-welcome.png` | Claude, ChatGPT, before, after (dark, light) | Same composition as the references: a mark and one line, then the pill stack and legal text |
| `cmp-matrix.png` | Welcome, email and code steps on iOS 26 and 27, dark and light | Same layout on both OS versions. The light email field and code boxes are now visible |
| `intro-s27-dark.png` | Launch → welcome, 12 frames 80 ms apart | The mark leaves the launch position without a jump, glides up and turns blue. The headline and buttons follow, settling in about 0.8 s |

Recorder artifact: in the videos, the mark seems to leave a faint dark trail at
the launch position for 2 or 3 frames. Screenshots taken during a slowed-down
intro (6 s spring, a temporary local build) show no trail. The trail comes from
the simulator's video encoder, not the app.

## Gaps

- The references are 2024-2026 gallery captures, not fresh captures of the
  current App Store builds.
- With `CNX_CLEAR_AUTH=1`, the launch mark waits about 2 s for auth to resolve
  before the intro starts. That delay comes from session restore, which was not
  part of this change.
- Apple, Google and GitHub sign-in were not run end to end. The buttons and
  their busy and disabled states are unchanged.
