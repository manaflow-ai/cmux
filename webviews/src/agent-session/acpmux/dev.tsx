// Dev server entry (vite.config.acpmux-pane.mjs): the bundled pane inlines
// these stylesheets (scripts/cmux-next/build-agent-pane-web.sh); here Vite
// serves them with hot reload.
import "../shared/styles.css";
import "./styles.css";
import "./conversation/conversation.css";
import "./changes/changes.css";
import "./composerControls.css";
import "./composerStates.css";
import "./searchChats.css";
import "./markdownField.css";
import "./modelPicker.css";
import { seedDevRecents } from "./devRecents";

// `?mock` runs the page in a plain browser against the in-page mock daemon (no cmux host), the
// way the screenshot harness stubs the bridge; `?recents=demo` seeds a few recent models so the
// model picker opens with its recents and layers.
const params = new URLSearchParams(location.search);
if (params.has("mock") && !window.webkit?.messageHandlers?.agentSession)
  window.cmuxAcpmuxActions = { ready: async () => ({ protocolVersion: 1, transport: "mock" }) };
if (params.get("recents") === "demo") seedDevRecents();
await import("./main");
