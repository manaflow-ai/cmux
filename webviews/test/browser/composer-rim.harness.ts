// The chat composer's (in both looks) and the New Tab box's rims and focus rings, with the pane's own
// stylesheets in its entry's order (acpmux/dev.tsx) and the desktop layer's script (it sets the
// hairline tokens and loads the liquid glass, which the card, the queue and the popover wear as in
// the pane).
import "../../src/pages/shared/desktop";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/threadMinimap/threadMinimap.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/composerStates.css";
import "../../src/agent-session/acpmux/composerLocation.css";
import "../../src/agent-session/acpmux/composerLook.css";
import "../../src/agent-session/acpmux/newtab/screen.css";
import { watchFocusVisible } from "../../src/agent-session/acpmux/focusVisibleMark";

document.body.style.margin = "0";
for (const box of document.querySelectorAll<HTMLElement>(".acpmux-composer-box, .nt-box")) {
  Object.assign(box.style, { width: "320px", height: "96px", margin: "16px" });
  // A strip or a queue sits on the card's top edge, as in the pane.
  if (box.matches(".acpmux-composer > :not(:first-child)")) box.style.marginTop = "0";
  // The card's focus ring reads `data-focused`, which its owner writes as focus moves (ComposerBox.tsx,
  // NewTabScreen.tsx; #50277 replaced the CSS `:has(:focus-visible)`): the harness's static cards are
  // marked the same way.
  watchFocusVisible(box, (focused) => box.toggleAttribute("data-focused", focused));
}
document.documentElement.dataset.harnessReady = "1";
