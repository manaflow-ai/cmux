// Dev server entry (vite.config.acpmux-pane.mjs). Its stylesheet imports are the page's order:
// scripts/cmux-next/build-agent-pane-web.sh writes the bundled pane's one <style> from the sheets
// this file reaches, in import order (bundle.mjs --css-inputs), so the app and the dev server apply
// the same sheets in the same order; here Vite serves them with hot reload. A sheet a component
// imports ships without a line here (it lands where its component's import puts it); list it here
// only to give it an earlier place.
// desktop.css first: it defines the popup surface (--surface-popup) and type scale; Cmd-A selects
// only fields and `.selectable` content (R139).
// The liquid glass next: a surface's own sheet (the composer's queue fill) must come after
// `.ui-glass`, not before it as desktop.ts's import would put it.
// changes.css @imports git.css: the page inlines git.css just before it.
import "../../pages/shared/desktop.css";
import "../../ui/glass/glass.css";
import "../../ui/wave.css";
import "../shared/styles.css";
import "../../ui/popupSurface.css";
import "../../ui/ghost.css";
import "../../ui/findPill.css";
import "../../theme/messages.css";
import "./styles.css";
import "./diffTokens.css";
import "./conversation/conversation.css";
import "./chips/chips.css";
import "./chips/linkCard.css";
import "./previewCard/previewCard.css";
import "./contextCard.css";
import "./changes/changes.css";
import "./handoff/styles.css";
import "./checkpoints/styles.css";
import "./composerControls.css";
import "./composerStates.css";
import "./composerLocation.css";
import "./composerLook.css";
import "./savedEnvironments.css";
import "./bottomStack.css";
import "./composerAttachments.css";
import "./composer/dropOverlay.css";
import "./markdownField.css";
import "./modelPicker.css";
import "./keys.css";
import "./summary/summary.css";
import "./summary/WorkflowCard.css";
import "./summary/workflowDots.css";
import "./subagents/subagents.css";
import "./header/header.css";
import "./needsYou/needsYou.css";
import "./newtab/screen.css";
import "./newtab/history.css";
import "./newtab/noEntry.css";
import "./threadMinimap/threadMinimap.css";
import "./turnChanges/turnChanges.css";
import "./Inspector.css";
import "./session-info/sessionInfo.css";
import "./session-info/ContextSection.css";
import "./session-info/WorkflowTasks.css";
import "./dictation.css";
import "./composerFooterShared.css";
import "./addProject.css";
import "./harnesses/harnesses.css";
import "./replay/replay.css";
import "./offer/suggestedTasks.css";
import "./started/startedSessions.css";
import "./started/sessionHover.css";
import "./conversation/SubsessionCallCard.css";
import "./conversation/DispatchCard.css";
import "./conversation/AgentMessageRow.css";
import "./harnessStatus.css";
import "../../markdown-task-checkbox.css";
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
// A standalone daemon has no cmux host to send the `display` event: the frame-cost bench
// (bench/thread-minimap-frame-cost.bench.ts) turns the chat minimap on through this instead.
if (devHost) {
  const { setChatDisplay } = await import("./chatDisplay");
  (window as { cmuxDevDisplay?: (value: unknown) => void }).cmuxDevDisplay = setChatDisplay;
}
// The dev server has no locales/<code>.js: install the whole string table before the pane loads.
globalThis.__cmuxPaneStrings ??= (await import("./generated/strings.json")).default;
await import("./main");
