# Shared transient material: chat adoption draft

**HOLD LANDING ONLY.** Source preparation, review and draft PR publication are
allowed. Do not merge this visual change until the chat visual landing hold is
lifted. This is the companion to [One transient material](transient-material.md),
which owns the references, common numeric contract and selected standard. It
does not establish a new material or change the baseline non-chat PR's scope.

Leo, 2026-11-11, on popovers: translucency is intended; the fix is one coherent
material style, never opaque. The standard candidate retains the existing web
menu density and native toast veil. Quieter and denser alternatives use the same
layout. Selection is a source recommendation until exact-head fleet captures
have been inspected; no screenshots or runtime verification are claimed here.

## Web adoption

`ui/glass/glass.css` now maps every `.ui-popup.ui-glass` and `.ui-card.ui-glass`
to the checked design-scale transient token, including chat menus, model and
reasoning pickers, context cards and other shared hover cards. Existing menu
tint/frost and host veil values are unchanged; their ownership is shared with
native surfaces. The root transient veil now uses the common alpha and scoped
theme surface, reaching existing Notice/toast and transient-error consumers.

`ui/popupSurface.css` maps dialogs and sheets to that veil and common frost.
The sheet radius, elevation, dimensions and buttons stay with their existing
owners. Tooltips retain their host contrast-fitted tint, ink and shadow over the
shared frost. Lens/spectrum retain their renderer-owned tint/frost; native host
glass still suppresses a second web blur. Both Reduce Transparency routes keep
their existing opaque override. No geometry, animation or interaction changes.

The previous standalone `pages/shared/transientMaterial.css` adapter and imports
remain. Its equal-valued declarations are redundant for common components but
also cover standalone `.page-menu` and legacy tooltip hooks. Removing them is a
separate import/call-site audit, not necessary for adopting chat.

## iOS adoption

The [iOS baseline inventory](../cmux-next-ios/design/transient-material.md)
describes the shared adapter and platform ownership. This draft changes these
previously held callers:

| Surface | Adoption |
| --- | --- |
| ContextUsageRing popover | Same real ring, 240-point details, native popover and compact adaptation; common presentation material, with a nil before-gallery option. |
| Shell toast | Explicit `.standard`; removes `nonChatToastMaterial`, including its conservative route/metadata exceptions. |
| Workspace opening/refusal toasts, palette, tab/group pickers, agent chooser and screen-sharing sheets | `.standard` on every tab; removes the agent/unknown-tab material exception. |
| Local chat toast | `ParityViews` explicitly opts into `.standard`. |
| Chat Files and Artifacts, Status, Copy, Display Settings, Edit Earlier Prompt | Existing presentation caller applies the shared sheet adapter; detents and background interaction remain unchanged. |
| Cloud Chats and both Message Chief presentations | Root sheet callers apply the shared adapter. |
| Chief Chat Colors | UIKit's existing SwiftUI host applies the adapter and clears only its host background, like the existing terminal artifact host. |
| Connection banners | Home Conversations banner explicitly adopts `.standard` here; Shell stays in the non-chat PR. No new shared default. |
| Home Updating notice and mixed group/screen management surfaces | ConversationsHome capsule, PageToast, and group move sheet adopt the shared material here because their destinations can contain chat. |

Shared toast/banner/sheet payload defaults stay unchanged. Nil remains available
for exact before galleries. Sheet scroll backdrops are hidden by the adapter;
content rows and artifact chips keep their semantic fills. Reduce Transparency
uses the existing opaque system sheet background and untinted system glass.

System menus, alerts, share controllers, Quick Look and system color pickers
retain platform presentation. Persistent composer, plan bar, voice/find bars
and content cards are outside this transient adoption.

One custom UIKit path is explicitly **not covered**: Home New Message uses
`CmuxConversationUI.ConversationComposeViewController.makeSheet()`, whose
controller owns opaque `ConversationTheme.background` fills and exposes no
material hook. A SwiftUI presentation modifier at its caller cannot change those
fills. Its renderer-owned material adoption needs a separate bounded change and
real compose-sheet gallery; do not count it as migrated or as system-owned.

## Gallery and fleet verification

- `ui.transient-material`: before, quieter, standard and denser, each light/dark.
  Before restores prior menu/tooltip frost and neutral toast/sheet veil. Generic
  palette/menu boxes are material samples; native interaction evidence is separate.
- `agent-pane.context-ring`: `material-before`, `material-quieter`,
  `material-standard`, `material-denser`. Each hovers the actual production ring
  and waits for the actual portaled card. Capture light/dark, plain/lens, host
  glass and Reduce Transparency. Standard and before may match in plain mode:
  the previous menu parameters already equal the shared token.
- iOS `transient-context`: the real `ContextUsageRing`, opened by tapping
  `contextUsage.open`; `contextUsage.details` must exist before capture. Variants
  are `before|quieter|standard|denser`, each light/dark. The existing toast,
  banner, sheet, palette and system-menu galleries are reused. The complete
  `TransientMaterialCaptureUITests` matrix is now 6 × 4 × 2 = 48 stills.

After the parent publishes the draft, run on the fleet from its exact head:

```sh
cmux-ci test --setup webviews --timeout 1200 -- bash -euo pipefail -c 'bun run check && bun test test/glass-levels.test.ts test/dialog-sheet-surface.test.ts test/hover-cards-glass.test.ts test/tooltip-surface.test.ts src/agent-session/acpmux/ContextCard.test.tsx'
```

Retain the existing `CmuxMobileWorkspacesTests/ToastRulesTests` and
`CommandPaletteTests`. Compile the iOS app and run these UI targets through the
fleet's supported iOS capture route, never on a personal Mac:

```text
CmuxMobileAppUITests/TransientMaterialCaptureUITests/testLightMaterials
CmuxMobileAppUITests/TransientMaterialCaptureUITests/testDarkMaterials
CmuxMobileAppUITests/AllUIStatesChatFeedCaptureUITests
CmuxMobileAppUITests/AllUIStatesShellCaptureUITests
CmuxMobileAppUITests/AllUIStatesWorkspacesCaptureUITests
```

Also capture the real Chat Colors sheet, five AgentChat sheets, Cloud Chats,
Message Chief and local/root toasts over chat. Verify unchanged dismissal,
detents, focus, tap targets and background interaction. Run accessibility text
size and Reduce Transparency cases. Accept only actually opened states, never
`UISTATE-MISS` or `uimiss`. Attach exact build/head, before/after stills and gallery
receipt to the draft PR; missing native captures remain unverified, not a pass.

## Draft handoff

Source diff review and `git diff --check` only in the implementation subtask.
No test, build, capture, commit or push is performed by that subtask. Existing
web source-contract assertions are updated to the new token names; runtime
checks and visual verdict remain the owning lane's next action. The parent owns
draft publication, review and eventual landing once the hold is lifted.
