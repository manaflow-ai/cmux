// l10n-allow-file: gallery fixtures (sample commands and output), not shipped UI.
// The chat row of a finished background command, opened (Leo, 2026-11-24, on a "Background command
// completed" row that opened to a Shell card with no command and no output, only "Finished": "but i
// couldnt... do anything?"). It always shows the command line, its exit status and the end of what
// it printed, else why there is none. acpmux builds all three when the turn starts
// (hub/command_end.rs `cause.command`); the row reads them off its record, with no read and no
// placeholder. The running variant is the same card while the command still runs, as the composer
// hat and the Background tasks panel draw it.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { AcpmuxCommandEnd, AcpmuxRow } from "../model";
import { BackgroundTurnLine } from "./BackgroundTurnLine";
import { CommandEndCard } from "./CommandEndCard";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { TranscriptDisclosureProvider } from "./transcriptDisclosure";
import { resetTranscriptDisclosure } from "./transcriptDisclosureModel";

type Props = { end: AcpmuxCommandEnd; summary: string };

const LINE = ".cv-background-turn__task button[aria-expanded]";
const DISCLOSURE = "gallery-command-end-row";

function GalleryRow({ end, summary }: Props) {
  useState(() => resetTranscriptDisclosure(DISCLOSURE));
  // Read the clock once, in the initializer, not on every render (react-hooks purity).
  const [at] = useState(() => Date.now() - 60_000);
  if (end.state === "running")
    return (
      <div className="cv-transcript" style={{ padding: 16 }}>
        <CommandEndCard end={end} />
      </div>
    );
  const row = {
    id: backgroundTurnRowId("bg-1"),
    version: 1,
    at,
    kind: BACKGROUND_TURN,
    background: {
      id: "bg-1",
      trigger: "task_notification",
      running: false,
      quiet: true,
      hasRows: true,
      cause: {
        kind: "shell",
        status: end.state === "failed" ? "failed" : "completed",
        weight: "result",
        origin: "toolu_1",
        summary,
        command: end,
      },
    },
  } as AcpmuxRow;
  return (
    <TranscriptDisclosureProvider sessionId={DISCLOSURE}>
      <div className="cv-transcript" style={{ padding: 16 }}>
        <BackgroundTurnLine row={row} expanded={false} onToggle={() => {}} />
      </div>
    </TranscriptDisclosureProvider>
  );
}

const open: Play = async (ctx) => {
  await ctx.click({ selector: LINE });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-background-turn__task .cv-shell"));
};

const TEST_TAIL = [
  "   Compiling acpmux v0.1.0 (cmux-tui/crates/acpmux)",
  "    Finished `test` profile [unoptimized + debuginfo] target(s) in 41.20s",
  "     Running unittests src/lib.rs",
  "running 63 tests",
  "test hub::command_end::tests::a_finished_command_carries_its_line_exit_and_last_lines ... ok",
  "test hub::command_end::tests::an_empty_file_is_empty_and_a_missing_one_is_gone_once_it_ended ... ok",
  "test result: ok. 63 passed; 0 failed; 0 ignored",
].join("\n");

export default componentEntry<Props>({
  id: "agent-pane.command-end-row",
  title: "Background command row, opened",
  area: "Agent pane",
  pane: true,
  covers: [
    "agent-session/acpmux/conversation/CommandEndCard.tsx#CommandEndCard",
    "agent-session/acpmux/conversation/BackgroundTurnLine.tsx#BackgroundTurnLine",
  ],
  load: async () => GalleryRow,
  height: 340,
  anchors: [{ selector: ".cv-shell" }],
  variants: {
    "with-output": {
      note: "Play: opened, a finished command shows its line, Exit code 0 in the quiet tone and the last lines it printed, from its turn's record.",
      props: {
        summary: 'Background command "cargo test -p acpmux command_end" completed (exit code 0)',
        end: {
          command: "cargo test -p acpmux command_end",
          state: "completed",
          exitCode: 0,
          outputState: "printed",
          output: TEST_TAIL,
          cut: true,
        },
      },
      play: open,
    },
    "empty-output": {
      note: "Play: opened, a command that printed nothing shows its line, its exit code and No output, never an empty box.",
      props: {
        summary: 'Background command "git fetch -q origin" completed (exit code 0)',
        end: { command: "git fetch -q origin", state: "completed", exitCode: 0, outputState: "empty" },
      },
      play: open,
    },
    "output-gone": {
      note: "Play: opened after its output file was deleted: its line, Exit code 1 in the error tone and Output no longer available.",
      props: {
        summary: 'Background command "bun run build" failed (exit code 1)',
        end: { command: "bun run build", state: "failed", exitCode: 1, outputState: "gone" },
      },
      play: open,
    },
    running: {
      note: "The same card while the command still runs (the composer hat's and Background tasks panel's): its line, Running, and its output so far.",
      props: {
        summary: "",
        end: {
          command: "bun run dev --port 5173",
          state: "running",
          outputState: "printed",
          output:
            "  VITE v6.0.3  ready in 412 ms\n\n  ➜  Local:   http://localhost:5173/\n  ➜  Network: use --host to expose",
        },
      },
    },
  },
});
