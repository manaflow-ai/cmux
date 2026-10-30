// l10n-allow-file: gallery fixtures (sample commands, output and summaries), not shipped UI.
// A background task's end opened in place (BackgroundTaskNote.tsx): a click on the note shows the
// whole command, the end of what it printed and its exit code, read from acpmux's process registry
// (backgroundTaskOutput.ts), and the one explicit way to its terminal, Open in terminal. The stage
// stands in for the registry with the answers acpmux sends (`process/list` records and a
// `process/tail` page), so the real note reads them as it does in the app.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { AcpmuxBackgroundTask } from "../model";
import { BackgroundTaskNote } from "./BackgroundTaskNote";
import { BackgroundTaskOutputContext, type BackgroundTaskOutputReader } from "./backgroundTaskOutput";
import { resetTranscriptDisclosure, TranscriptDisclosureProvider } from "./transcriptDisclosure";

type Props = {
  task: AcpmuxBackgroundTask;
  /// The registry's record for the task (hub/processes.rs `Process`), and the end of its output.
  process?: Record<string, unknown>;
  output?: string;
};

const NOTE = "button.cv-bgtask";

/// The disclosure session the stage keeps its notes' open state in, cleared on each mount so a play
/// always starts from a closed note.
const DISCLOSURE = "gallery-background-task-note";

/// The note in a transcript's width, over a registry that answers for its one task as acpmux does:
/// the process record, and a tail page read from past the file's start (so its first line is cut).
function GalleryNote({ task, process, output }: Props) {
  const [reader] = useState<BackgroundTaskOutputReader>(() => {
    resetTranscriptDisclosure(DISCLOSURE);
    return {
      sessionId: "gallery",
      source: {
        listProcesses: async () => ({ processes: process ? [process] : [] }),
        tailProcess: async () => {
          const bytes = new TextEncoder().encode(`…partial line\n${output ?? ""}`);
          return {
            data: btoa(String.fromCharCode(...bytes)),
            fromByte: 4096,
            nextByte: 4096 + bytes.length,
            eof: true,
          };
        },
      },
    };
  });
  return (
    <TranscriptDisclosureProvider sessionId={DISCLOSURE}>
      <BackgroundTaskOutputContext.Provider value={reader}>
        <div style={{ padding: 16 }}>
          <BackgroundTaskNote task={task} />
        </div>
      </BackgroundTaskOutputContext.Provider>
    </TranscriptDisclosureProvider>
  );
}

const open: Play = async (ctx) => {
  await ctx.click({ selector: NOTE });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-bgtask__open"));
};
const openWithOutput: Play = async (ctx) => {
  await open(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".cv-shell__output"));
};

const TEST_TAIL = [
  "\u001b[32m ✓\u001b[0m src/upload/chunk.test.ts (12 tests) 41ms",
  "\u001b[32m ✓\u001b[0m src/upload/retry.test.ts (7 tests) 18ms",
  "\u001b[31m ✗\u001b[0m src/upload/resume.test.ts > resumes after a dropped connection",
  "   AssertionError: expected 206 to be 200",
  "    ❯ src/upload/resume.test.ts:48:27",
  "",
  " Test Files  1 failed | 2 passed (3)",
  "      Tests  1 failed | 19 passed (20)",
  "",
].join("\n");

const BUILD_TAIL = [
  "vite v6.3.1 building for production...",
  "✓ 1284 modules transformed.",
  "dist/index.html                  0.62 kB │ gzip:  0.38 kB",
  "dist/assets/index-4f2c1a.css    18.40 kB │ gzip:  4.91 kB",
  "dist/assets/index-9b8e7d.js    212.77 kB │ gzip: 68.03 kB",
  "✓ built in 3.82s",
  "",
].join("\n");

const record = (toolCallId: string, command: string, state: string, extra: Record<string, unknown> = {}) => ({
  id: `gallery/${toolCallId}`,
  sessionId: "gallery",
  toolCallId,
  harness: "claude",
  command,
  state,
  ...extra,
});

export default componentEntry<Props>({
  id: "agent-pane.background-task-note-open",
  title: "Background task note, opened",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/conversation/BackgroundTaskNote.tsx#BackgroundTaskNote"],
  load: async () => GalleryNote,
  height: 420,
  anchors: [{ selector: NOTE }],
  variants: {
    collapsed: {
      note: "A failed background task's end, closed: one tool row with its red mark and a chevron. A click opens it here; it never opens a terminal.",
      props: {
        task: { toolCallId: "bg-test", command: "npm test -- --watch=false", state: "failed" },
        process: record("bg-test", "npm test -- --watch=false", "failed", { detail: "1 test failed" }),
        output: TEST_TAIL,
      },
    },
    "failed-open": {
      note: "Play: opened, a failed task shows the whole command, the end of what it printed (colour codes stripped, cut at a line), its exit code and the harness's words on its end, then Open in terminal. The red mark stays; the clicked line does not move.",
      props: {
        task: {
          toolCallId: "bg-make",
          command: 'export PATH="$HOME/.cargo/bin:$PATH"; cd ~/src/uploader && npm test -- --watch=false',
          state: "failed",
          summary: "1 test failed in src/upload/resume.test.ts",
          exitCode: 1,
        },
        process: record("bg-make", "npm test -- --watch=false", "failed", { exitCode: 1 }),
        output: TEST_TAIL,
      },
      play: openWithOutput,
    },
    "completed-open": {
      note: "Play: opened, a finished task shows its command and the end of its output, with no exit line, then Open in terminal.",
      props: {
        task: { toolCallId: "bg-build", command: "bun run build", state: "completed", summary: "Build finished" },
        process: record("bg-build", "bun run build", "exited", { exitCode: 0 }),
        output: BUILD_TAIL,
      },
      play: openWithOutput,
    },
    "stopped-open": {
      note: "Play: a task the agent stopped, opened with nothing in the registry (another machine's chat): the whole command and Open in terminal, no invented output.",
      props: {
        task: { toolCallId: "bg-dev", command: "npm run dev", state: "stopped", reason: "Stopped by the agent" },
      },
      play: open,
    },
  },
});
