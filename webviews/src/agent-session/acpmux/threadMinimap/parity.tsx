// l10n-allow-file: dev page fixture prompts (the Codex reference thread), not shipped UI.
// Dev server only (threadMinimap/parity.html): the transcript and its minimap over the Codex
// reference thread (eighteen "Reply with only the word ok and the number N" prompts) in the dark
// reference theme, at the recorded window's size, so a capture of hover, the card, a click jump
// with its highlight, Tab, a scrub and a bookmark compares with the Codex clips (minimap-ref).
// `?w=` and `?h=` size the page; `?prompts=` changes the count.
import "../../shared/styles.css";
import "../styles.css";
import "../conversation/conversation.css";
import "./threadMinimap.css";
import { createRoot } from "react-dom/client";
import type { AcpmuxRow } from "../model";
import { turnView } from "../conversation/turns";
import { VirtualTranscript } from "../App";

globalThis.__cmuxPaneStrings ??= (await import("../generated/strings.json")).default;

const params = new URLSearchParams(location.search);
const width = Number(params.get("w") ?? 1280);
const height = Number(params.get("h") ?? 820);
const prompts = Number(params.get("prompts") ?? 18);
const row = (id: string, kind: string, text?: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  text,
  version: 1,
  at: 1,
  ...extra,
});
const rows = Array.from({ length: prompts }, (_, index) => [
  row(`user-${index + 1}`, "user", `Reply with only the word ok and the number ${index + 1}. No tools.`),
  row(`answer-${index + 1}`, "assistant", `ok ${index + 1}`),
  row(`end-${index + 1}`, "turnSummary", undefined, { status: "completed", durationMs: 32_000 }),
]).flat();

const style = document.documentElement.style;
style.setProperty("--agent-text", "rgb(218 218 218)");
style.setProperty("--agent-muted", "rgb(129 129 129)");
style.setProperty("--agent-page-bg", "rgb(22 22 22)");
style.setProperty("--acpmux-base", "rgb(22 22 22)");
document.body.style.cssText = "margin:0;background:rgb(22 22 22)";
const root = document.getElementById("root")!;
Object.assign(root.style, { width: `${width}px`, height: `${height}px`, display: "flex", flexDirection: "column" });
createRoot(root).render(
  <VirtualTranscript
    rows={turnView(rows, new Set())}
    sessionId="parity"
    onToggleActivity={() => {}}
    expanded={new Set()}
  />,
);
