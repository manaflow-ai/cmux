// l10n-allow-file: gallery fixtures (sample commands and output), not shipped UI.
// A new worktree chat's setup line (worktreeSetup.tsx, design/worktree-setup.md). Three looks were
// built for the same states; `line` ships (the notice row "Creating worktree…" already uses, with
// the Cloud start's checklist rows under Output). `card` and `tail` are the alternatives the
// design note compares; they are drawn here from the same pieces and do not ship.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { WorktreeSetupRun } from "../../worktreeRecipe";
import type { SetupView } from "./worktreeSetup";

type Look = "line" | "card" | "tail";
type Props = { look?: Look; creating?: boolean; view?: SetupView; open?: boolean; runnable?: boolean };

const STARTED = 1_762_500_000_000;
const OUTPUT = [
  "$ bun install",
  "bun install v1.3.1 (9f2a1c4e)",
  "Resolving dependencies",
  "Resolved, downloaded and extracted [1408]",
  "+ @base-ui/react@1.0.0",
  "+ react@19.2.0",
  "1408 packages installed [6.21s]",
  "$ cp .env.example .env.local",
].join("\n");

function view(state: WorktreeSetupRun["state"], extra: Partial<WorktreeSetupRun> = {}, output = OUTPUT): SetupView {
  return {
    run: {
      state,
      port: 40_010,
      setup: "bun install && cp .env.example .env.local",
      include: { copied: 3, kept: 0, outside: [], problems: [] },
      startedMs: STARTED,
      output,
      outputStart: "0",
      outputEnd: String(output.length),
      ...extra,
    },
    output,
    read: true,
  };
}

// A running setup's time ticks from now in the app; `finishedMs` pins it so captures match.
const running = view("running", { finishedMs: STARTED + 12_400 }, OUTPUT.split("\n").slice(0, 4).join("\n"));
const succeeded = view("succeeded", { exitCode: 0, finishedMs: STARTED + 14_200 });
const failed = view(
  "failed",
  { exitCode: 1, finishedMs: STARTED + 4_100 },
  "$ bun install\nbun install v1.3.1 (9f2a1c4e)\nerror: lockfile had changes, but lockfile is frozen\nnote: try re-running without --frozen-lockfile",
);
const copying = view("copying", { finishedMs: STARTED + 600 }, "");
const copiedOnly: SetupView = (() => {
  const base = view("succeeded", { finishedMs: STARTED + 300 }, "");
  const { setup: _setup, ...run } = base.run;
  return { ...base, run };
})();

// A repository's `.cmux/worktree.toml` waits for the person before anything copies or runs.
const recipe = (approved: boolean) => ({
  setup: "bun install && cp .env.example .env.local",
  run: "bun run dev --port $CMUX_PORT",
  teardown: "docker compose down",
  include: [".env", "config/local.json"],
  repository: {
    setup: "bun install && cp .env.example .env.local",
    teardown: "docker compose down",
    include: [".env"],
  },
  files: [".worktreeinclude", ".cmux/worktree.toml"],
  approval: { fingerprint: "3f9a1c", approved },
});
const awaiting: SetupView = (() => {
  const base = view("awaiting_approval", {}, "");
  const { startedMs: _startedMs, setup: _setup, ...run } = base.run;
  return { ...base, run, recipe: recipe(false) };
})();
const retryable: SetupView = { ...failed, recipe: recipe(true) };

export default componentEntry<Props>({
  id: "agent-pane.worktree-setup",
  title: "Worktree setup line",
  area: "Agent pane",
  pane: true,
  height: 340,
  widths: { narrow: 360, normal: 720, wide: 900 },
  covers: ["agent-session/acpmux/worktreeSetup.tsx"],
  load: async () => {
    const { WorktreeSetupLine, SetupDetails, SetupMark, setupFacts, setupLabel, setupStatus } =
      await import("./worktreeSetup");
    const { useT } = await import("./i18n");
    const { lastOutputLine } = await import("../../worktreeRecipe");

    /** Alternative: the Cloud start's bordered card, its rows always shown. */
    function CardLook({ view: shown }: { view: SetupView }) {
      const t = useT();
      const status = setupStatus(shown.run.state);
      return (
        <div className="acpmux-switch-notice">
          <div className="acpmux-cloud-start__card" data-look="card">
            <div className="acpmux-cloud-start__summary">
              <SetupMark status={status} />
              <span>{setupLabel(shown.run, t)}</span>
              <span className="acpmux-cloud-start__time">{setupFacts(shown.run, STARTED + 12_400, t).join(" · ")}</span>
            </div>
            <div className="acpmux-cloud-start__details">
              <SetupDetails view={shown} now={STARTED + 12_400} hasScript />
            </div>
          </div>
        </div>
      );
    }

    /** Alternative: the line, with the output's last line always under it (the Cloud log tail). */
    function TailLook({ view: shown }: { view: SetupView }) {
      const t = useT();
      return (
        <output className="acpmux-switch-notice acpmux-worktree-setup" data-state={shown.run.state}>
          <span className="acpmux-worktree-setup__summary">
            <SetupMark status={setupStatus(shown.run.state)} />
            <span className="acpmux-worktree-setup__label">{setupLabel(shown.run, t)}</span>
            {setupFacts(shown.run, STARTED + 12_400, t).map((fact) => (
              <span key={fact} className="acpmux-worktree-setup__fact">
                {fact}
              </span>
            ))}
          </span>
          <span className="acpmux-cloud-start__log-tail">{lastOutputLine(shown.output)}</span>
        </output>
      );
    }

    return function GalleryWorktreeSetup({
      look = "line",
      creating = false,
      view: shown,
      open = false,
      runnable = false,
    }: Props) {
      const [dismissed, setDismissed] = useState(false);
      const [ran, setRan] = useState(false);
      return (
        <div className="acpmux-shell">
          <div style={{ height: 96 }} aria-hidden />
          {dismissed ? null : look === "card" && shown ? (
            <CardLook view={shown} />
          ) : look === "tail" && shown ? (
            <TailLook view={shown} />
          ) : (
            <WorktreeSetupLine
              creating={creating}
              view={shown}
              defaultOpen={open}
              onDismiss={() => setDismissed(true)}
              {...(runnable ? { onRun: () => setRan(true) } : {})}
              runPending={ran}
            />
          )}
          <div className="acpmux-composer-box" style={{ height: 96 }} />
        </div>
      );
    };
  },
  styles: () => Promise.all([import("./styles.css"), import("./cloudStart.css"), import("./worktreeSetup.css")]),
  anchors: [{ selector: ".acpmux-worktree-setup__summary" }],
  variants: {
    creating: {
      props: { creating: true },
      note: "New Worktree while the host makes it: the row every later state draws in.",
    },
    copying: { props: { view: copying }, note: "The recipe copies its .worktreeinclude files from the main checkout." },
    running: {
      props: { view: running },
      note: "Shipped look: the setup script runs; its time, the worktree's port, Output.",
    },
    "running-output": {
      props: { view: running, open: true },
      note: "Output open: the Cloud start's rows (Copy files, Run setup script) and the output, the composer moved down with it.",
    },
    "output-toggle": {
      props: { view: running },
      note: "Play: Output opens the drawer under the line; the line itself does not move.",
      play: (async (ctx) => {
        await ctx.click({ role: "button", name: "Output" });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-worktree-setup__drawer[data-open="true"]'));
      }) satisfies Play,
    },
    succeeded: { props: { view: succeeded }, note: "Finished: its time and port, Output, and Dismiss." },
    "copied-only": { props: { view: copiedOnly }, note: "A recipe with only files to copy and no setup script." },
    failed: {
      props: { view: failed },
      note: "Failed with exit 1: the line says so in the danger ink and opens its output once by itself.",
    },
    "awaiting-approval": {
      props: { view: awaiting, runnable: true },
      note: "A repository's setup waits for the person: its commands and the ignored files it copies (this worktree only), open, with Run Setup.",
    },
    "run-setup": {
      props: { view: awaiting, runnable: true },
      note: "Play: Run Setup approves the recipe read above it; the button waits until the host answers.",
      play: (async (ctx) => {
        await ctx.click({ role: "button", name: "Run Setup" });
        await ctx.waitFor(() =>
          ctx.document.querySelector<HTMLButtonElement>(".acpmux-worktree-setup button:disabled"),
        );
      }) satisfies Play,
    },
    retry: {
      props: { view: retryable, runnable: true },
      note: "A failed setup of an approved recipe offers Retry next to Dismiss.",
    },
    "look-card": {
      props: { look: "card", view: running },
      note: "Alternative (not shipped): the Cloud start's bordered card with its rows always open. Heavy above a composer.",
    },
    "look-tail": {
      props: { look: "tail", view: running },
      note: "Alternative (not shipped): the line plus the output's last line, always. Jumps as lines wrap.",
    },
  },
});
