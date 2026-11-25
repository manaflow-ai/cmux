// l10n-allow-file: gallery fixtures (sample commands and output), not shipped UI.
// A "Background task finished: bg-…" line opened (BackgroundTurnLine.tsx, backgroundTurnTask.ts;
// Leo, 2026-11-21: "7. background tasks not expandable. even if they're denoting completion, why
// shouldn't they get the same treatment?"). A click opens it like any command: the command, its end
// and the last lines it printed, read from acpmux's `_acpmux/bg/output`. The stage stands in for
// acpmux with the reply it sends, so the real line reads it as it does in the app.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";
import { BackgroundTurnLine } from "./BackgroundTurnLine";
import { BackgroundTaskOutputContext, type BackgroundTaskOutputReader } from "./backgroundTaskOutput";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { TranscriptDisclosureProvider } from "./transcriptDisclosure";
import { resetTranscriptDisclosure } from "./transcriptDisclosureModel";

type Props = {
  task: string;
  status: "completed" | "failed";
  command: string;
  /// What `_acpmux/bg/output` answers for the task, when it answers.
  reply?: Record<string, unknown>;
};

const LINE = ".cv-background-turn__task button[aria-expanded]";
const DISCLOSURE = "gallery-background-turn-task";

function GalleryLine({ task, status, command, reply }: Props) {
  const [reader] = useState<BackgroundTaskOutputReader>(() => {
    resetTranscriptDisclosure(DISCLOSURE);
    return {
      sessionId: `gallery-${task}`,
      source: {
        listProcesses: async () => ({ processes: [] }),
        tailProcess: async () => ({}),
        tailTask: async () => {
          if (!reply) throw new Error("no such task");
          return reply;
        },
      },
    };
  });
  // Read the clock once, in the initializer, not on every render (react-hooks purity).
  const [at] = useState(() => Date.now() - 60_000);
  const row: AcpmuxRow = {
    id: backgroundTurnRowId(task),
    version: 1,
    at,
    kind: BACKGROUND_TURN,
    background: {
      id: task,
      trigger: "task_notification",
      running: false,
      quiet: status === "completed",
      hasRows: true,
      cause: {
        kind: "shell",
        status,
        weight: "result",
        summary: `Background task ${status === "failed" ? "failed" : "finished"}: ${task}`,
      },
      source: { command },
    },
  } as AcpmuxRow;
  return (
    <TranscriptDisclosureProvider sessionId={DISCLOSURE}>
      <BackgroundTaskOutputContext.Provider value={reader}>
        <div className="cv-transcript" style={{ padding: 16 }}>
          <BackgroundTurnLine row={row} expanded={false} onToggle={() => {}} />
        </div>
      </BackgroundTaskOutputContext.Provider>
    </TranscriptDisclosureProvider>
  );
}

const open: Play = async (ctx) => {
  await ctx.click({ selector: LINE });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-background-turn__task .cv-shell"));
};
const openWithOutput: Play = async (ctx) => {
  await open(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".cv-background-turn__task .cv-shell__output"));
};

const bytes = (text: string) => btoa(String.fromCharCode(...new TextEncoder().encode(text)));

const TEST_TAIL = [
  "bun test v1.3.4",
  "",
  "test/background-turn-task-opens.test.tsx:",
  "\u001b[32m✓\u001b[0m a finished task's line shows a chevron and opens [2.10ms]",
  "\u001b[32m✓\u001b[0m a running task's line opens nothing [0.40ms]",
  "\u001b[32m✓\u001b[0m an opened line shows the command and the last lines [1.30ms]",
  "",
  " 6 pass",
  " 0 fail",
  " 14 expect() calls",
  "Ran 6 tests across 1 file. [212.00ms]",
  "",
].join("\n");

const FAIL_TAIL = [
  "error[E0308]: mismatched types",
  "  --> crates/acpmux/src/hub/background_cause.rs:88:17",
  "   |",
  "88 |         weight: Weight::Result,",
  "   |                 ^^^^^^^^^^^^^^ expected `Option<Weight>`, found `Weight`",
  "",
  "error: could not compile `acpmux` (lib) due to 1 previous error",
  "",
].join("\n");

export default componentEntry<Props>({
  id: "agent-pane.background-turn-task-open",
  title: "Background task finished line, opened",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/conversation/BackgroundTurnLine.tsx#BackgroundTurnLine"],
  load: async () => GalleryLine,
  height: 360,
  anchors: [{ selector: LINE }],
  variants: {
    closed: {
      note: "A finished task's line, closed: its words, the command it cites and a chevron in the quiet tone, like every row that opens.",
      props: {
        task: "bg-53568892f4dd",
        status: "completed",
        command: "bun test test/background-turn-task-opens.test.tsx",
        reply: { command: "bun test test/background-turn-task-opens.test.tsx", state: "completed", exitCode: 0 },
      },
    },
    "finished-open": {
      note: "Play: opened, a finished task shows its command, the last lines it printed (all in sight, no scroll), how long it took and Finished, in the same card a command opens to.",
      props: {
        task: "bg-53568892f4dd",
        status: "completed",
        command: "bun test test/background-turn-task-opens.test.tsx",
        reply: {
          command: "bun test test/background-turn-task-opens.test.tsx",
          description: "Run the background turn tests",
          state: "completed",
          exitCode: 0,
          startedAt: 1_700_000_000_000,
          endedAt: 1_700_000_004_200,
          data: bytes(TEST_TAIL),
          fromByte: 0,
        },
      },
      play: openWithOutput,
    },
    "failed-open": {
      note: "Play: opened, a failed task shows its command, the last lines it printed and its exit code.",
      props: {
        task: "bg-9a1c03be77d2",
        status: "failed",
        command: "cargo check -p acpmux",
        reply: {
          command: "cargo check -p acpmux",
          state: "failed",
          exitCode: 101,
          startedAt: 1_700_000_000_000,
          endedAt: 1_700_000_031_000,
          data: bytes(FAIL_TAIL),
          fromByte: 2048,
        },
      },
      play: openWithOutput,
    },
    "gone-open": {
      note: "Play: opened when acpmux no longer has the task (another machine's chat, a restart): the command the line cites and its end, no invented output.",
      props: { task: "bg-0d0d0d0d0d0d", status: "completed", command: "bun run build" },
      play: open,
    },
  },
});
