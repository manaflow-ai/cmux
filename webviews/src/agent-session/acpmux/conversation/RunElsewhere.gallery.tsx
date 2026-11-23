// l10n-allow-file: gallery fixtures (sample commands, paths and machine names), not shipped UI.
// "Run on a bigger machine" (RunElsewhere.tsx) on the real CommandRow and ToolRow, over a stand-in
// for acpmux's `_acpmux/run_elsewhere/*` and `_acpmux/bg/output`. Three chip looks, then the states
// under the row: the panel that shows what goes, a command that stays here (acpmux's reason, the
// app's host refusing to relay the run, no machine) in three looks, the run streaming, and runs that
// ended. References: claude/live/panel-environment (plain rows with a small machine icon, a caption
// over each group, no card chrome), claude/live/transcript-new-session-proposal-card (a ghost
// secondary action beside one solid primary) and claude/live/transcript-tool-rows-and-task-list
// (a row's status is quiet dim text, never a card).
import { useMemo } from "react";
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxActivity } from "../model";
import { CommandRow } from "./CommandRow";
import { afterPlan, afterPlanError } from "./RunElsewhere";
import { ToolRow } from "./ToolRow";
import {
  RunElsewhereContext,
  RunElsewhereStore,
  resetHostRelays,
  type RunElsewhere,
  type RunPlan,
  type RunState,
} from "./runElsewhereModel";
import { TranscriptDisclosureProvider } from "./transcriptDisclosure";

type Look = "text" | "icon" | "accent";
type Shown = "chip" | "panel" | "refused" | "host-refused" | "no-machine" | "running" | "finished" | "failed";
/** How a command that stays here reads: the shipped quiet line, the reason at the row's edge, or
 * the line in the panel's card chrome. */
type NoteLook = "line" | "edge" | "card";
type Props = { look: Look; shown: Shown; note?: NoteLook };

/** Long ago, so the chip's 20 s have passed in every capture. */
const STARTED = Date.UTC(2026, 10, 8, 10, 0, 0);

const call = (id: string, command: string): AcpmuxActivity => ({
  kind: "tool",
  text: command,
  tool: { id, title: command, kind: "execute", status: "in_progress", command, startedAt: STARTED },
});

const PLAN: RunPlan = {
  eligible: true,
  machines: [
    { name: "build-box", ok: true },
    { name: "gpu-mini", ok: true },
    { name: "laptop", ok: false, why: "not connected now" },
  ],
  tree: {
    origin: "https://github.com/acme/app.git",
    base: "4f1c2a9be03d7e51a2c6f0b8d9e4a7c3b1f05e62",
    prefix: "",
    files: [
      { path: "crates/core/src/lib.rs", status: "M", secret: false },
      { path: "crates/core/src/cache.rs", status: "A", secret: false },
      { path: "crates/core/src/old_cache.rs", status: "D", secret: false },
      { path: ".env.local", status: "M", secret: true },
    ],
    untracked: ["notes.md", "scratch/bench.txt", "target-old/x"],
    untrackedTotal: 9,
    patchBytes: 18_204,
    digest: "c0ffee",
  },
};

const OUTPUT = `[cmux] running on build-box at 4f1c2a9be03d with 4 changed file(s)
   Compiling cmux-core v0.1.0 (/home/me/.cache/cmux-run-elsewhere/acme-app-1a2b3c/work/crates/core)
    Finished \`test\` profile [unoptimized + debuginfo] target(s) in 41.2s
     Running unittests src/lib.rs
running 214 tests
test cache::evicts_oldest ... ok
test cache::keeps_hot ... ok
`;

function stateFor(shown: Shown, store: RunElsewhereStore): RunState | undefined {
  switch (shown) {
    case "chip":
      return undefined;
    case "panel":
      return { phase: "choosing", plan: PLAN, machine: "build-box", send: [] };
    case "refused":
      return afterPlan({ eligible: false, why: "vim needs this machine", machines: PLAN.machines });
    case "host-refused": {
      const state = afterPlanError(
        { store, client: NEVER_CLIENT },
        { code: "transport.method_refused", message: "Refused by the cmux host" },
      );
      // This stage's store keeps the refusal (its chips go); the gallery's other stages do not.
      resetHostRelays();
      return state;
    }
    case "no-machine":
      return afterPlan({ ...PLAN, machines: [] });
    case "running":
      return { phase: "running", machine: "build-box", taskId: "bg-1", output: OUTPUT };
    case "finished":
      return {
        phase: "ended",
        machine: "build-box",
        taskId: "bg-1",
        output: `${OUTPUT}test result: ok. 214 passed; 0 failed\n`,
        exitCode: 0,
        state: "exited",
      };
    case "failed":
      return {
        phase: "ended",
        machine: "build-box",
        taskId: "bg-1",
        output: `${OUTPUT}test cache::spills ... FAILED\ntest result: FAILED. 213 passed; 1 failed\n`,
        exitCode: 101,
        state: "exited",
      };
  }
}

const never = () => new Promise<never>(() => undefined);
const NEVER_CLIENT = { plan: never, start: never, output: never, stop: async () => undefined };

function Stage({ look, shown, note = "line" }: Props) {
  const runs = useMemo<RunElsewhere>(() => {
    const store = new RunElsewhereStore();
    const state = stateFor(shown, store);
    if (state) store.set("test", state);
    return { store, client: { ...NEVER_CLIENT, plan: async () => PLAN } };
  }, [shown]);
  return (
    <TranscriptDisclosureProvider sessionId="gallery-run-elsewhere">
      <RunElsewhereContext.Provider value={runs}>
        <div className="acpmux-shell cv-run-elsewhere-looks" data-look={look} data-note={note} style={{ padding: 16 }}>
          <div className="cv-tools">
            <CommandRow item={call("test", "cargo test -p cmux-core")} />
          </div>
          <div className="cv-tools">
            <ToolRow item={call("build", "make -j8 release")} />
          </div>
        </div>
      </RunElsewhereContext.Provider>
    </TranscriptDisclosureProvider>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.run-elsewhere",
  title: "Run on a bigger machine",
  area: "Agent pane",
  pane: true,
  covers: [
    "agent-session/acpmux/conversation/RunElsewhere.tsx#RunElsewhereChip",
    "agent-session/acpmux/conversation/RunElsewhere.tsx#RunElsewhereBelow",
  ],
  load: async () => Stage,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../../../ui/controls.css"),
      import("./conversation.css"),
      import("./RunElsewhere.gallery.css"),
    ]),
  height: 420,
  widths: { narrow: 360, normal: 640 },
  anchors: [
    { selector: ".cv-run-elsewhere-chip" },
    { selector: ".cv-run-elsewhere" },
    { selector: ".cv-run-elsewhere-line" },
  ],
  variants: {
    text: {
      note: "Shipped look: a small machine icon and the words in the row's dim ink at its trailing edge, accent on hover. It arrives 20 s into a running command, in the slot a running row leaves empty, so nothing moves.",
      props: { look: "text", shown: "chip" },
    },
    icon: {
      note: "Alternative: the icon alone, the words in its tooltip. Quietest, but a person has to hover to learn what it does, and the point is to be found.",
      props: { look: "icon", shown: "chip" },
    },
    accent: {
      note: "Alternative: the words in the accent at rest, as the dev server chip. Louder than any other mark on a running row; two accent chips on one row compete.",
      props: { look: "accent", shown: "chip" },
    },
    panel: {
      note: "A click opens what goes under the row: the commit, each changed file, the secret-looking file left out unless ticked, the untracked files that stay. Cancel is the design system's ghost button and Run its one solid one (ui/Button.tsx), with no keycaps: Return runs it and Escape closes from anywhere in the panel.",
      props: { look: "text", shown: "panel" },
    },
    refused: {
      note: "Shipped: a command that needs this machine (an editor, sudo, a local service) gets one quiet line under the row's words with acpmux's reason, in the failed call's cause grammar. No card, no Cancel: nothing to press.",
      props: { look: "text", shown: "refused", note: "line" },
    },
    "refused-edge": {
      note: "Alternative: the reason at the row's trailing edge, where the chip was. Keeps the row one line, but a reason that long is cut to a few words there, so it never says why.",
      props: { look: "text", shown: "refused", note: "edge" },
    },
    "refused-card": {
      note: "Alternative: the same line in the panel's ring and fill. Reads as something to act on, which is what the card with a Cancel did wrong: it adds weight for a status.",
      props: { look: "text", shown: "refused", note: "card" },
    },
    "host-refused": {
      note: 'This app\'s host does not relay the run (an app older than the feature): the line says so in plain words instead of "Refused by the cmux host", and the chip goes from every row of the chat.',
      props: { look: "text", shown: "host-refused" },
    },
    "no-machine": {
      note: "Nothing connected: the same one quiet line, pointing to Machines.",
      props: { look: "text", shown: "no-machine" },
    },
    running: {
      note: "The run streams under the original row, as its own shell would; Stop ends it on the other machine.",
      props: { look: "text", shown: "running" },
    },
    finished: {
      note: "Ended with exit 0: Finished, the whole output kept to read.",
      props: { look: "text", shown: "finished" },
    },
    failed: {
      note: "Ended with a nonzero exit: the line takes the failure ink and names the code.",
      props: { look: "text", shown: "failed" },
    },
  },
});
