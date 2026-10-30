// l10n-allow-file: gallery fixture commands and output, not shipped copy.
// An opened step of a "Ran N commands" group (CommandRow.tsx → ShellBlock.tsx), as Claude Code
// desktop opens one (Leo 2026-10-29: "we want to have that capabilitiy of rendering like claude code
// desktop has stuff organized"): the command in a block of its own, its words in their code colors
// (shellHighlight.ts), then its output in mono, a long one scrolling inside an eight-line box.
// States: short output, very long output, a failing command and a command still streaming.
// Versions: the shipped one (command over its output, a hairline between them, "$" leading the
// first line), a command block apart from the output, and a "$" gutter the command's lines and the
// output both align after.
import { useEffect } from "react";
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import { tool } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import { CommandRow } from "./CommandRow";
import { TranscriptDisclosureProvider, resetTranscriptDisclosure } from "./transcriptDisclosure";

type Look = "hairline" | "split" | "gutter";
type Case = "short" | "long" | "failed" | "streaming";
type Props = { look: Look; state: Case; mode: "light" | "dark" };

const GREP = `grep -nE "useMoreBelow|data-more-below" src/conversation/*.tsx | head -n 5`;
const LONG = Array.from(
  { length: 60 },
  (_, n) => `ok ${String(n + 1).padStart(2)} - transcript › step body › case ${n + 1} (${(n * 7) % 40}ms)`,
).join("\n");

const steps: Record<Case, () => ReturnType<typeof tool>> = {
  short: () =>
    tool(GREP, "execute", "completed", {
      command: GREP,
      output:
        "src/conversation/ToolRow.tsx:32:import { useMoreBelow } from './moreBelow';\nsrc/conversation/moreBelow.ts:9:export const MORE_BELOW = 'data-more-below';\n",
      exitCode: 0,
    }),
  long: () =>
    tool("bun test", "execute", "completed", {
      command: `cd ~/src/atlas && BUN_ENV=test bun test --reporter=spec 2>&1 | tee "$TMPDIR/run.log"`,
      output: `${LONG}\n\n60 pass\n0 fail\n`,
      exitCode: 0,
    }),
  failed: () =>
    tool("cargo check", "execute", "failed", {
      command: `cargo check -p atlas-core --features 'sync,net' && echo "built $(git rev-parse --short HEAD)"`,
      output:
        "    Checking atlas-core v0.4.1\nerror[E0425]: cannot find value `retry_budget` in this scope\n  --> crates/atlas-core/src/net.rs:88:17\n   |\n88 |         if retry_budget == 0 {\n   |            ^^^^^^^^^^^^ not found in this scope\n\nerror: could not compile `atlas-core` (lib) due to 1 previous error\n",
      exitCode: 101,
    }),
  streaming: () =>
    tool("bun run build", "execute", "in_progress", {
      command: `for pkg in core web cli; do bun run --cwd "packages/$pkg" build || exit 1; done`,
      output: LONG.split("\n").slice(0, 23).join("\n"),
    }),
};

function ShellStepBodyGallery({ look, state, mode }: Props) {
  const session = `gallery-shell-step-${look}-${state}`;
  useEffect(() => resetTranscriptDisclosure(session), [session]);
  return (
    <TranscriptDisclosureProvider sessionId={session}>
      <main className="shell-step-gallery acpmux-conversation" data-mode={mode} data-look={look} data-shell-step>
        <div className="cv-tools">
          <CommandRow item={steps[state]()} />
        </div>
      </main>
    </TranscriptDisclosureProvider>
  );
}

/// Opens the step and waits for its Shell block.
const open: Play = async (ctx) => {
  await ctx.click({ selector: "[data-shell-step] button.cv-command" });
  await ctx.waitFor(() => ctx.document.querySelector("[data-shell-step] .cv-shell__command"));
};

const variant = (look: Look, state: Case, mode: Props["mode"], note: string): ComponentVariant<Props> => ({
  note: `${note} ${mode === "dark" ? "Dark" : "Light"} theme.`,
  props: { look, state, mode },
  play: open,
});

const LOOKS: Record<Look, string> = {
  hairline: "Shipped: the command over its output, a hairline between them.",
  split: "The command in a block apart from the output.",
  gutter: "A $ gutter the command's lines and the output align after.",
};
const CASES: Record<Case, string> = {
  short: "Short output.",
  long: "Sixty lines of output scrolling inside an eight-line box.",
  failed: "A failing command and its exit code.",
  streaming: "A command still running, its output following the newest line.",
};

const variants: Record<string, ComponentVariant<Props>> = {};
for (const look of Object.keys(LOOKS) as Look[])
  for (const state of Object.keys(CASES) as Case[]) {
    const name = look === "hairline" ? state : `${look}-${state}`;
    variants[name] = variant(look, state, "light", `${LOOKS[look]} ${CASES[state]}`);
    if (look === "hairline") variants[`${state}-dark`] = variant(look, state, "dark", `${LOOKS[look]} ${CASES[state]}`);
  }

export default componentEntry<Props>({
  id: "agent-pane.shell-step-body",
  title: "Command step: highlighted command and output",
  area: "Agent pane",
  pane: true,
  height: 520,
  widths: { narrow: 420, normal: 640, wide: 900 },
  anchors: [{ selector: "[data-shell-step] .cv-tools > :first-child" }],
  covers: [
    "agent-session/acpmux/conversation/ShellBlock.tsx#ShellBlock",
    "agent-session/acpmux/conversation/ShellBlock.tsx#ShellCommand",
  ],
  styles: () => import("./ShellStepBody.gallery.css"),
  load: async () => ShellStepBodyGallery,
  keywords: ["shell", "command", "highlight", "syntax", "output", "scroll", "step"],
  variants,
});
