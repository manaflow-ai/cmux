// l10n-allow-file: gallery fixture names, reports and recorded messages, not shipped UI.
// A subagent's own view with its result head first (SubagentResultHead.tsx): Leo, 2026-11-04,
// "Opening a subagent shows its result first (medium). Put status, duration and its final report
// above its transcript, the way ChatGPT does."
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxRow } from "../model";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { childView } from "./subagentRows";

type Props = { agent: Partial<Subagent>; transcript?: boolean };
const at = Date.UTC(2026, 10, 4, 12);

const SHORT_REPORT = [
  "The reconnect bug is in `hub/reconnect.rs`: the retry timer is armed before the old socket closes,",
  "so the second attempt races the first.",
  "",
  "- Move `arm_retry` after `close_socket` (one line).",
  "- Add `reconnect_after_close` to cover it.",
].join("\n");

const LONG_REPORT = [
  "## Findings",
  "",
  "I read every call site of `SessionStore::flush` and the three paths that reach it from the UI.",
  "",
  "1. **Draft save on blur** writes the whole session, not the draft. On a 4,000-row chat that is 38 ms on the main thread.",
  "2. **Tab switch** flushes twice: once from `willHide` and once from the store's own observer.",
  "3. **Quit** waits on the flush with no deadline; a stuck disk holds the app open.",
  "",
  "## Proposed changes",
  "",
  "- Save drafts through `DraftStore` alone (it already debounces).",
  "- Drop the `willHide` flush; the observer covers it.",
  "- Give the quit flush a 2 s deadline, then write what is dirty and exit.",
  "",
  "## Measured",
  "",
  "| path | before | after |",
  "| --- | --- | --- |",
  "| blur | 38 ms | 0.4 ms |",
  "| tab switch | 21 ms | 9 ms |",
  "",
  "Tests: `session_store_flush_once`, `draft_save_skips_session`, `quit_flush_deadline`.",
  "",
  "Nothing else in the store writes on the main thread.",
].join("\n");

const transcript = (id: string, report: string | undefined): AcpmuxRow[] => [
  { id: `${id}:prompt`, kind: "user", version: 1, at, text: "Find why reconnect fires twice and propose a fix." },
  {
    id: `${id}:work`,
    kind: "activity",
    version: 1,
    at: at + 2_000,
    toolCount: 2,
    items: [
      { kind: "tool", text: "", tool: { id: "t1", title: "rg arm_retry", kind: "search", status: "completed" } },
      { kind: "tool", text: "", tool: { id: "t2", title: "Read hub/reconnect.rs", kind: "read", status: "completed" } },
    ],
  },
  ...(report ? [{ id: `${id}:reply`, kind: "assistant", version: 1, at: at + 90_000, text: report }] : []),
];

export default componentEntry<Props>({
  id: "agent-pane.subagent-result",
  title: "Subagent result first",
  area: "Agent pane",
  pane: true,
  height: 560,
  covers: [
    "agent-session/acpmux/subagents/SubagentResultHead.tsx",
    "agent-session/acpmux/subagents/subagentRows.ts#childView",
  ],
  load: () =>
    import("../App").then(
      ({ VirtualTranscript }) =>
        function GallerySubagentResult({ agent: fields, transcript: withTranscript = true }: Props) {
          const agent: Subagent = {
            id: "worker",
            parent: null,
            name: "Explore",
            task: "Find the reconnect race",
            state: "completed",
            startedAt: at,
            endedAt: at + 134_000,
            ...fields,
          };
          const group: AcpmuxRow = { id: "group", kind: SUBAGENTS, version: 1, at, subagents: [agent] };
          const report = agent.state === "running" ? undefined : agent.result;
          const rows = childView(
            "worker",
            [group],
            withTranscript ? { worker: transcript("worker", report) } : {},
            new Set(),
            "Release review",
          )!;
          return (
            <div className="acpmux-main" style={{ height: "100%", position: "relative" }}>
              <VirtualTranscript
                rows={rows}
                sessionId="gallery-subagent-result"
                expanded={new Set()}
                openAt={agent.state === "running" ? undefined : { rowId: rows[0]!.id, offset: 0 }}
                onToggleActivity={() => undefined}
              />
            </div>
          );
        },
    ),
  variants: {
    finished: {
      props: { agent: { result: SHORT_REPORT } },
      note: "Done · 2m 14s, its final report, then a hairline and its transcript.",
    },
    failed: {
      props: {
        agent: {
          state: "failed",
          endedAt: at + 41_000,
          error: "Agent terminated early due to an API error. The request timed out after 600s.",
        },
      },
      note: "The error mark is the only red; the failure reads as the report.",
    },
    running: {
      props: { agent: { state: "running", endedAt: undefined, action: "Read hub/reconnect.rs" } },
      note: "The working spinner and its elapsed time; no report yet, the view opens on its latest row.",
    },
    "long-report": {
      props: { agent: { result: LONG_REPORT, endedAt: at + 612_000 } },
      note: "A report past 12 lines is cut with a fade and Show more.",
    },
    "no-transcript": {
      props: { agent: { result: SHORT_REPORT }, transcript: false },
      note: "A finished child whose transcript was not recorded still shows its result first.",
    },
  },
});
