// Dev server entry (vite.config.acpmux-pane.mjs): the page's own stylesheets first, in the order
// the bundled pane ships them (pageStyles.ts; scripts/cmux-next/build-agent-pane-web.sh); here
// Vite serves them with hot reload.
import "./pageStyles";
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
