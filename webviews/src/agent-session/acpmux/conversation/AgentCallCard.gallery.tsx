// l10n-allow-file: gallery fixtures (a sample prompt and report), not shipped UI.
// A Claude Code Task or Agent call no subagent record claimed (an adopted chat's replay), before and
// after (AgentCallCard.tsx). `before` is the plain "Agent: …" tool row it drew. Three looks: `report`
// (selected): the line, then the report with the prompt behind "Show prompt"; `stacked`: the prompt
// and the report both shown, a hairline between; `preview`: as `report`, with the report's first line
// under the closed line, two lines tall. Each look closed and opened, and the selected one running
// and failed.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { tool } from "../../../gallery/fixtures/acpmux";
import { AgentCallCard, type AgentCallLook } from "./AgentCallCard";
import { agentCall } from "./agentCalls";
import { ToolRow } from "./ToolRow";
import { resetTranscriptDisclosure, TranscriptDisclosureProvider } from "./transcriptDisclosure";

type Props = { look: AgentCallLook | "before"; state: "done" | "running" | "failed" };

const PROMPT = [
  "Find where the transcript parser drops tool results that arrive before their call.",
  "",
  "1. Read `src/parse.ts` and `src/merge.ts`.",
  "2. Report each place with its file and line, and why it drops the result.",
  "",
  "Do not change any files.",
].join("\n");

const REPORT = [
  "The parser drops an early result in **two places**:",
  "",
  "- `src/merge.ts:42`: `mergeUpdate()` returns early when it has no call for the id, so the result is lost.",
  "- `src/parse.ts:118`: `readContent()` skips a `tool_call_update` whose `content` is empty.",
  "",
  "Keeping the update until its call arrives fixes both.",
  "agentId: a39e817af38ddf5e7 (use SendMessage with to: 'a39e817af38ddf5e7' to continue this agent)",
  "<usage>total_tokens: 18234",
  "tool_uses: 14",
  "duration_ms: 72000</usage>",
].join("\n");

const INPUT = JSON.stringify({ description: "Find the parser", prompt: PROMPT, subagent_type: "Explore" });

function fixture(state: Props["state"]) {
  const now = Date.now();
  const item = tool("Agent: Find the parser", "think", state === "running" ? "in_progress" : state, {
    inputSummary: INPUT,
    output: state === "done" ? REPORT : state === "failed" ? "Agent stopped: the API returned an error." : undefined,
    startedAt: now - 72_000,
    endedAt: state === "running" ? undefined : now,
  });
  return item;
}

const DISCLOSURE = "gallery-agent-call";

function Stage({ look, state }: Props) {
  useState(() => resetTranscriptDisclosure(DISCLOSURE));
  const [item] = useState(() => fixture(state));
  const call = agentCall(item.tool!);
  return (
    <TranscriptDisclosureProvider sessionId={DISCLOSURE}>
      <div className="acpmux-shell" style={{ padding: 16, maxWidth: 640 }}>
        <div className="cv-tools">
          {look === "before" || !call ? (
            <ToolRow item={item} />
          ) : (
            <AgentCallCard call={call} tool={item.tool!} look={look} />
          )}
        </div>
      </div>
    </TranscriptDisclosureProvider>
  );
}

/// Opens the card (or the plain row) by its line.
const open: Play = async (ctx) => {
  const toggle =
    ctx.document.querySelector<HTMLButtonElement>(".cv-disclosure__toggle") ??
    ctx.document.querySelector<HTMLButtonElement>(".cv-tool.is-toggle");
  toggle?.click();
  await ctx.waitFor(() => ctx.document.querySelector(".cv-disclosure__panel, .cv-tool-output, [aria-expanded=true]"));
};

const variant = (look: Props["look"], state: Props["state"], opened: boolean, note: string) => ({
  note,
  props: { look, state },
  ...(opened ? { play: open } : {}),
});

export default componentEntry<Props>({
  id: "agent-pane.agent-call-card",
  title: "Claude subagent call card",
  area: "Agent pane",
  pane: true,
  height: 420,
  covers: [
    "agent-session/acpmux/conversation/AgentCallCard.tsx",
    "agent-session/acpmux/conversation/agentCalls.ts",
    "agent-session/acpmux/conversation/ToolRow.tsx",
  ],
  load: async () => Stage,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: {
    "before-closed": variant(
      "before",
      "done",
      false,
      'Before: the plain tool row an adopted chat drew for Claude\'s Agent call, "Agent: Find the parser".',
    ),
    "before-open": variant(
      "before",
      "done",
      true,
      "Before, opened: the result as raw text with Claude Code's agentId and usage trailer, and no prompt.",
    ),
    "report-closed": variant(
      "report",
      "done",
      false,
      "Selected: one line, the subagent's mark, its kind and words, then Done, its time and tool uses.",
    ),
    "report-open": variant(
      "report",
      "done",
      true,
      "Selected, opened: the report as Markdown cut to three lines, the prompt behind Show prompt.",
    ),
    "report-running": variant("report", "running", false, "Selected, running: Working with the spinner and its clock."),
    "report-running-open": variant("report", "running", true, "Selected, running and opened: the prompt it was given."),
    "report-failed": variant(
      "report",
      "failed",
      true,
      "Selected, failed: Failed in the failure tone; its message below.",
    ),
    "stacked-open": variant(
      "stacked",
      "done",
      true,
      "Version B, opened: the prompt and the report both shown, a hairline between. Busier; the report sits lower.",
    ),
    "preview-closed": variant(
      "preview",
      "done",
      false,
      "Version C, closed: the report's first line under the line. Two lines per call; long runs of calls grow.",
    ),
  },
});
