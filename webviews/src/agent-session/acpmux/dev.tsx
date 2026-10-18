// Dev server entry (vite.config.acpmux-pane.mjs): the bundled pane inlines
// these stylesheets (scripts/cmux-next/build-agent-pane-web.sh); here Vite
// serves them with hot reload.
// desktop.css first, as in the bundle: it defines the popup surface (--surface-popup) and type scale.
import "../../pages/shared/desktop.css";
import "../../ui/popupSurface.css";
import "../shared/styles.css";
import "./styles.css";
import "./conversation/conversation.css";
import "./conversation/chatLook.css";
import "./conversation/renderPreview.css";
import "./chips/chips.css";
import "./previewCard/previewCard.css";
import "./changes/changes.css";
import "./turnChanges/turnChanges.css";
import "./summary/summary.css";
import "./subagents/subagents.css";
import "./header/header.css";
import "./composerControls.css";
import "./composerStates.css";
import "./composerLocation.css";
import "./bottomStack.css";
import "./composerAttachments.css";
import "./markdownField.css";
import "./modelPicker.css";
import "./keys.css";
import "./newtab/screen.css";
import "./newtab/history.css";
import "./threadMinimap/threadMinimap.css";
import { devHostParams, installDevHost } from "../../dev-host/host";
import { seedDevRecents } from "./devRecents";

// `?mock` runs the page in a plain browser against the in-page mock daemon (no cmux host), the
// way the screenshot harness stubs the bridge; `?recents=demo` seeds a few recent models so the
// model picker opens with its recents and layers. `#endpoint=…&token=…` runs it against a
// standalone acpmux daemon instead (devHost.ts, scripts/agent-pane/dev-slot.sh).
const params = new URLSearchParams(location.search);
const devHost = devHostParams(location.hash);
if (devHost) installDevHost(devHost);
else if (params.has("mock") && !window.webkit?.messageHandlers?.agentSession) {
  // `?newtab` opens the page as a New Tab page; `?newtab=surfaces` as an agent chat's side column.
  const newTab = params.has("newtab")
    ? { newTab: { kind: "agent", ...(params.get("newtab") === "surfaces" ? { surfaces: true } : {}) } }
    : {};
  window.cmuxAcpmuxActions = { ready: async () => ({ protocolVersion: 1, transport: "mock", ...newTab }) };
}
if (params.get("recents") === "demo") seedDevRecents();
// `?data-<name>=<value>` sets what the app's Debug choices set on <html> before the page loads
// (AgentPaneTunables.documentAttributes), e.g. `?mock&data-thought-style=brain`.
for (const [name, value] of params) if (/^data-[a-z-]+$/.test(name)) document.documentElement.setAttribute(name, value);
// `?sleek` turns on every cleaner chat variant at once (conversation/chatLook.css).
if (params.has("sleek"))
  for (const [name, value] of Object.entries({
    "data-chat-bubble": "soft",
    "data-chat-code": "slim",
    "data-chat-files": "quiet",
    "data-chat-inline-code": "soft",
  }))
    document.documentElement.setAttribute(name, value);
// The dev server has no locales/<code>.js: install the whole string table before the pane loads.
globalThis.__cmuxPaneStrings ??= (await import("./generated/strings.json")).default;
await import("./main");
