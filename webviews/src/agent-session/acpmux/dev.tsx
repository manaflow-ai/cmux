// Dev server entry (vite.config.acpmux-pane.mjs): the bundled pane inlines
// these stylesheets (scripts/cmux-next/build-agent-pane-web.sh); here Vite
// serves them with hot reload.
import "../shared/styles.css";
import "./styles.css";
import "katex/dist/katex.min.css";
import "./conversation/conversation.css";
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
import "./composerAttachments.css";
import "./markdownField.css";
import "./modelPicker.css";
import "./keys.css";
import "./newtab/screen.css";
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
else if (params.has("mock") && !window.webkit?.messageHandlers?.agentSession)
  window.cmuxAcpmuxActions = { ready: async () => ({ protocolVersion: 1, transport: "mock" }) };
if (params.get("recents") === "demo") seedDevRecents();
// The dev server has no locales/<code>.js: install the whole string table before the pane loads.
globalThis.__cmuxPaneStrings ??= (await import("./generated/strings.json")).default;
await import("./main");
