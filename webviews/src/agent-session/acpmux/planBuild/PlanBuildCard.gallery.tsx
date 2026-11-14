// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { PlanBuildCard } from "./PlanBuildCard";
import type { PlanBuild, PlanBuildReply } from "./planBuild";

type Props = { build: PlanBuild; diffs?: PlanBuildReply; live?: boolean };

const claude = {
  sessionId: "build-claude",
  name: "Claude",
  harness: "claude",
  branch: "cmux/rate-limit-retries",
  base: "main",
};
const codex = {
  sessionId: "build-codex",
  name: "Codex",
  harness: "codex",
  branch: "cmux/rate-limit-retries-2",
  base: "main",
};

const running: PlanBuild = {
  buildId: "b1",
  target: "compare",
  builds: [
    { ...claude, state: "running" },
    { ...codex, state: "running" },
  ],
  archived: [],
  turnsEnded: 0,
};
const done: PlanBuild = {
  ...running,
  builds: [
    { ...claude, state: "done" },
    { ...codex, state: "done" },
  ],
  turnsEnded: 2,
};
const diffs: PlanBuildReply = {
  buildId: "b1",
  builds: [
    {
      sessionId: claude.sessionId,
      branch: claude.branch,
      added: 184,
      removed: 37,
      files: [
        { path: "src/net/retry.ts", added: 96, removed: 12 },
        { path: "src/net/retry.test.ts", added: 61, removed: 0 },
        { path: "src/net/client.ts", added: 14, removed: 19 },
        { path: "src/config/defaults.ts", added: 6, removed: 2 },
        { path: "docs/networking.md", added: 7, removed: 4 },
      ],
    },
    {
      sessionId: codex.sessionId,
      branch: codex.branch,
      added: 241,
      removed: 58,
      files: [
        { path: "src/net/backoff.ts", added: 88, removed: 0 },
        { path: "src/net/backoff.test.ts", added: 72, removed: 0 },
        { path: "src/net/client.ts", added: 31, removed: 40 },
        { path: "src/net/errors.ts", added: 18, removed: 6 },
        { path: "src/config/defaults.ts", added: 9, removed: 3 },
        { path: "src/config/schema.ts", added: 12, removed: 5 },
        { path: "docs/networking.md", added: 6, removed: 2 },
        { path: "CHANGELOG.md", added: 5, removed: 2 },
      ],
    },
  ],
};
const kept: PlanBuild = { ...done, keptSessionId: claude.sessionId, archived: [codex.sessionId] };
const worktree: PlanBuild = {
  buildId: "b2",
  target: "worktree",
  builds: [{ ...claude, state: "running" }],
  archived: [],
  turnsEnded: 0,
};

/// The card as a chat draws it under the plan it was approved from. `live`: Keep answers as acpmux
/// would, so the play can press it.
function GalleryPlanBuild({ build, diffs, live }: Props) {
  return (
    <div className="acpmux-shell">
      <div data-plan-build-fixture style={{ flex: 1, minWidth: 0, padding: 12 }}>
        <PlanBuildCard
          build={build}
          sessionId="parent"
          diffs={live ? undefined : diffs}
          onOpen={() => undefined}
          compare={async () => diffs ?? { buildId: build.buildId, builds: [] }}
          keep={async (_session, _build, keep) => ({ ...diffs, keptSessionId: keep })}
        />
      </div>
    </div>
  );
}

const keepClaude: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-plan-builds-keep" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-outcome="kept"]'));
};

export default componentEntry<Props>({
  id: "agent-pane.plan-build",
  title: "Plan build card",
  area: "Agent pane",
  pane: true,
  height: 420,
  widths: { narrow: 360, normal: 560, wide: 760 },
  anchors: [{ selector: "[data-plan-build-fixture]" }],
  covers: ["agent-session/acpmux/planBuild/PlanBuildCard.tsx#PlanBuildCard"],
  styles: () => import("../styles.css"),
  load: async () => GalleryPlanBuild,
  variants: {
    running: {
      note: "Build on two agents and compare, just started: both columns Working, every line reserved so nothing moves when diffs arrive.",
      props: { build: running },
    },
    done: {
      note: "Both builds finished: each column's +/− and first files, the second with more files than it lists; Keep this one on each.",
      props: { build: done, diffs },
    },
    kept: {
      note: "Claude's build kept: its column says Kept, Codex's Archived and dims, the heading says the other is archived, never deleted. Same height as done.",
      props: { build: kept, diffs },
    },
    "keep-press": {
      note: "Done, then Keep this one pressed on the first column: the card moves to the kept state in place.",
      props: { build: done, diffs, live: true },
      play: keepClaude,
    },
    worktree: {
      note: "Build in a new worktree: one column with Open, no Keep.",
      props: { build: worktree },
    },
  },
});
