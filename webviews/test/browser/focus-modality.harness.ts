// The focus ring's one owner (src/ui/focusModality.ts) through the real desktop layer and the real,
// build-gated stylesheets: shared buttons (ui.css, desktop.css's ring) and the chat composer's rim.
import "../../src/pages/shared/desktop";
import "../../src/ui/ui.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/composerStates.css";
import "../../src/agent-session/acpmux/composerLocation.css";

document.body.style.margin = "16px";
const composer = document.getElementById("composer")!;
Object.assign(composer.style, { width: "320px", height: "96px", marginTop: "16px" });
// A shortcut (Cmd-K) that moves focus from code, as the palette and the pane keys do.
addEventListener("keydown", (event: KeyboardEvent) => {
  if (event.metaKey && event.key === "k") document.getElementById("b")!.focus();
});
document.documentElement.dataset.harnessReady = "1";
