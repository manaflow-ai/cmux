// l10n-allow-file: gallery fixtures (sample shell commands and output), not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";
import { MoveRow } from "./MoveRow";
import { ShellActionsContext, ShellRow } from "./ShellRow";
import type { ShellRun } from "./shellRuns";

const now = 1_760_000_000_000;

const running: ShellRun = {
  id: "gallery-running",
  command: "pnpm test -- --watch",
  cwd: "/Users/you/src/atlas-web",
  startedAt: now - 8_400,
  status: "running",
  output: "PASS src/net/retry.test.ts\nWatching for changes…",
  truncated: false,
  version: 2,
};

const longOutput = Array.from({ length: 12 }, (_, index) => `step ${index + 1}: completed`).join("\n");

const done: ShellRun = {
  id: "gallery-done",
  command: "pnpm lint",
  cwd: "/Users/you/src/atlas-web",
  startedAt: now - 13_200,
  endedAt: now - 1_200,
  status: "done",
  output: "Checked 142 files\nNo issues found",
  truncated: false,
  version: 3,
};

const failed: ShellRun = {
  id: "gallery-failed",
  command: "pnpm test -- src/auth.test.ts",
  cwd: "/Users/you/src/atlas-web",
  startedAt: now - 24_000,
  endedAt: now - 6_000,
  status: "failed",
  exitCode: 2,
  output: "1 failing test\nExpected token to be refreshed",
  error: "Command exited with code 2",
  truncated: false,
  version: 4,
};

const stopped: ShellRun = {
  id: "gallery-stopped",
  command: "pnpm dev",
  cwd: "/Users/you/src/atlas-web",
  startedAt: now - 45_000,
  endedAt: now - 2_000,
  status: "stopped",
  output: "ready - started server on http://localhost:3000",
  truncated: false,
  version: 4,
};

const row = (shell: ShellRun): AcpmuxRow => ({
  id: `shell-${shell.id}`,
  kind: "userShell",
  at: shell.startedAt,
  version: shell.version,
  shell,
});

const move: AcpmuxRow = {
  id: "gallery-move",
  kind: "move",
  at: now,
  version: 1,
  text: "Build workspace",
};

type Props = { row: AcpmuxRow; expanded?: boolean };

function GalleryShellRow({ row: input, expanded: initialExpanded = false }: Props) {
  const [expanded, setExpanded] = useState(initialExpanded);
  const [receipt, setReceipt] = useState("");
  const shell = input.shell;

  if (!shell) return <MoveRow row={input} />;

  return (
    <div className="acpmux-shell-row-gallery-stage">
      <ShellActionsContext.Provider
        value={{
          stop: (id) => setReceipt(`Stop requested for ${id}`),
          openInTerminal: (run) => setReceipt(`Opened ${run.command} in a terminal`),
        }}
      >
        <ShellRow row={input} expanded={expanded} onToggleActivity={() => setExpanded((value) => !value)} />
      </ShellActionsContext.Provider>
      <output className="acpmux-shell-row-gallery-receipt" data-testid="gallery-receipt" aria-live="polite">
        {receipt}
      </output>
    </div>
  );
}

const stop: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /Stop/ });
  await ctx.waitFor(
    () =>
      ctx.document.querySelector('[data-testid="gallery-receipt"]')?.textContent?.includes("Stop requested") ?? false,
  );
};

const openInTerminal: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Open in terminal" });
  await ctx.waitFor(
    () => ctx.document.querySelector('[data-testid="gallery-receipt"]')?.textContent?.includes("Opened") ?? false,
  );
};

const keyboardOpen: Play = async (ctx) => {
  await ctx.focus({ role: "button", name: "Open in terminal" });
  await ctx.press("Enter");
  await ctx.waitFor(
    () => ctx.document.querySelector('[data-testid="gallery-receipt"]')?.textContent?.includes("Opened") ?? false,
  );
};

const expandOutput: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Show all output" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Show less" }));
};

export default componentEntry<Props>({
  id: "agent-pane.shell-rows",
  title: "Shell transcript rows",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 390, normal: 640, wide: 860 },
  anchors: [{ selector: ".acpmux-shell-block" }],
  covers: [
    "agent-session/acpmux/shell/ShellRow.tsx#ShellActionsContext",
    "agent-session/acpmux/shell/ShellRow.tsx#ShellRow",
    "agent-session/acpmux/shell/MoveRow.tsx#MoveRow",
  ],
  load: async () => GalleryShellRow,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("./ShellRow.gallery.css"),
    ]),
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Expanding shell output and triggering a shell action must not move the shell block anchor.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Shell row controls should remain responsive while output disclosure updates the transcript.",
    },
    settleMaxMs: {
      value: 250,
      reason: "Stop, Open in terminal, and output disclosure are local state updates and should settle promptly.",
    },
  },
  variants: {
    running: {
      note: "A running command exposes Stop with the Control-C hint and keeps Open in terminal available.",
      props: { row: row(running) },
    },
    "stop-receipt": { props: { row: row(running) }, play: stop },
    collapsed: {
      note: "Closed long output keeps the last eight lines and offers Show all output.",
      props: {
        row: row({
          ...running,
          id: "gallery-long",
          command: "pnpm build",
          status: "done",
          endedAt: now - 500,
          output: longOutput,
          version: 3,
        }),
      },
    },
    expanded: {
      props: {
        row: row({
          ...running,
          id: "gallery-long-expanded",
          command: "pnpm build",
          status: "done",
          endedAt: now - 500,
          output: longOutput,
          version: 3,
        }),
        expanded: true,
      },
    },
    "expand-output": {
      note: "Show all output reveals the complete transcript and changes to Show less without moving the block.",
      props: {
        row: row({
          ...running,
          id: "gallery-long-play",
          command: "pnpm build",
          status: "done",
          endedAt: now - 500,
          output: longOutput,
          version: 3,
        }),
      },
      play: expandOutput,
    },
    succeeded: { props: { row: row(done) }, play: openInTerminal },
    failed: { props: { row: row(failed) } },
    stopped: { props: { row: row(stopped) } },
    "keyboard-open": {
      note: "Open in terminal is a real button and remains keyboard activatable.",
      props: { row: row(done) },
      play: keyboardOpen,
    },
    moved: {
      note: "A chat move is rendered as the same quiet date-line treatment used in the transcript.",
      props: { row: move },
    },
  },
});
