// l10n-allow-file: gallery fixtures (sample sessions, pull requests and commands), not shipped UI.
// Session Info (Debug Settings `agent.sessionInfo`, on by default) as the real SessionInfo renders it
// in its panel at the right of a chat: a full chat with every section, its Context and Connectors
// open, its Changes across repositories with line breakdowns, comments, failing checks and owners
// (all of them after Show more), its running subagents and chats named one per line with the ended
// ones folded into one row (and that row open), a busy chat's seventeen running past "Show more", the
// running lines' wave held mid-sweep, its finished tasks open (a background Bash only the transcript
// knows among them), a Cloud chat before its first usage report, a chat with little to show (the
// card ends at its content) beside a busy one (the card stops at its ceiling and scrolls), and the
// panel over the chat (Overlay). Light and dark come from the gallery's theme switch.
// A subagent's own panel (Leo, 2026-10-21: "subagent should have its own instance of it like it might
// have different env worktree context bg tasks outputs and diffs etc"): one working in a Claude
// worktree of its own, its environment, tokens, background test run and diffs its own, under three
// ways to say whose panel it is (the head's title, the one drawn; a path; a card); one sharing the
// chat's checkout; and the chat's panel beside them, its Subagents listing it.
import { useState, type ComponentProps, type CSSProperties } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play, PlayContext } from "../../../gallery/play";
import { WAVE_CLASS, WAVE_KEYFRAMES } from "../../../ui/wave";
import { activity, assistant, chat, CONTEXT_BREAKDOWN, CWD, tool } from "../../../gallery/fixtures/acpmux";
import type { StartedSession } from "../started/startedSessions";
import type { Subagent } from "../subagents/subagentFold";
import { createWorkflowAdapter } from "../summary/foldWorkflows";
import { sessionSummary, type SummaryWakeup } from "../summary/sessionSummary";
import { workflowFixture, type WorkflowFixtureStage } from "../summary/workflowFixture";
import { SessionInfo, SessionInfoPanel, type SessionInfoPlacement } from "./SessionInfo";
import { SubagentBanner, SubagentTitle, type SubagentHeaderVariant } from "./SubagentScopeHeader";
import { subagentSummary, type SubagentScope } from "./subagentScope";
import { outputArtifacts } from "./OutputsSection";
import { DEFAULT_SECTIONS } from "./sessionInfoState";
import { sessionEntry, type AcpmuxSessionEntry } from "../sessionList";
import type { SessionUsageStats } from "../usageStats";

type Props = ComponentProps<typeof SessionInfo> & {
  placement?: SessionInfoPlacement;
  transcript?: boolean;
  /// Its own head with the close button, as the chat draws it.
  closable?: boolean;
  /// Gallery-only chrome choices for the Session Info surface.
  chrome?: "title" | "close" | "compact-close";
  /// A subagent's panel: whose it is, said the `header` way.
  scope?: Pick<SubagentScope, "agent" | "parent" | "onBack">;
  header?: SubagentHeaderVariant;
  /// A gallery-only palette for the Context breakdown's categories (ContextSection.css tones).
  tones?: CSSProperties;
  /// Gallery-only: a different height ceiling, for comparison with the shipped full-room one.
  ceiling?: string;
  /// Gallery-only: a different edge look, for comparison with the shipped hairline (sessionInfo.css).
  edge?: string;
  /// Gallery-only: panel width used by narrow workflow layout states.
  panelWidth?: number;
  /// Gallery-only: the old always-drawn thin thumb, for comparison with the shipped no-scrollbar body.
  scroller?: "thumb";
};

const edit = (path: string, oldText: string | undefined, newText: string) =>
  tool(`Edit ${path}`, "edit", "completed", { diffs: [{ path: `${CWD}/${path}`, oldText, newText }] });

const local = chat([
  activity(
    [
      edit("src/net/fetch.ts", "export const tries = 1;\n", "export const tries = 3;\nexport const backoff = 200;\n"),
      edit("src/net/retry.ts", undefined, "export async function retry() {}\n"),
      edit("test/retry.test.ts", undefined, "test('retries', () => {});\n"),
    ],
    4,
  ),
]);
const made = sessionSummary(local.rows);

/// A busy transcript under the panel (prompts, replies, code), so its glass shows what it lies over.
const TRANSCRIPT = [
  "Make Session Info glass, and its cards bordered with no fill.",
  "The panel paints the chat's page color, so nothing behind it shows. I'll give it the shared glass and drop the cards' fill.",
  '<aside className="ui-glass ui-glass-floats acpmux-session-info">\n  {sections}\n</aside>',
  "Check it over a long transcript in light and dark.",
  "Over the transcript the text frosts under the panel and the cards keep only their hairline.",
  "export const tries = 3;\nexport const backoff = 200;\nexport async function retry() {}",
];
function Transcript() {
  return (
    <div aria-hidden="true" style={{ position: "absolute", inset: 0, overflow: "hidden", padding: "16px 24px" }}>
      {[0, 1, 2].flatMap((round) =>
        TRANSCRIPT.map((line, index) =>
          index % 3 === 0 ? (
            <div key={`${round}-${index}`} className="acpmux-user" style={{ margin: "12px 0" }}>
              <div className="acpmux-user-bubble">{line}</div>
            </div>
          ) : (
            <div key={`${round}-${index}`} className="acpmux-markdown" style={{ margin: "12px 0" }}>
              {index % 3 === 2 ? <pre>{line}</pre> : <p>{line}</p>}
            </div>
          ),
        ),
      )}
    </div>
  );
}

function GallerySessionInfo({
  placement = "overlay",
  transcript = false,
  closable = false,
  chrome = "close",
  scope,
  header = "title",
  tones,
  ceiling,
  edge,
  panelWidth = 320,
  scroller,
  more: moreAtFirst,
  ...props
}: Props) {
  // The panel's Show more, held here so a variant starts where it says and a play can open it.
  const [more, setMore] = useState(moreAtFirst);
  return (
    <div className="acpmux-shell" style={{ display: "flex", justifyContent: "flex-end", height: "100%", ...tones }}>
      {ceiling ? <style>{`.acpmux-session-info[data-placement]{max-height:${ceiling}}`}</style> : null}
      {edge ? <style>{`.acpmux-session-info[data-placement]{${edge}}`}</style> : null}
      {scroller === "thumb" ? <style>{".acpmux-session-info__body{scrollbar-width:thin}"}</style> : null}
      {transcript ? <Transcript /> : null}
      <SessionInfoPanel
        width={panelWidth}
        placement={placement}
        // Over a transcript it floats over the chat's column (a foot), where it is glass; otherwise it
        // sits in the gutter or pushes, with no card (SessionInfo.tsx SessionInfoPanel).
        foot={transcript && placement === "overlay" ? 0 : undefined}
        chrome={chrome}
        // The head draws only with a close: as in the chat pane.
        onClose={scope || closable ? () => undefined : undefined}
        title={scope && header === "title" ? <SubagentTitle scope={scope} /> : undefined}
      >
        <SessionInfo
          {...props}
          more={more}
          onMore={more === undefined ? undefined : setMore}
          banner={scope && header !== "title" ? <SubagentBanner scope={scope} variant={header} /> : undefined}
        />
      </SessionInfoPanel>
    </div>
  );
}

/// Pull requests the chat opened or changed across repositories (oldest first, as sessionSummary
/// reads them). Read-only references appear in Sources below.
const pullRequests: NonNullable<Props["made"]>["pullRequests"] = [
  { n: 22217, title: "cmux NEXT: Cmd-W closes a pinned tab's split", opened: true, state: "merged" },
  { repo: "acme/billing", n: 7, title: "billing: retry webhooks on a 502", opened: false, state: "closed" },
  { n: 22227, title: "New Tab Now Playing: right-click menu and a setting to hide it", opened: false },
  { n: 22228, title: "cmux NEXT: the thread minimap feels like the Codex rail", opened: true },
  { n: 22229, title: "cmux NEXT Home list: one-row sessions", opened: true, state: "merged" },
  { repo: "acme/atlas-web", n: 412, title: "atlas: dark mode tokens for the settings page", opened: true },
  { n: 22231, title: "cmux NEXT New Tab: paste an image into the composer", opened: true },
  { n: 22240, title: "Session Info: the chat's right-hand panel", opened: true },
].map(({ repo = "manaflow-ai/cmux", n, title, opened, state = "open" }) => ({
  url: `https://github.com/${repo}/pull/${n}`,
  repo,
  number: n,
  title,
  opened,
  state: state as "open" | "merged" | "closed",
}));
const pr = (n: number, repo = "manaflow-ai/cmux") => `https://github.com/${repo}/pull/${n}`;
/// What the App read of them: line counts split by kind, comments, failing checks against the
/// base, a draft, one with conflicts, owners.
const statuses: NonNullable<Props["statuses"]> = {
  [pr(22240)]: {
    additions: 1_482,
    deletions: 311,
    breakdown: {
      code: { additions: 902, deletions: 240 },
      tests: { additions: 410, deletions: 61 },
      generated: { additions: 150, deletions: 10 },
      docs: { additions: 20, deletions: 0 },
    },
    comments: 13,
    checks: "failing",
    failing: 3,
    failingOnBase: 2,
    owner: "session-info",
  },
  [pr(22231)]: { additions: 96, deletions: 12, comments: 2, checks: "passing", owner: "newtab" },
  [pr(412, "acme/atlas-web")]: { additions: 608, deletions: 8, checks: "passing" },
  [pr(22228)]: { state: "draft", additions: 240, deletions: 88, checks: "pending" },
  [pr(22227)]: { mergeable: "conflicting", checks: "failing", failing: 9, owner: "teamleaderleo" },
};

/// Background processes as acpmux's registry lists them: a dev server, a watcher, three finished.
const started = Date.now();
const processes: NonNullable<Props["processes"]> = [
  { id: "s/1", command: "bun test --watch", startedAt: started - 3_740_000, state: "running" },
  {
    id: "s/2",
    command: "cargo build --release",
    startedAt: started - 900_000,
    endedAt: started - 600_000,
    state: "exited",
  },
  { id: "s/3", command: "npm run lint", startedAt: started - 800_000, endedAt: started - 790_000, state: "failed" },
  { id: "s/4", command: "bun run dev --port 5173", startedAt: started - 76_000, state: "running" },
  {
    id: "s/5",
    command: "tail -f logs/server.log",
    startedAt: started - 60_000,
    endedAt: started - 30_000,
    state: "killed",
  },
];

const NAMES = ["Explore", "Review", "Tests", "Docs", "Fleet", "Gallery", "Strings", "Swift", "CI", "Lint", "Base"];
/// Three running subagents and forty that finished.
const agents: Subagent[] = Array.from({ length: 43 }, (_, index) => ({
  id: `agent-${index}`,
  parent: null,
  name: `${NAMES[index % NAMES.length]} ${Math.floor(index / NAMES.length) + 1}`,
  task: "Check one part of the change",
  state: index < 3 ? "running" : index === 7 ? "failed" : "completed",
  startedAt: started - (index + 1) * 120_000,
  ...(index < 3 ? { action: "Reading SessionInfo.tsx" } : { endedAt: started - index * 100_000 }),
}));

/// The running wave (ui/wave.ts, Leo 2026-10-21: "THESE GLIMMER AT DIFFERENT INTERVALS ... it would
/// look cool if they went in a wave, like how thinking glimmers in ChatGPT"): five running subagents,
/// then one done and one failed, which stay out of the wave.
const RUNNING = 5;
const waveAgents: Subagent[] = Array.from({ length: RUNNING + 2 }, (_, index) => ({
  id: `wave-${index}`,
  parent: null,
  name: NAMES[index]!,
  task: "Check one part of the change",
  state: index < RUNNING ? "running" : index === RUNNING ? "completed" : "failed",
  startedAt: started - (index + 1) * 60_000,
  ...(index < RUNNING ? { action: "Reading SessionInfo.tsx" } : { endedAt: started - index * 30_000 }),
}));

/// Leo's Session Info of 2026-11-02 ("but what's going on with these?"): three subagents at work, two
/// that stopped two hours ago and wait on background work of their own (Idle, out of the shimmer and
/// out of "running" in the head too), one met first through its progress and named by its prompt
/// rather than its id, and the chat-start limit named for what it counts.
const idleAgents: Subagent[] = [
  {
    id: "idle-a",
    parent: null,
    name: "Drop server login",
    state: "running",
    startedAt: started - 6_900_000,
    quietSince: started - 6_600_000,
  },
  {
    id: "idle-b",
    parent: null,
    name: "Audit Session Info strings",
    state: "running",
    startedAt: started - 6_890_000,
    quietSince: started - 6_500_000,
  },
  {
    id: "busy-a",
    parent: null,
    name: "Fix the running tray",
    state: "running",
    startedAt: started - 300_000,
    quietSince: started - 5_000,
    action: "Reading SubagentTray.tsx",
  },
  {
    id: "busy-b",
    parent: null,
    name: "Measure the rail",
    state: "running",
    startedAt: started - 200_000,
    action: "Running bun test",
  },
  {
    id: "acp-1/toolu_c",
    parent: null,
    name: "Check the permission receipt",
    state: "running",
    startedAt: started - 120_000,
    quietSince: started - 2_000,
  },
  {
    id: "done-a",
    parent: null,
    name: "Read the design spec",
    state: "completed",
    startedAt: started - 7_000_000,
    endedAt: started - 6_800_000,
  },
];

/// Where the play holds every wave loop: one point on each loop's own timeline, past its delay (the
/// delay is never positive, wave.css), so each icon's phase differs only by its index. At 840 ms
/// the crest (20% of Session Info's 2.4 s period, SubagentsSection.css) is on the third line: the
/// two before it fall from it, the two after it rise toward it, so a still reads dim, brighter,
/// crest, brighter, dim.
const WAVE_HOLD_MS = 840;

/// The page's wave loops (CSS animations of `cmux-wave`).
const waveLoops = (ctx: PlayContext) =>
  ctx.document
    .getAnimations()
    .filter((animation) => (animation as CSSAnimation).animationName === WAVE_KEYFRAMES) as CSSAnimation[];

/// Holds the wave mid-sweep for a still. A loop is held only once installWave has moved it onto the
/// shared epoch (its start is a whole number of periods of Unix time): a loop paused before that is
/// restarted by the realignment, which scrambled the wave. Then all of them pause at one point.
const holdWave: Play = async (ctx) => {
  const items = () => ctx.document.querySelectorAll(`.acpmux-session-info-subagents .${WAVE_CLASS}`);
  await ctx.waitFor(() => items().length === RUNNING);
  // Reduce Motion, the motion gate or static indicators run no wave: there is nothing to hold.
  const view = ctx.document.defaultView!;
  if (view.getComputedStyle(items()[0]!).animationName !== WAVE_KEYFRAMES) return;
  const origin = view.performance.timeOrigin;
  const aligned = (animation: CSSAnimation) => {
    const period = Number(animation.effect?.getTiming().duration);
    if (!(period > 0) || animation.startTime === null) return false;
    const phase = (((Number(animation.startTime) + origin) % period) + period) % period;
    return Math.min(phase, period - phase) < 1;
  };
  await ctx.waitFor(() => {
    const loops = waveLoops(ctx);
    return loops.length === RUNNING && loops.every((loop) => loop.playState === "running" && aligned(loop));
  });
  for (const loop of waveLoops(ctx)) {
    loop.pause();
    loop.currentTime = WAVE_HOLD_MS;
  }
};

/// Chats the agent started: one waits on the person, one runs on a Cloud VM, one is done.
const sessions: StartedSession[] = [
  { sessionId: "child-1", title: "Rename the settings keys", state: "waiting", createdAt: started - 600_000 },
  { sessionId: "child-2", title: "Run the e2e suite on build-01", state: "running", createdAt: started - 500_000 },
  { sessionId: "child-3", title: "Draft the release notes", state: "idle", createdAt: started - 400_000 },
];

/// A background Bash the transcript knows but the registry does not list (an older acpmux), still
/// running and so without Stop; and one that finished.
const transcriptTasks: NonNullable<Props["transcriptTasks"]> = [
  { id: "call-pytest", command: "pytest -x --lf", state: "running", startedAt: started - 45_000 },
  { id: "call-gen", command: "bun scripts/pages/gen-strings.mjs", state: "completed", startedAt: started - 700_000 },
];

/// What acpmux reports a session spent (usageStats.ts), for Usage.
const spent = (fields: Partial<SessionUsageStats>): SessionUsageStats => ({
  launcher: "claude",
  autocompact: "none",
  compactions24h: 0,
  subagentsLive: 0,
  subagents1h: 0,
  subagents24h: 0,
  tokens24h: 0,
  updatedAt: Date.UTC(2026, 9, 30, 3),
  ...fields,
});
const ownUsage = spent({
  launcher: "claude-sr2",
  autocompact: "capped",
  autocompactCap: 200_000,
  contextTokens: 94_000,
  contextWindow: 200_000,
  compactions24h: 2,
  subagentsLive: 1,
  subagents1h: 3,
  subagents24h: 11,
  tokens24h: 38_400_000,
  costUsd24h: 61.2,
  calls24h: 182,
  cacheReadShare24h: 0.981,
  costPerCallUsd24h: 0.3363,
});
const summary = {
  ...local.summary!,
  usage: { used: 94_000, size: 200_000 },
  usageStats: ownUsage,
  // At most 16 of the chats it started run at once (acpmux's default).
  subsessionLimits: { maxRunning: 16, maxRunningSource: "default" as const },
  branch: "feat/next-session-info",
  mcpServers: [
    { name: "github", status: "connected" as const },
    { name: "linear", status: "failed" as const },
    { name: "sentry", status: "pending" as const },
  ],
};

/// Holds Outputs mid-drag over Context: pressed on its handle, moved, never released.
const dragOutputsOverContext: Play = async (ctx) => {
  const grip = '[data-section="outputs"] > .acpmux-session-info-section__handle';
  await ctx.waitFor(() => ctx.document.querySelector(grip));
  await ctx.pointer.down({ selector: grip });
  await ctx.pointer.move({ selector: '[data-section="context"]' });
  await ctx.waitFor(() => ctx.document.querySelector('[data-slot="outputs"][data-lifted]'));
};

const FOLDABLE_HEAD =
  ".acpmux-session-info-section > .acpmux-session-info-section__disclosure > .ui-disclosure-trigger";
const style = (ctx: PlayContext, element: Element) => ctx.document.defaultView!.getComputedStyle(element);

/// cmux#32765, as native #32674: a section's fold chevron sits after its title and shows only while its
/// head is hovered (or keyboard focused). At rest no chevron draws, but its room is kept, so the title
/// does not move when it shows.
const chevronOnHoverAfterTitle: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(`${FOLDABLE_HEAD} > .acpmux-session-info-section__fold`));
  const folds = [...ctx.document.querySelectorAll(`${FOLDABLE_HEAD} > .acpmux-session-info-section__fold`)];
  for (const fold of folds)
    if (style(ctx, fold).visibility !== "hidden") throw new Error("A section's fold chevron draws at rest");
  const head = folds[0]!.parentElement!;
  const section = head.closest<HTMLElement>(".acpmux-session-info-section")!.dataset.section;
  const selector = `[data-section="${section}"] > .acpmux-session-info-section__disclosure > .ui-disclosure-trigger`;
  const title = head.querySelector(".acpmux-session-info-section__title")!;
  const before = title.getBoundingClientRect();
  await ctx.hover({ selector });
  const fold = ctx.find({ selector: `${selector} > .acpmux-session-info-section__fold` });
  await ctx.waitFor(() => style(ctx, fold).visibility === "visible");
  const after = title.getBoundingClientRect();
  if (after.left !== before.left || after.width !== before.width)
    throw new Error("The title moved when the chevron showed");
  if (fold.getBoundingClientRect().left < after.right) throw new Error("The fold chevron is not after the title");
};

/// As native #32674: the six-dot grip draws nothing at rest, nor for a pointer over a section's other
/// rows; it shows while its section's head is hovered, left of the title (Leo, 2026-11-03: "why dont
/// we have the drag grabber to the left of the title"), overlapping neither the title nor the head's
/// icon, and the title does not move when it shows.
const gripOnHeadHoverOnly: Play = async (ctx) => {
  const handles = () => [...ctx.document.querySelectorAll(".acpmux-session-info-section__handle")];
  await ctx.waitFor(() => handles().length > 0);
  for (const handle of handles())
    if (style(ctx, handle).opacity !== "0") throw new Error("A section's drag grip draws at rest");
  const head = ctx.find({ selector: FOLDABLE_HEAD });
  const section = head.closest<HTMLElement>(".acpmux-session-info-section")!;
  const handle = section.querySelector(":scope > .acpmux-session-info-section__handle")!;
  const row = section.querySelector(".ui-disclosure-panel :is(.acpmux-session-info-row, li)");
  if (row && row.getClientRects().length > 0) {
    await ctx.hover({
      selector: `[data-section="${section.dataset.section}"] .ui-disclosure-panel :is(.acpmux-session-info-row, li)`,
    });
    if (style(ctx, handle).opacity !== "0") throw new Error("A body row's hover showed its section's grip");
  }
  const title = head.querySelector(".acpmux-session-info-section__title")!;
  const before = title.getBoundingClientRect();
  await ctx.hover({
    selector: `[data-section="${section.dataset.section}"] > .acpmux-session-info-section__disclosure > .ui-disclosure-trigger`,
  });
  await ctx.waitFor(() => style(ctx, handle).opacity === "1");
  const after = title.getBoundingClientRect();
  if (after.left !== before.left || after.width !== before.width)
    throw new Error("The title moved when the grip showed");
  // Leo, 2026-11-03: "just align the draggable. in fact, make it a more horizontally wide symbol". The
  // dots are wider than tall and on the head's middle line. Leo, 2026-11-04: "this is off", of the dots
  // centred on the pill's left edge: they sit wholly inside the pill, left of its icon or title.
  const dots = handle.querySelector("svg")!.getBoundingClientRect();
  const pill = head.getBoundingClientRect();
  if (dots.right > after.left + 0.5) throw new Error("The grip is not left of the title");
  const icon = head.querySelector(".acpmux-session-info-section__icon");
  if (icon && dots.right > icon.getBoundingClientRect().left + 0.5)
    throw new Error("The grip overlaps the head's icon");
  if (!(dots.width > dots.height)) throw new Error(`The grip is ${dots.width}x${dots.height}, not wider than tall`);
  if (dots.left < pill.left + 0.5) throw new Error("The grip is not wholly inside its head's pill");
  if (Math.abs(dots.top + dots.height / 2 - (pill.top + pill.height / 2)) > 0.5)
    throw new Error("The grip is not on its head's middle line");
};

/// Shows a compared grip placement: the pointer rests on the first foldable section head.
const hoverFirstHead: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(FOLDABLE_HEAD));
  await ctx.hover({ selector: FOLDABLE_HEAD });
};

/// Leo, 2026-11-03: "why dont we have the drag grabber to the left of the title". Every section's grip,
/// icon heads (Context, Usage, Connectors) and the bare Environment rows included, ends at or before its
/// head's first glyph (its icon, else its title) and sits far from the panel's right edge, where the
/// scrollbar's thumb runs.
const gripLeftOfEveryTitle: Play = async (ctx) => {
  const sections = () => [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-session-info-section")];
  await ctx.waitFor(() => sections().some((s) => s.querySelector(":scope > .acpmux-session-info-section__handle")));
  const body = ctx.find({ selector: ".acpmux-session-info__body" }).getBoundingClientRect();
  for (const section of sections()) {
    const handle = section.querySelector(":scope > .acpmux-session-info-section__handle");
    if (!handle || handle.getClientRects().length === 0) continue;
    // The dots: the handle's hit box reaches over the icon box's empty margin.
    const grip = handle.querySelector("svg")!.getBoundingClientRect();
    const first = section.querySelector(
      ":scope > .acpmux-session-info-section__disclosure > .ui-disclosure-trigger, :scope > .acpmux-session-info-section__head",
    );
    // A bare section (the Environment rows) has no head: its first row's leading icon stands in.
    const glyph = first
      ? first.querySelector(":scope > .acpmux-session-info-section__icon, :scope > .acpmux-session-info-section__title")
      : section.querySelector(":scope > :not(.acpmux-session-info-section__handle) svg");
    if (glyph && grip.right > glyph.getBoundingClientRect().left + 0.5)
      throw new Error(`${section.dataset.section}'s grip is not left of its title`);
    if (grip.left < body.left - 0.5) throw new Error(`${section.dataset.section}'s grip spills out of the panel`);
    if (grip.right > body.left + body.width / 2)
      throw new Error(`${section.dataset.section}'s grip is on the right, by the scrollbar's thumb`);
  }
};

/// As native #32661: pushed beside the chat (or in the empty gutter) the panel draws no card behind its
/// sections: no fill, no blur, no shadow.
const noCardBehind: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-session-info"));
  const panel = ctx.find({ selector: ".acpmux-session-info" });
  const look = style(ctx, panel);
  if (panel.classList.contains("ui-glass")) throw new Error("The panel is a glass card where nothing runs under it");
  if (look.backgroundColor !== "rgba(0, 0, 0, 0)" || look.backgroundImage !== "none")
    throw new Error(`The panel paints a card: ${look.backgroundColor} ${look.backgroundImage}`);
  if (!["none", ""].includes(look.backdropFilter) || look.boxShadow !== "none")
    throw new Error(`The panel draws a card's blur or shadow: ${look.backdropFilter} ${look.boxShadow}`);
};

/// Leo, 2026-11-03: "i mean there's literally no scrollbar in claude code it's just scrollable". A busy
/// body overflows, draws no scrollbar and keeps no width for one (its client width is its whole width
/// inside its borders), and it still scrolls.
const scrollsWithNoScrollbar: Play = async (ctx) => {
  const selector = ".acpmux-session-info__body";
  await ctx.waitFor(() => {
    const body = ctx.document.querySelector<HTMLElement>(selector);
    return body !== null && body.scrollHeight > body.clientHeight + 1;
  });
  const body = ctx.find({ selector }) as HTMLElement;
  const look = style(ctx, body);
  if ("scrollbarWidth" in look && look.scrollbarWidth !== "none")
    throw new Error(`The body's scrollbar-width is ${look.scrollbarWidth}, not none`);
  const borders = Number.parseFloat(look.borderLeftWidth) + Number.parseFloat(look.borderRightWidth);
  if (Math.abs(body.offsetWidth - borders - body.clientWidth) > 0.5)
    throw new Error(`The body keeps ${body.offsetWidth - borders - body.clientWidth}px for a scrollbar`);
  await ctx.scroll({ selector }, 120);
  await ctx.waitFor(() => body.scrollTop > 0);
};

// The panel's edge: a hairline (at most 1px) in the pane's border color all round, on its rounded corners,
// and no fill of its own where nothing runs under it (Leo, 2026-11-03: "having a border for it might be better").
const hairlineEdge: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-session-info"));
  const panel = ctx.find({ selector: ".acpmux-session-info" });
  const look = style(ctx, panel);
  for (const side of ["Top", "Right", "Bottom", "Left"] as const) {
    const width = Number.parseFloat(look.getPropertyValue(`border-${side.toLowerCase()}-width`));
    if (!(width > 0 && width <= 1)) throw new Error(`The panel's ${side} edge is ${width}px, not a hairline`);
    if (look.getPropertyValue(`border-${side.toLowerCase()}-style`) !== "solid")
      throw new Error(`The panel's ${side} edge does not draw`);
  }
  const probe = ctx.document.createElement("div");
  probe.style.color = "var(--agent-border)";
  panel.parentElement!.append(probe);
  const border = style(ctx, probe).color;
  probe.remove();
  if (look.borderTopColor !== border)
    throw new Error(`The edge is ${look.borderTopColor}, not the pane's border ${border}`);
  if (Number.parseFloat(look.borderTopLeftRadius) <= 0) throw new Error("The edge has square corners");
  if (!panel.hasAttribute("data-over-chat")) await noCardBehind(ctx);
};

// Every section title shares the Environment rows' text column, with or without an icon.
const checkTopBlockAlignment: Play = async (ctx) => {
  const rect = (selector: string) => ctx.find({ selector }).getBoundingClientRect();
  const environment = '[data-section="environment"] .acpmux-session-info-row__name';
  await ctx.waitFor(() => ctx.document.querySelector(environment));
  const labelLeft = rect(environment).left;
  for (const section of ["context", "usage", "connectors"]) {
    const title = rect(`[data-section="${section}"] .acpmux-session-info-section__title`);
    if (Math.abs(title.left - labelLeft) > 0.5)
      throw new Error(`${section} label starts ${title.left - labelLeft}px from the Environment text column`);
  }
  const heading = rect('[data-section="changes"] .acpmux-session-info-section__title');
  if (Math.abs(heading.left - labelLeft) > 0.5)
    throw new Error("The Changes heading moved from the shared text column");
};

/// The default order, top to bottom (sectionOrder.ts DEFAULT_ORDER; Leo, 2026-11-03: "1. Machines showing
/// up so I know if it's cloud or not 2. context 3. Subagents/background tasks running 4. Sources").
const DEFAULT_SECTION_ORDER = [
  "environment",
  "context",
  "usage",
  "subagents",
  "tasks",
  "sources",
  "changes",
  "outputs",
  "connectors",
];
const assertDefaultOrder: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector("[data-slot]"));
  const drawn = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-session-info-sections > [data-slot]")].map(
    (slot) => slot.dataset.slot!,
  );
  const expected = DEFAULT_SECTION_ORDER.filter((id) => drawn.includes(id));
  if (drawn.join(" ") !== expected.join(" "))
    throw new Error(`Session Info's default order is ${drawn.join(", ")}, not ${expected.join(", ")}`);
  for (const id of ["environment", "context", "subagents", "sources"])
    if (!drawn.includes(id)) throw new Error(`The full chat does not draw ${id}`);
};

/// The sections the panel draws, top to bottom.
const drawnSlots = (ctx: PlayContext) =>
  [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-session-info-sections > [data-slot]")].map(
    (slot) => slot.dataset.slot!,
  );
const LEO_FOUR = ["environment", "context", "subagents", "tasks", "sources"];
const LESS_USED = ["usage", "changes", "outputs", "connectors"];
const expectDrawn = (ctx: PlayContext, expected: readonly string[]) => {
  const drawn = drawnSlots(ctx);
  if (drawn.join(" ") !== expected.join(" "))
    throw new Error(`Session Info draws ${drawn.join(", ")}, not ${expected.join(", ")}`);
};
/// The shipped default view: Leo's four in view, the less-used sections behind one Show more that
/// names them; Show more draws every one in the default order, and Show less puts them back.
const compactByDefault: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector("[data-slot]"));
  expectDrawn(ctx, LEO_FOUR);
  const more = ctx.find({ selector: ".acpmux-session-info-more" });
  if (more.getAttribute("aria-expanded") !== "false") throw new Error("Show more starts open");
  const names = more.querySelector(".acpmux-session-info-more__names")?.textContent ?? "";
  for (const title of ["Usage", "Changes", "Outputs", "Connectors"])
    if (!names.includes(title)) throw new Error(`Show more does not name ${title}: "${names}"`);
  await ctx.click({ selector: ".acpmux-session-info-more" });
  await ctx.waitFor(() => drawnSlots(ctx).length === LEO_FOUR.length + LESS_USED.length);
  expectDrawn(ctx, DEFAULT_SECTION_ORDER);
  if (!/Show less/.test(ctx.find({ selector: ".acpmux-session-info-more" }).textContent ?? ""))
    throw new Error("Show more open does not offer Show less");
  await ctx.click({ selector: ".acpmux-session-info-more" });
  await ctx.waitFor(() => drawnSlots(ctx).length === LEO_FOUR.length);
};

/// Every session acpmux lists, this Mac's and a peer's: the usage audit's deputies on a build box (no
/// autocompact cap, 290-330k per call, 67-90 subagents a day) above this chat.
const fleet: AcpmuxSessionEntry[] = [
  sessionEntry({
    sessionId: local.summary!.sessionId,
    name: "session-info-polish",
    harness: "claude",
    usageStats: ownUsage,
  }),
  ...(
    [
      ["dep-fleet", 1_420.5, 312_000, 90],
      ["dep-land", 1_288, 331_000, 84],
      ["dep-asks", 1_204.75, 296_000, 71],
      ["self-audit", 1_190, 290_000, 67],
    ] as const
  ).map(([name, costUsd24h, contextTokens, subagents24h]) =>
    sessionEntry({
      sessionId: `build-box-${name}`,
      name: `build-box/${name}`,
      peer: "build-box",
      harness: "claude",
      usageStats: spent({ costUsd24h, contextTokens, contextWindow: 1_000_000, subagents24h, tokens24h: 900_000_000 }),
    }),
  ),
  sessionEntry({
    sessionId: "gcp-review",
    name: "lane-vm/review-27744",
    peer: "lane-vm",
    harness: "codex",
    // acpmux has not read a whole day yet: the 24h counts are unknown, never 0.
    usageStats: {
      launcher: "codex-acp",
      autocompact: "unknown",
      contextTokens: 41_000,
      updatedAt: Date.UTC(2026, 9, 30, 3),
    },
  }),
  sessionEntry({
    sessionId: "docs-pass",
    name: "docs-pass",
    harness: "claude",
    usageStats: spent({ autocompact: "capped", costUsd24h: 4.1, contextTokens: 22_000, tokens24h: 1_300_000 }),
  }),
];

/// A session whose tokens and context acpmux read but whose cost it could not (a harness with no
/// price table): sorted by 24h cost it reads as an em dash, never its token count.
const unpricedFleet: AcpmuxSessionEntry[] = [
  ...fleet.slice(0, 3),
  sessionEntry({
    sessionId: "unpriced-codex",
    name: "lane-vm/unpriced-codex",
    peer: "lane-vm",
    harness: "codex",
    usageStats: spent({ launcher: "codex-acp", autocompact: "unknown", contextTokens: 41_000, tokens24h: 52_000_000 }),
  }),
];

const full: Props = {
  summary,
  allSessions: fleet,
  onOpenChat: () => undefined,
  machineName: "Studio",
  repository: "manaflow-ai/cmux",
  made: {
    ...made,
    pullRequests,
    sources: [
      { url: "https://github.com/acme/billing/pull/7", label: "billing: retry webhooks on a 502", kind: "pullRequest" },
      { label: "cmux.com/docs/session-info", url: "https://cmux.com/docs/session-info", kind: "url" },
      { label: "src/net/fetch.ts", kind: "file" },
      { label: "github · search issues", kind: "mcp" },
      { label: "linear · get issue", kind: "mcp" },
      { label: "teamleaderleo/leo-workspace #1056", kind: "issue" },
    ],
  },
  links: [
    { url: "https://cmux.com/docs/session-info", label: "cmux.com/docs/session-info" },
    { url: "https://claude.ai/artifact/session-info-plan", label: "claude.ai/artifact/session-info-plan" },
  ],
  artifacts: 4,
  agents,
  statuses,
  processes,
  transcriptTasks,
  sessions,
  onOpenSession: () => undefined,
  onStopProcess: async () => undefined,
  onOpenUrl: () => undefined,
  onOpenOutput: () => undefined,
  onOpenSourceFile: () => undefined,
  onOpenSubagent: () => undefined,
  onSaveEnvironment: () => undefined,
  onSetRunningLimit: async () => undefined,
  onReconnectMcp: async () => undefined,
  onCompact: () => undefined,
  remoteControl: { on: false, set: () => undefined },
  // Every section in view: the variants below compare the sections themselves. The default view
  // (Show more closed) is `compact-more`.
  more: true,
};

/// Wakeups and cron jobs as a coordinator schedules them (Leo, 2026-11-03: "expired waits like 'Wake
/// at ~03:37Z' stay listed forever ... one shows a raw cron string '17 * * * *'"): two waits still
/// ahead, three whose time has passed, an hourly pass, a five-minute poll a CronDelete removed, a
/// recurring job past its 7 days and a failed call. Times are relative to the gallery's load.
const MINUTE = 60_000;
const scheduledMix: SummaryWakeup[] = [
  {
    id: "w-ahead",
    kind: "wakeup",
    text: "Wake when the nightly finishes",
    startedAt: started - 2 * MINUTE,
    dueAt: started + 25 * MINUTE,
  },
  {
    id: "w-merge",
    kind: "wakeup",
    text: "Waiting on the merge retries, then re-check",
    startedAt: started - MINUTE,
    dueAt: started + 40 * MINUTE,
  },
  {
    id: "w-done-1",
    kind: "wakeup",
    text: "Wake at ~03:37Z when cmux#32865's checks land",
    startedAt: started - 64 * MINUTE,
    dueAt: started - 60 * MINUTE,
  },
  {
    id: "w-done-2",
    kind: "wakeup",
    text: "Production promote: check the run",
    startedAt: started - 30 * MINUTE,
    dueAt: started - 18 * MINUTE,
  },
  {
    id: "w-done-3",
    kind: "wakeup",
    text: "Waiting on the three stuck merges",
    startedAt: started - 9 * MINUTE,
    dueAt: started - 4 * MINUTE,
  },
  {
    id: "c-hourly",
    kind: "cron",
    cron: "17 * * * *",
    text: "Hourly coordinator pass",
    startedAt: started - 90 * MINUTE,
  },
  {
    id: "c-poll",
    kind: "cron",
    cron: "*/5 * * * *",
    text: "Poll the webview verdicts",
    startedAt: started - 50 * MINUTE,
    cancelledAt: started - 12 * MINUTE,
  },
  {
    id: "c-old",
    kind: "cron",
    cron: "0 9 * * 1-5",
    text: "Morning stand-up summary",
    startedAt: started - 8 * 24 * 60 * MINUTE,
  },
  {
    id: "w-failed",
    kind: "wakeup",
    text: "Fallback heartbeat while pinned merges run",
    startedAt: started - 3 * MINUTE,
    failed: true,
  },
];
const scheduledProps: Props = {
  ...full,
  processes: processes.filter((process) => process.state === "running" && !/vite|dev/.test(process.command)),
  transcriptTasks: [],
  made: { ...full.made!, scheduled: scheduledMix },
};

/// A busy coordinator, as in Leo's 2026-10-21 screenshot: twelve subagents and five chats it started
/// run (one waits on the person), ninety-four ended and one failed.
const busyAgents: Subagent[] = Array.from({ length: 107 }, (_, index) => ({
  id: `busy-${index}`,
  parent: null,
  name: `${NAMES[index % NAMES.length]} ${Math.floor(index / NAMES.length) + 1}`,
  task: "Land one piece of the session panel",
  state: index < 12 ? "running" : index === 12 ? "failed" : "completed",
  startedAt: started - (index + 1) * 60_000,
  ...(index < 12 ? { action: index % 2 ? "Running bun test" : "Reading SubagentsSection.tsx" } : {}),
  ...(index >= 12 ? { endedAt: started - index * 50_000 } : {}),
  // Every fourth runs on Codex (a `codex exec` the chat started), so its line draws Codex's mark.
  ...(index % 4 === 3 ? { harness: "codex" } : {}),
}));
const LANES = ["summary-panel", "priority-view", "lane-host", "machine-hygiene", "paired-approvals"];
const busySessions: StartedSession[] = LANES.map((title, index) => ({
  sessionId: `lane-${index}`,
  title,
  state: index === 1 ? "waiting" : "running",
  createdAt: started - (index + 1) * 300_000,
  // The chats it started run on Claude or Codex, and one on a harness with no mark of its own: its
  // icon keeps its own color (Leo, 2026-10-29: "one of these is Codex, one of these is Claude").
  ...(index === 4 ? {} : { harness: index % 2 ? "codex" : "claude" }),
}));
/// The chat runs on Claude: its own subagents draw Claude's mark.
const busy: Props = { ...full, summary: { ...summary, harness: "claude" }, agents: busyAgents, sessions: busySessions };

/// A chat running a Claude workflow (Labs `workflowLabs`): its events fed through the real subagent
/// fold (summary/workflowFixture.ts), so Background tasks shows what the fold keeps
/// (session-info/WorkflowTasks.tsx). The workflow's node leaves Subagents for Background tasks.
const workflowProps = (
  stage: WorkflowFixtureStage,
  workflowAgentRowVariant?: Props["workflowAgentRowVariant"],
  panelWidth = 320,
  modelOverride?: string,
): Props => {
  const nodes = workflowFixture(stage);
  const workflowList = createWorkflowAdapter()(nodes, "gallery-chat").map((workflow) =>
    modelOverride
      ? {
          ...workflow,
          agents: workflow.agents.map((agent) =>
            agent.index === 4 ? { ...agent, model: modelOverride, startedAt: Date.now() - 204_000 } : agent,
          ),
        }
      : workflow,
  );
  return {
    summary,
    machineName: "Studio",
    repository: "manaflow-ai/cmux",
    agents: nodes,
    workflows: workflowList,
    onStopWorkflow: async () => undefined,
    onOpenSubagent: () => undefined,
    onOpenWorkflowAgent: () => undefined,
    workflowAgentRowVariant,
    panelWidth,
    onSaveEnvironment: () => undefined,
    remoteControl: { on: true, set: () => undefined },
  };
};

/// A provider failure after an earlier progress message, read through the real summary fold.
const workflowFailureProps = (): Props => {
  const nodes = workflowFixture("finished").map((node) => ({
    ...node,
    state: "failed",
    workflowAgents: new Map(
      [...(node.workflowAgents ?? [])].map(([index, agent]) => [
        index,
        index === 4
          ? {
              ...agent,
              state: "failed",
              error: "503: No provider capacity available",
              lastMessage: "Earlier reply before the request failed",
            }
          : agent,
      ]),
    ),
  }));
  return { ...workflowProps("finished", "detail", 260), workflows: createWorkflowAdapter()(nodes, "gallery-chat") };
};

const assertNarrowWorkflowLayout: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-workflow-agent__button") !== null);
  const panel = ctx.find({ selector: ".acpmux-session-info" }).getBoundingClientRect();
  if (Math.abs(panel.width - 260) > 1) throw new Error(`expected a 260px panel, got ${panel.width}px`);
  const name = ctx.find({ selector: ".acpmux-workflow-agent__name" }).getBoundingClientRect();
  const model = ctx.find({ selector: ".acpmux-workflow-agent__model" }).getBoundingClientRect();
  const state = ctx.find({ selector: ".acpmux-workflow-agent__state" }).getBoundingClientRect();
  const time = ctx.find({ selector: ".acpmux-workflow-agent .acpmux-session-info-task__time" }).getBoundingClientRect();
  if (name.width < 24) throw new Error(`workflow agent name collapsed at ${name.width}px`);
  if (model.right > state.left + 0.5) throw new Error("workflow model overlaps the state column");
  if (state.right > time.left + 0.5) throw new Error("workflow state overlaps the elapsed-time column");
};
/// Opens the workflow's `n`th phase (from 1).
const openPhase =
  (n: number): Play =>
  async (ctx) => {
    await ctx.click({ selector: `.acpmux-workflow-phase:nth-child(${n}) .acpmux-workflow-phase__head` });
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-workflow-phase__agents") !== null);
  };

/// A chat in a lane checkout of cmux that worked across several folders: Environment lists only its
/// project (chatFolders.ts).
const PROJECTS = "/Users/you/Projects";
const SCRATCHPAD = "/private/tmp/agent-501/-Users-you-Projects/7f3e/scratchpad";
const touched = (path: string) =>
  tool(`Read ${path}`, "read", "completed", { locations: [{ path: `${PROJECTS}/${path}` }] });
const projectRows = [
  activity(
    [
      touched("cmux/webviews/src/agent-session/acpmux/App.tsx"),
      touched("cmux-app-screenshots/index.json"),
      touched("agent-pane-reference/README.md"),
      touched("cmuxterm-hq/build-fleet/FLEET-AND-CI.md"),
      touched("leo-workspace/NOW.md"),
      touched("ci-daemon/main.go"),
    ],
    6,
  ),
];

const environmentProps = (): Props => ({
  ...full,
  summary: { ...summary, cwd: `${PROJECTS}/checkouts/cmux/next-env-folders`, branch: "you/next-env-folders" },
  rows: projectRows,
  onOpenFolder: () => undefined,
  remoteControl: undefined,
});

/// What a chat produced, as Claude Code desktop's Outputs lists it: a ledger page it rendered and a
/// Markdown plan its reply drew, each opening in the side panel.
const producedRows = [
  activity(
    [
      tool("mcp__cmux__render", "other", "completed", {
        inputSummary: JSON.stringify({
          title: "Leo's Asks Ledger",
          html: "<!doctype html><title>Leo's Asks Ledger</title><h1>Asks</h1>",
        }),
        output: '{"rendered":true}',
      }),
    ],
    3,
  ),
  assistant("Here is the plan:\n\n```markdown\n# Session Info rollout\n\n- Context\n- Outputs\n```\n", 2),
];

/// A subagent in a Claude worktree of its own: it read and edited files there, ran the tests in the
/// background (still running), and its result named the worktree and branch.
const TREE = `${CWD}/.claude/worktrees/agent-a3f9c2`;
const inTree = (path: string, oldText: string | undefined, newText: string) =>
  tool(`Edit ${path}`, "edit", "completed", { diffs: [{ path: `${TREE}/${path}`, oldText, newText }] });
const subagentRows = [
  activity(
    [
      tool("Read src/net/fetch.ts", "read", "completed", { locations: [{ path: `${TREE}/src/net/fetch.ts` }] }),
      inTree("src/net/fetch.ts", "export const timeout = 5_000;\n", "export const timeout = 15_000;\n"),
      inTree("src/net/timeout.test.ts", undefined, "test('waits 15s', () => {});\n"),
      tool("Run bun test --watch src/net", "execute", "in_progress", {
        command: "bun test --watch src/net",
        inputSummary: JSON.stringify({ command: "bun test --watch src/net", run_in_background: true }),
      }),
    ],
    3,
  ),
  assistant("Raised the timeout to 15 s and added a test; the watcher runs in the worktree.", 1),
];
const worktreeAgent: Subagent = {
  id: "agent-timeouts",
  parent: null,
  name: "Fix the timeouts",
  task: "Raise the fetch timeout in a worktree",
  kind: "general-purpose",
  state: "running",
  startedAt: started - 240_000,
  action: "Running bun test",
  tokens: 48_200,
  toolUses: 14,
  isolated: true,
  worktree: { path: TREE, branch: "worktree-agent-a3f9c2" },
};
const scopeOf = (agent: Subagent) => ({ agent, parent: "Add retries to the fetch helper", onBack: () => undefined });
/// The subagent's panel: its own rows, environment and progress; nothing of the chat's.
const subagentPanel: Props = {
  summary: subagentSummary(summary, worktreeAgent, subagentRows),
  machineName: "Studio",
  repository: "manaflow-ai/cmux",
  made: sessionSummary(subagentRows, "manaflow-ai/cmux"),
  transcriptTasks: sessionSummary(subagentRows).backgroundTasks,
  rows: subagentRows,
  agent: worktreeAgent,
  onOpenUrl: () => undefined,
  onOpenOutput: () => undefined,
  onOpenSourceFile: () => undefined,
  onStopProcess: async () => undefined,
  scope: scopeOf(worktreeAgent),
};
/// An Explore subagent in the chat's own checkout: its folder and branch are the chat's.
const sharedAgent: Subagent = {
  id: "agent-explore",
  parent: null,
  name: "Explore the retry callers",
  task: "Find every caller of fetchWithRetry",
  kind: "Explore",
  state: "completed",
  startedAt: started - 600_000,
  endedAt: started - 420_000,
  tokens: 21_400,
  toolUses: 9,
};
const sharedRows = [
  activity(
    [
      tool("Read src/net/fetch.ts", "read", "completed", { locations: [{ path: `${CWD}/src/net/fetch.ts` }] }),
      tool("Read src/api/client.ts", "read", "completed", { locations: [{ path: `${CWD}/src/api/client.ts` }] }),
    ],
    9,
  ),
  assistant("fetchWithRetry has three callers: client.ts, upload.ts and the webhook relay.", 7),
];
/// A Claude Code chat with its /context breakdown, Context open and the long sections folded so the
/// card shows whole. It compacts at 400k (its acpmux cap and /context agree), so Context reads the
/// window /context names: the smaller of the two (usageStats.ts `compactingUsage`, #32665), never
/// the 200k cap of this file's other chat.
const breakdownUsage: SessionUsageStats = { ...ownUsage, autocompactCap: 400_000 };
const breakdownProps: Props = {
  ...full,
  summary: {
    ...summary,
    usage: { used: 171_400, size: 400_000 },
    usageStats: breakdownUsage,
    contextBreakdown: CONTEXT_BREAKDOWN,
  },
  sections: { ...DEFAULT_SECTIONS, environment: false, context: true, changes: false, subagents: false, tasks: false },
};
/// A gallery-only palette for the breakdown's used categories, largest first.
const palette = (colors: string[]) =>
  Object.fromEntries(colors.map((color, index) => [`--acpmux-context-tone-${index}`, color])) as CSSProperties;
const openMcpTools: Play = async (ctx) => {
  await ctx.click({ selector: '[data-list="mcpTools"] button' });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-context-breakdown__items") !== null);
};

const text = (ctx: Parameters<Play>[0]) => ctx.document.querySelector(".acpmux-session-info")?.textContent ?? "";

export default componentEntry<Props>({
  id: "agent-pane.chat-inspector",
  title: "Session Info",
  area: "Agent pane",
  pane: true,
  height: 900,
  widths: { narrow: 320, normal: 420 },
  covers: [
    "agent-session/acpmux/session-info/SessionInfo.tsx",
    "agent-session/acpmux/session-info/chatFolders.ts",
    "agent-session/acpmux/session-info/ChildSessionRows.tsx",
    "agent-session/acpmux/session-info/ChangesSection.tsx",
    "agent-session/acpmux/session-info/SourcesSection.tsx",
    "agent-session/acpmux/session-info/ConnectorsSection.tsx",
    "agent-session/acpmux/session-info/ContextSection.tsx",
    "agent-session/acpmux/session-info/PullRequestGlyph.tsx",
    "agent-session/acpmux/session-info/EnvironmentSection.tsx",
    "agent-session/acpmux/session-info/SessionInfoSection.tsx",
    "agent-session/acpmux/session-info/SessionInfoGroup.tsx",
    "agent-session/acpmux/session-info/sectionOrder.ts",
    "agent-session/acpmux/session-info/OutputsSection.tsx",
    "agent-session/acpmux/session-info/ServersSection.tsx",
    "agent-session/acpmux/session-info/SubagentLimitStepper.tsx",
    "agent-session/acpmux/session-info/SubagentsSection.tsx",
    "agent-session/acpmux/session-info/SubagentScopeHeader.tsx",
    "agent-session/acpmux/session-info/subagentScope.ts",
    "agent-session/acpmux/session-info/TasksSection.tsx",
    "agent-session/acpmux/session-info/UsageSection.tsx",
    "agent-session/acpmux/session-info/WorkflowTasks.tsx",
    "agent-session/acpmux/summary/foldWorkflows.ts",
    "agent-session/acpmux/subagents/AgentLine.tsx",
  ],
  load: async () => GallerySessionInfo,
  variants: {
    full: {
      note: "A chat on this Mac with every section, shipped layout (glance), in the default order: the machine (this Mac or Cloud), Context, what it runs, then Sources. No section is a box. Where it runs: the machine with Save, folder, repository, branch and Remote Control, then Context (47%) and Usage as one row each. A hairline, then what it runs: three running subagents and two running chats with the 40 done · 1 failed row, and Background tasks, the dev server on :5173 first, then the commands (one only the transcript knows, without Stop) and four finished. A hairline, then Sources with read-only PRs, URLs, files and MCP tools, six session-owned pull requests in Changes, and its outputs. A last hairline, then Connectors (1 to reconnect).",
      props: full,
      play: async (ctx) => {
        await assertDefaultOrder(ctx);
        await checkTopBlockAlignment(ctx);
      },
    },
    "compact-more": {
      note: "Chosen default view (Leo, 2026-11-03: \"i feel like it's a bit too much stuff by default there's a bunch of things there that can be a bit more hidden under 'show more' or whatnot\"): his four in view (the machine, Context, subagents and background tasks, Sources), then one whole-row Show more that names what it holds (Usage, Changes, Outputs, Connectors). Opened, every section shows in the default order and the choice stays for the pane; a reveal of a held section opens it. A section the person dragged above one of the four stays in view. The play opens and closes it.",
      props: { ...full, more: false },
      play: compactByDefault,
    },
    "compact-more-open": {
      note: "The chosen view with Show more opened: every section, then Show less.",
      props: { ...full, more: false },
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-session-info-more" });
        await ctx.waitFor(() => drawnSlots(ctx).length === LEO_FOUR.length + LESS_USED.length);
      },
    },
    "compact-folded": {
      note: "Alternative (not shipped): every section in view, the less-used ones folded to their one-line head. Shorter than today, but still nine rows of headings before anything is read, and a fold already saved open in a chat keeps it long, so it does little for the chats Leo has open.",
      props: {
        ...full,
        more: undefined,
        compactLook: "all",
        sections: { ...DEFAULT_SECTIONS, usage: false, changes: false, outputs: false, connectors: false },
      },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector("[data-slot]"));
        expectDrawn(ctx, DEFAULT_SECTION_ORDER);
        for (const id of LESS_USED) {
          const trigger = ctx.document.querySelector(`[data-slot="${id}"] .ui-disclosure-trigger`);
          if (trigger?.getAttribute("aria-expanded") !== "false") throw new Error(`${id} is not folded`);
        }
      },
    },
    "compact-capped": {
      note: "Alternative (not shipped): every section open, each body cut at three rows with a Show more of its own. Short lists get a Show more they do not need, the cut lands mid-list, and every section still takes its place, so the panel is busier, not calmer.",
      props: { ...full, more: undefined, compactLook: "capped" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector("[data-slot]"));
        expectDrawn(ctx, DEFAULT_SECTION_ORDER);
        if (ctx.document.querySelectorAll("[data-capped]").length < LEO_FOUR.length)
          throw new Error("the sections are not capped");
      },
    },
    "workflow-running": {
      note: "Chosen: the live workflow row keeps the agent name above its truncating model label, puts its current action beneath, and keeps state and elapsed time aligned on the right. Running work uses a spinner; finished and failed work use status marks; queued work uses an outline.",
      props: workflowProps("running"),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-workflow-task") !== null);
      },
    },
    "workflow-finished": {
      note: "Labs: the same workflow finished. 1 finished; Finished · 7 agents · 432k tokens; each phase N/N with its dots, no Stop. Critique opened: its agents with a check and how long each took.",
      props: workflowProps("finished"),
      play: openPhase(2),
    },
    "workflow-agent-failed": {
      note: "A failed workflow agent shows the provider's failure reason in the existing message line instead of stale progress. At 260px the reason truncates and its full text remains in the tooltip and accessible name.",
      props: workflowFailureProps(),
      play: async (ctx) => {
        await openPhase(2)(ctx);
        const message = ctx.find({
          selector: '.acpmux-workflow-agent[data-state="failed"] .acpmux-workflow-agent__doing',
        });
        if (message.textContent !== "503: No provider capacity available")
          throw new Error("missing workflow failure reason");
        await assertNarrowWorkflowLayout(ctx);
      },
    },
    "workflow-agent-row-compact": {
      note: "Alternative (gallery only): a compact one-line workflow agent row keeps the action inline with the name for the highest density.",
      props: workflowProps("running", "compact"),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-workflow-task") !== null);
      },
    },
    "workflow-agent-row-detail": {
      note: "Chosen workflow agent row: name, model and action each have their own line so the name remains readable at narrow widths; state and elapsed time stay aligned on the right.",
      props: workflowProps("running", "detail"),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-workflow-task") !== null);
      },
    },
    "workflow-agent-row-grid": {
      note: "Alternative (gallery only): a grid workflow agent row gives state, name, model and elapsed time fixed columns, with the action spanning below.",
      props: workflowProps("running", "grid"),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-workflow-task") !== null);
      },
    },
    "workflow-agent-row-narrow": {
      note: "Narrow-width check: at 260px the longest supported model label truncates while the running agent name stays visible and state plus elapsed time keep separate columns.",
      props: workflowProps("running", "detail", 260, "anthropic/claude-sonnet-5-5"),
      play: assertNarrowWorkflowLayout,
    },
    usage: {
      note: "Chosen: Usage's own metric rows reserve the shared leading slot, so their labels start on the same text column as Context and peer-session rows without repeating a generic icon. The section keeps this chat's last 24 hours (cost, tokens, the context each call carries with Compact beside it, its autocompact cap, compactions, subagents with Show, the launcher), then every session acpmux lists on this Mac and its peers, highest 24h cost first; five show, then View all. Folded, it is one row after Context: this chat's 24h cost.",
      props: {
        ...full,
        sections: {
          ...DEFAULT_SECTIONS,
          environment: false,
          usage: true,
          changes: false,
          subagents: false,
          tasks: false,
        },
      },
    },
    "usage-layout-flush": {
      note: "Alternative: the own metric labels start at the row inset, as the old Usage treatment did; peer-session rows still use the shared icon/text columns, making the mismatch visible.",
      props: {
        ...full,
        usageOwnRowLayout: "flush",
        sections: {
          ...DEFAULT_SECTIONS,
          environment: false,
          usage: true,
          changes: false,
          subagents: false,
          tasks: false,
        },
      },
    },
    "usage-layout-slot": {
      note: "Chosen arm: an empty leading slot puts own metric labels on the shared Session Info text column while keeping the rows quiet and preserving every metric.",
      props: {
        ...full,
        usageOwnRowLayout: "slot",
        sections: {
          ...DEFAULT_SECTIONS,
          environment: false,
          usage: true,
          changes: false,
          subagents: false,
          tasks: false,
        },
      },
    },
    "usage-layout-icon": {
      note: "Alternative: each own metric gets the Usage activity mark in the shared leading slot; it aligns cleanly but repeats one generic glyph on every row, so the quieter empty slot ships.",
      props: {
        ...full,
        usageOwnRowLayout: "icon",
        sections: {
          ...DEFAULT_SECTIONS,
          environment: false,
          usage: true,
          changes: false,
          subagents: false,
          tasks: false,
        },
      },
    },
    "usage-cache-1h": {
      note: 'Chosen: the prompt cache\'s numbers as two rows right after the 24h cost they explain. A chat on the hour-long cache: Cache reads 98.1%, Cost per call $0.34. Leo, 2026-11-03, on the 1h cache: "such a big win that cmux-next/acpmux can get"; the coordinator relayed: show the cache-read share and estimated cost per call, so users can see the win.',
      props: {
        ...full,
        summary: { ...summary, usageStats: ownUsage },
        sections: {
          ...DEFAULT_SECTIONS,
          environment: false,
          usage: true,
          changes: false,
          subagents: false,
          tasks: false,
        },
      },
    },
    "usage-cache-5m": {
      note: "The same chat's numbers on the 5-minute cache, gaps between calls letting it go cold: Cache reads 94.3%, Cost per call $0.43. Set beside usage-cache-1h, the win reads at a glance.",
      props: {
        ...full,
        summary: {
          ...summary,
          usageStats: { ...ownUsage, cacheReadShare24h: 0.943, costPerCallUsd24h: 0.4313, costUsd24h: 78.5 },
        },
        sections: {
          ...DEFAULT_SECTIONS,
          environment: false,
          usage: true,
          changes: false,
          subagents: false,
          tasks: false,
        },
      },
    },
    "usage-cache-combined": {
      note: "Alternative: one Prompt cache row reading 98.1% read · $0.34/call. Shorter, but the cost per call hides inside a sentence and no longer lines up with the other dollar values in the value column, so the two rows ship.",
      props: {
        ...full,
        usageCacheLayout: "combined" as const,
        summary: { ...summary, usageStats: ownUsage },
        sections: {
          ...DEFAULT_SECTIONS,
          environment: false,
          usage: true,
          changes: false,
          subagents: false,
          tasks: false,
        },
      },
    },
    "usage-cache-small": {
      note: "A cheap chat whose calls cost under a cent: the cost keeps two significant digits ($0.0042), never a rounded $0.00.",
      props: {
        ...full,
        summary: {
          ...summary,
          usageStats: {
            ...ownUsage,
            cacheReadShare24h: 0.72,
            costPerCallUsd24h: 0.0042,
            costUsd24h: 0.21,
            calls24h: 50,
          },
        },
        sections: {
          ...DEFAULT_SECTIONS,
          environment: false,
          usage: true,
          changes: false,
          subagents: false,
          tasks: false,
        },
      },
    },
    "usage-cache-unknown": {
      note: "Before acpmux has read the whole day (or a chat with no calls yet): both rows read the em dash, never 0% or $0.00.",
      props: {
        ...full,
        summary: {
          ...summary,
          usageStats: { ...ownUsage, calls24h: undefined, cacheReadShare24h: undefined, costPerCallUsd24h: undefined },
        },
        sections: {
          ...DEFAULT_SECTIONS,
          environment: false,
          usage: true,
          changes: false,
          subagents: false,
          tasks: false,
        },
      },
    },
    "usage-no-cap": {
      note: "Usage for a chat acpmux says runs with no autocompact cap: Autocompact reads No cap, with Restart with cap beside it, disabled until acpmux can restart a session with a cap. A cap acpmux could not read reads as an em dash and offers nothing.",
      props: {
        ...full,
        summary: { ...summary, usageStats: { ...ownUsage, autocompact: "none" as const, autocompactCap: undefined } },
        sections: {
          ...DEFAULT_SECTIONS,
          environment: false,
          usage: true,
          changes: false,
          subagents: false,
          tasks: false,
        },
      },
    },
    "usage-context": {
      note: "Usage sorted by Context: the sessions carrying the most context per call first, the uncapped deputies on build-box at 290-330k on top.",
      props: {
        ...full,
        sections: {
          ...DEFAULT_SECTIONS,
          environment: false,
          usage: true,
          changes: false,
          subagents: false,
          tasks: false,
        },
      },
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-session-info-usage__sort-option:nth-child(2)" });
        await ctx.waitFor(() => ctx.document.querySelector('[data-sort="context"]') !== null);
      },
    },
    "usage-unknown-cost": {
      note: "Usage sorted by 24h cost with a session whose cost acpmux could not read (its tokens and context it did): the row ends in an em dash, never its 24h token count under the cost heading. Sorted by Context it shows its context.",
      props: {
        ...full,
        allSessions: unpricedFleet,
        sections: {
          ...DEFAULT_SECTIONS,
          environment: false,
          usage: true,
          changes: false,
          subagents: false,
          tasks: false,
        },
      },
    },
    "usage-all": {
      note: "Usage with View all open: every session with usage, the lane VM's Codex review, whose 24h numbers acpmux has not read yet, shows an em dash, never $0.00.",
      props: {
        ...full,
        sections: {
          ...DEFAULT_SECTIONS,
          environment: false,
          usage: true,
          changes: false,
          subagents: false,
          tasks: false,
        },
      },
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-session-info-usage-fold" });
        await ctx.waitFor(() => ctx.document.querySelectorAll("[data-sort] > li").length > 5);
      },
    },
    "reorder-dragging": {
      note: 'Mid-drag (Leo, 2026-10-31: "THE CLICK DRAG" ... "WHERE IS MY FUCKING PARITY"): Outputs held by its six-dot handle and carried up into where it runs, over Context. The held section is lifted (a raised surface and a shadow, only while held) and follows the pointer; Usage and the sections under it have slid out of the way, and the hairlines follow the blocks now adjacent. Released, it settles there and the order is kept; Escape puts it back.',
      props: full,
      play: dragOutputsOverContext,
    },
    "grid-expanded": {
      note: "All Session Info sections expanded for shared lead, text, trail and spacing measurements.",
      props: { ...full, sections: { ...DEFAULT_SECTIONS, context: true, connectors: true } },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /4 finished/ });
      },
    },
    "layout-glance": {
      note: "Chosen (Leo, 2026-10-22: \"this session rail is tmi and too many boxes?\"). Eight cards became three blocks with a hairline between them and no box: the Environment's rows with no title, Context and Connectors one row each; Changes and Outputs; Subagents and Background tasks, the Servers card's row now heading Background tasks. Least ink of the three while every section and click stays; the rows line up under the panel's title.",
      props: full,
    },
    "layout-glance-open": {
      note: "The shipped layout with Context and Connectors opened in place: each row opens into its token counts or its servers, still with no box.",
      props: { ...full, sections: { ...DEFAULT_SECTIONS, context: true, connectors: true } },
    },
    "layout-rules": {
      note: "Alternative (not shipped): no boxes, every section keeps its title (Environment's too) with a hairline between each. Clear, but seven titles and seven rules still read as a stack of parts.",
      props: { ...full, layout: "rules" },
    },
    "layout-groups": {
      note: "Alternative (not shipped): the same three blocks as the shipped layout, each one hairline card (three boxes in place of eight). Groups well, but it is still boxes in a box.",
      props: { ...full, layout: "groups" },
    },
    "chrome-close-only": {
      note: "Chosen: the side panel has no title row, matching Codex and Claude desktop. Its close control floats at the top edge while the first Environment row starts below it, so the panel's content gets the space instead of repeating Session Info.",
      props: { ...full, closable: true, chrome: "close" },
    },
    "chrome-title": {
      note: "Alternative: the current titled treatment, with Session Info above the rows and the close control in that head. Clear, but it spends a full row repeating the panel name.",
      props: { ...full, closable: true, chrome: "title" },
    },
    "chrome-compact-close": {
      note: "Alternative: a compact control-only head keeps a close row without a title. It removes the repeated name, but still reserves a full strip before the Environment rows.",
      props: { ...full, closable: true, chrome: "compact-close" },
    },
    "environment-folders": {
      note: "Shipped (Leo, 2026-10-27: \"why are these files being shown to me in the first place\"): a chat in a lane checkout of cmux that worked across six folders. Environment lists only its project, by its repository's name (cmux, not the checkout's folder name), the full path only on hover; then the repository and the branch, each a link to GitHub. No folder its tool calls touched. The project opens in Files as a tab right of the chat.",
      props: environmentProps(),
    },
    "environment-branch-chip": {
      note: "Alternative (not shipped): the branch as a quiet chip at the end of the project's row, with no branch row. One row shorter, but the branch is no longer a link to GitHub and a long branch name crowds the project's name.",
      props: { ...environmentProps(), projectRowLook: "branch" },
    },
    "environment-parent": {
      note: "Alternative (not shipped): the project's name with its parent folder after it, as the Environment drew every folder before. The path text is what Leo asked not to see; the tooltip carries it in the shipped row.",
      props: { ...environmentProps(), projectRowLook: "parent" },
    },
    "environment-remote-control": {
      note: 'Shipped (Leo, 2026-10-28: "you don\'t even have the, like, remote control toggle functionality"; its pointer icon, as Claude Code desktop\'s Remote Control row, since 2026-11-01: "i think we should rethink what symbol we have for remote control at least"): a chat on this Mac while it can serve cmux on iPhone. Remote Control is the iPhone host\'s own switch (mobile.allowIPhoneConnections, as Settings > Mobile), so its tooltip says it covers every chat on this Mac. Off here; a chat on another machine, Quick Chat, or a Mac with no account signed in draws no row.',
      props: { ...environmentProps(), remoteControl: { on: false, set: () => undefined } },
    },
    "environment-remote-control-on": {
      note: "Shipped: the same chat with Remote Control on; cmux on the same account's iPhone can open this Mac's chats.",
      props: { ...environmentProps(), remoteControl: { on: true, set: () => undefined } },
    },
    "environment-remote-control-icon-phone-waves": {
      note: 'Alternative (not shipped): a phone with signal waves. Says "from your phone" more plainly than the bare outline it replaces, but it is still a phone first, the shape Leo asked to rethink, and the waves get busy at row size.',
      props: {
        ...environmentProps(),
        remoteControl: { on: true, set: () => undefined },
        remoteControlIcon: "mobile.pair",
      },
    },
    "environment-remote-control-icon-display": {
      note: 'Alternative (not shipped): a display. Reads as "a screen" rather than "control this chat from elsewhere", and beside the machine row\'s own Mac glyph it looks like a second machine.',
      props: {
        ...environmentProps(),
        remoteControl: { on: true, set: () => undefined },
        remoteControlIcon: "remote.display",
      },
    },
    "environment-remote-control-icon-phone": {
      note: 'Replaced (before 2026-11-01): the bare phone outline Leo asked to rethink ("i think we should rethink what symbol we have for remote control at least"). Taller and narrower than every other row icon.',
      props: {
        ...environmentProps(),
        remoteControl: { on: true, set: () => undefined },
        remoteControlIcon: "device.phone",
      },
    },
    "environment-remote-control-icon-link": {
      note: "Alternative (not shipped): a chain link. Fits the icon box well, but in this list it reads as a URL row (the repository and branch rows already link out).",
      props: { ...environmentProps(), remoteControl: { on: true, set: () => undefined }, remoteControlIcon: "link" },
    },
    "environment-scratchpad": {
      note: "Shipped: Leo's chat, run in a harness's scratchpad under /private/tmp, whose commands cd'd into a worktree. Before, Environment listed the scratchpad with its path and the worktree, and offered Save. Now only the machine: no folder row and no Save (a scratch folder is never a project).",
      props: {
        ...environmentProps(),
        summary: { ...summary, cwd: SCRATCHPAD, branch: undefined, worktree: undefined },
        repository: undefined,
      },
    },
    "context-connectors-open": {
      note: "Context and Connectors open: the percent used with the tokens, the bar, used and free space with their shares; each MCP server with its status.",
      props: { ...full, sections: { ...DEFAULT_SECTIONS, context: true, connectors: true } },
    },
    "context-compact-working": {
      note: "Shipped (Leo, 2026-10-28: \"You don't have the compact session\"; 2026-10-31: \"COMPACT BUTTON LITERALLY DOESN'T EVEN F***IN WORK\"): Context open while a turn runs. Compact session is a real button at the rows' trailing edge and stays live: its /compact queues behind the turn. A Claude chat's /context adds the tokens until auto-compact beside it (context-breakdown).",
      props: { ...full, sections: { ...DEFAULT_SECTIONS, context: true } },
    },
    "context-breakdown": {
      note: "Shipped: a Claude Code chat's /context in Context, open: 43% used with 171.4k / 400k, the bar split by category in steps of the theme accent (largest first; the autocompact buffer grey; free space the track), a row per category with its tokens and share, the deferred ones dimmed with no share, then the MCP tools, Memory files and Skills folds, MCP tools open.",
      props: breakdownProps,
      play: openMcpTools,
    },
    "context-autocompact-window": {
      note: "Shipped (Leo, 2026-11-02: \"whatever a user set their compact window to it should be that instead of always showing the defautl (e.g. we should be seieng 400k)\"): a 1M model whose chat compacts at 400K reads 43% with 171.4K / 400K, the window Claude Code's /context names, not the model's 1M.",
      props: {
        ...breakdownProps,
        summary: {
          ...summary,
          usageStats: breakdownUsage,
          contextBreakdown: CONTEXT_BREAKDOWN,
          usage: { used: 171_400, size: 1_000_000 },
        },
      },
      play: async (ctx) => {
        await ctx.waitFor(() => /171\.4K\s*\/\s*400K/.test(text(ctx)));
        if (/\/\s*1M/.test(text(ctx))) throw new Error("Context still reads the model's 1M window");
      },
    },
    "context-breakdown-hues": {
      note: "Alternative (not shipped): each category a different hue turned from the theme accent, as Claude Code desktop colors them. Reads faster, but brings colors the theme does not have.",
      props: {
        ...breakdownProps,
        tones: palette(
          [0, 60, 150, 210, 280, 320].map((turn) => `oklch(from var(--agent-accent) l c calc(h + ${turn}))`),
        ),
      },
      play: openMcpTools,
    },
    "context-breakdown-mono": {
      note: "Alternative (not shipped): every used category in the full accent, told apart only by the bar's gaps and the row order. Quietest, but the bar no longer says which part is which.",
      props: {
        ...breakdownProps,
        tones: palette(Array.from({ length: 6 }, () => "var(--agent-accent)")),
      },
      play: openMcpTools,
    },
    "changes-breakdown": {
      note: "Changes: hovering a pull request's line counts splits them into Code, Tests, Generated and Docs; its 3 failing checks dim the 2 already on base.",
      props: full,
      play: async (ctx) => {
        await ctx.waitFor(() => /already on base/.test(text(ctx)));
        await ctx.hover({ selector: ".acpmux-session-info-pr__counts" });
        await ctx.waitFor(() => /Generated/.test(ctx.document.body.textContent ?? ""));
      },
    },
    "changes-all": {
      note: "Changes after Show more: the open pull requests first (a draft in orange, one with conflicts in red), then the closed and merged ones by their glyphs, with no state word, and Show less.",
      props: full,
      play: async (ctx) => {
        await ctx.click({ selector: "button.acpmux-session-info-pr-fold" });
        await ctx.waitFor(() => /Show less/.test(text(ctx)));
      },
    },
    "row-hover": {
      note: "The pointer on a pull request's row: a faint tint of the text inside the body's padding, with the row radius, never a solid fill and never past the panel's edge. Every row in the panel hovers the same way.",
      props: full,
      play: async (ctx) => {
        await ctx.waitFor(() => /already on base/.test(text(ctx)));
        await ctx.hover({ selector: ".acpmux-session-info-pr" });
      },
    },
    "sources-hover": {
      note: "The pointer on a Sources link's row: one faint tint over the row, the link inside it never tinting a second time. An MCP tool's row takes no click, so it never lights.",
      props: full,
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector("a.acpmux-session-info-source__link") !== null);
        await ctx.hover({ selector: "a.acpmux-session-info-source__link" });
      },
    },
    "sources-folders": {
      note: "A chat started with two folders beside its own (acpmux additionalDirectories): Sources lists them first, by name with the path on hover, then what it read.",
      props: {
        ...full,
        summary: { ...summary, additionalDirectories: ["/Users/you/notes", "/Users/you/design/specs"] },
      },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector('[data-kind="folder"]') !== null);
        ctx.document.querySelector('[data-section="sources"]')?.scrollIntoView({ block: "center" });
      },
    },
    "subagents-open": {
      note: "A click on the ended row (40 done · 1 failed) opens their lines, the failed one first; each opens its subagent or chat.",
      props: full,
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /40 done · 1 failed/ });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-session-info-subagents__list") !== null);
      },
    },
    "subagent-limit": {
      note: 'Subagents with the chat\'s own running limit of 2: two of the chats it started run, a third waits for a slot ("1 queued"), with Reset back to the inherited limit and − / + beside it.',
      props: {
        ...full,
        summary: { ...summary, subsessionLimits: { maxRunning: 2, maxRunningSource: "session" } },
        sessions: [
          ...sessions.slice(1),
          { sessionId: "child-4", title: "Profile the sidebar", state: "running", createdAt: started - 300_000 },
          {
            sessionId: "child-5",
            title: "Audit the strings",
            state: "idle",
            waitsForSlot: true,
            createdAt: started - 200_000,
          },
        ],
      },
    },
    "subagent-limit-hidden-default": {
      note: "A chat that never started a subagent or a chat, at acpmux's default running limit: no Subagents card at all.",
      props: { summary, machineName: "Studio", onSetRunningLimit: async () => undefined },
    },
    "subagent-limit-set-no-rows": {
      note: "No subagents or chats yet, but the settings set the running limit to 4: Subagents shows only that limit, with − and +.",
      props: {
        summary: { ...summary, subsessionLimits: { maxRunning: 4, maxRunningSource: "settings" } },
        machineName: "Studio",
        onSetRunningLimit: async () => undefined,
      },
    },
    "subagents-busy": {
      note: "A busy coordinator: the first five of seventeen running subagents and chats, the one waiting on the person first, then Show 12 more and the 94 done · 1 failed row.",
      props: busy,
    },
    "subagents-busy-more": {
      note: "Show 12 more opens every running line; Show less folds them back to five.",
      props: busy,
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /Show 12 more/ });
        await ctx.waitFor(() => /Show less/.test(text(ctx)));
      },
    },
    "subagents-idle": {
      note: 'Subagents that stopped and wait on background work of their own read Idle, not Running for two hours, and the head counts them as idle ("3 running · 2 idle · 1 done"). Every line is named by its task, never its id. The limit line says it caps the chats this one started: "Started chats: 0 of 1000 at once".',
      props: {
        ...full,
        agents: idleAgents,
        sessions: [],
        summary: {
          ...summary,
          harness: "claude",
          subsessionLimits: { maxRunning: 1000, maxRunningSource: "settings" },
        },
      },
      play: async (ctx) => {
        await ctx.waitFor(() => /2 idle/.test(text(ctx)) && /Started chats: 0 of 1000 at once/.test(text(ctx)));
      },
    },
    "subagents-wave": {
      note: "Five running subagents, one per line, share one shimmer that sweeps down their icons, held mid-sweep for the still: dim, brighter, the crest, brighter, dim. The row of the done and the failed one under them stays at full strength.",
      props: { ...full, agents: waveAgents, sessions: [] },
      play: holdWave,
    },
    "tasks-finished": {
      note: "Background tasks: the running watcher with how long it has run and Stop, the transcript's pytest without Stop, then the four finished commands, open.",
      props: full,
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /4 finished/ });
        await ctx.waitFor(() => /cargo build/.test(text(ctx)));
      },
    },
    "tasks-scheduled": {
      note: "Background tasks with mixed kinds: the running command (terminal), the two waits still ahead (clock, with the time each wakes) and the hourly pass (repeat, 'hourly at :17', not '17 * * * *'). The waits whose time passed, the removed poll, the job past its 7 days and the failed call fold into 6 finished, latest first: Failed, Done · 5m, Cancelled, Done · 12m, Done · 4m, Expired.",
      props: scheduledProps,
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /6 finished/ });
        await ctx.waitFor(() => /Expired/.test(text(ctx)));
      },
    },
    "cloud-empty": {
      note: "A Cloud chat before the agent reports usage or edits anything: Context and Outputs have no sections yet.",
      props: {
        cloudRepositoryAvailable: true,
        summary: {
          ...local.summary!,
          cwd: "/workspace/atlas-web",
          host: "build-runner-2",
          hostKind: "cloud",
          branch: undefined,
          usage: undefined,
        },
      },
    },
    "outputs-artifacts": {
      note: "Outputs as Claude Code desktop lists them: each artifact by its title with an Artifact tag (each opens in the side panel), the gallery, the files with their line counts, the links with a Link tag.",
      props: {
        ...full,
        documents: outputArtifacts(producedRows),
        onOpenDocument: () => undefined,
        sections: { ...DEFAULT_SECTIONS, changes: false, subagents: false, tasks: false, servers: false },
      },
    },
    "fits-content": {
      note: "A chat with little to show, over a 900px pane: Environment and Context only. The card ends right after Context, with the body's 10px under it and no fixed or minimum height: the ceiling (the room under the header) is only a maximum (Leo, 2026-10-22: \"the card should just end when there's no more content to show\").",
      props: {
        summary: { ...summary, mcpServers: [] },
        machineName: "Studio",
        repository: "manaflow-ai/cmux",
        onSaveEnvironment: () => undefined,
        closable: true,
      },
    },
    "scroller-none": {
      note: "Chosen. A busy coordinator: the body scrolls by wheel, trackpad and keyboard with no scrollbar at all, as Claude Code's panel, and its edge fades say there is more; nothing takes width at the right edge, so no thumb sits by a section's grip (Leo, 2026-11-03: \"i mean there's literally no scrollbar in claude code it's just scrollable\"). The play scrolls it and checks it keeps no scrollbar width.",
      props: { ...busy, closable: true },
      play: scrollsWithNoScrollbar,
    },
    "scroller-thumb": {
      note: 'Before, for comparison: a thin thumb drawn at the right edge beside the section grips (Leo, 2026-11-03: "there\'s basically no thumb on the claude code session info section").',
      props: { ...busy, closable: true, scroller: "thumb" },
    },
    ceiling: {
      note: "Chosen. A busy coordinator over the same 900px pane: the card uses the full room under the header, less its 8px inset at the foot, and only then does its body scroll; it still floats over the chat with its own edge (Leo, 2026-10-26: \"you still haven't done the full-length thing. It's still just this constrained height for, like, no reason at all\").",
      props: { ...busy, closable: true },
    },
    "ceiling-capped": {
      note: 'Before, for comparison: the old ceiling, the smallest of 560px and 80% of the room under the header, so a busy card stopped with room left and scrolled (Leo: "this constrained height for, like, no reason at all").',
      props: {
        ...busy,
        closable: true,
        ceiling:
          "min(560px, calc((100% - var(--acpmux-session-info-top, 0px)) * 0.8), calc(100% - var(--acpmux-session-info-top, 0px) - var(--acpmux-session-info-inset)))",
      },
    },
    "ceiling-most": {
      note: "Alternative: 90% of the room under the header, leaving a band of the chat under the card.",
      props: { ...busy, closable: true, ceiling: "calc((100% - var(--acpmux-session-info-top, 0px)) * 0.9)" },
    },
    push: {
      note: 'Pushed: the panel sits beside the chat and narrows it. Nothing runs under it, so it draws no card: its sections sit on the pane with no fill, blur or shadow, as the native panel (#32661; Leo, 2026-11-02: "we still HAVE AN ASININE BACKGROUND").',
      props: { ...full, placement: "push" },
      play: noCardBehind,
    },
    "header-chevron-hover": {
      note: "A section head under the pointer: its fold chevron shows one grid gap after the title (cmux#32765, as native #32674). At rest no head draws a chevron, and its room is kept, so the title never moves.",
      props: { ...full, placement: "push" },
      play: chevronOnHoverAfterTitle,
    },
    "header-grip-hover": {
      note: 'A section head under the pointer: the six-dot grip shows left of the title, wholly inside the head\'s pill in its leading padding and on its middle line (Leo, 2026-11-03: "why dont we have the drag grabber to the left of the title"; 2026-11-04, of the grip centred on the pill\'s edge: "this is off"). The title does not move. At rest no grip draws, and a pointer over the section\'s other rows shows none.',
      props: { ...full, placement: "push" },
      play: gripOnHeadHoverOnly,
    },
    "header-grip-edge": {
      note: 'Before, for comparison: the grip centred on the head\'s left edge, half on and half off its pill, as cmux#34269 drew it (Leo, 2026-11-04: "this is off").',
      props: { ...full, placement: "push", edge: "--acpmux-session-info-grip-center:0px" },
      play: hoverFirstHead,
    },
    "header-grip-gutter": {
      note: "Compared, not chosen: the wide grip wholly in the gutter left of the pill. It reads as detached from its row and runs into the panel's resize edge.",
      props: { ...full, placement: "push", edge: "--acpmux-session-info-grip-center:calc(-1 * var(--grid-base))" },
      play: hoverFirstHead,
    },
    "header-grip-tall": {
      note: "Before, for comparison: the grip turned upright (two across, three down), as cmux#32930 drew it.",
      props: { ...full, placement: "push", edge: "--acpmux-session-info-grip-turn:rotate(90deg)" },
      play: hoverFirstHead,
    },
    "header-grip-left": {
      note: "Every section's grip, icon heads and the bare Environment rows included, sits left of its head's icon or title, away from the scrollbar's thumb on the right.",
      props: { ...full, placement: "push" },
      play: gripLeftOfEveryTitle,
    },
    "edge-hairline": {
      note: "Chosen. The panel in the gutter with no fill of its own and a hairline edge in the pane's border color (--agent-border, 0.5px) on its rounded corners (Leo, 2026-11-03: \"maybe it's ok...? to HAVE NO BACKGROUND FOR THE SESSION INFO / but i think having a border for it might be better\").",
      props: { ...full },
      play: hairlineEdge,
    },
    "edge-hairline-over-chat": {
      note: "Chosen, over the chat's column: the same hairline over the glass. Without the glass the transcript's text would read through the panel's own, so it keeps the blur and tint there.",
      props: { ...full, transcript: true },
      play: hairlineEdge,
    },
    "edge-none": {
      note: "Before, for comparison: no fill and no edge, so the panel's sections float on the pane with nothing marking where it ends.",
      props: { ...full, edge: "border-color:transparent" },
    },
    "edge-strong": {
      note: "Alternative: a stronger edge (--agent-border-strong). It reads as a box drawn around the panel.",
      props: { ...full, edge: "border-color:var(--agent-border-strong)" },
    },
    "over-chat-blur-only": {
      note: "Alternative over the chat: the hairline and the blur with no tint. Light transcript text still shows through the panel's rows, so the chosen look keeps the tint.",
      props: { ...full, transcript: true, edge: "--glass-tint:transparent" },
    },
    "subagent-parent": {
      note: "The chat's own panel while a subagent works in a worktree: the chat's folder, branch, context, pull requests and tasks, and its Subagents list, which opens each subagent's own panel.",
      props: { ...full, agents: [worktreeAgent, { ...sharedAgent }, ...agents.slice(3, 8)] },
    },
    "subagent-title": {
      note: "Chosen. A subagent's own panel, the head naming it: back, then Subagent · Fix the timeouts. Its Environment is its worktree (agent-a3f9c2) and branch, not the chat's; Context is its 48.2K tokens and 14 tool uses; Background tasks its own watcher; Outputs the two files it edited in the worktree. No Connectors, chats or Save: those are the chat's.",
      props: { ...subagentPanel, header: "title" },
    },
    "subagent-crumb": {
      note: "Alternative: the head keeps Session Info, and the body's first line is a path, the chat's name (back) › Subagent · Fix the timeouts.",
      props: { ...subagentPanel, header: "crumb" },
    },
    "subagent-card": {
      note: "Alternative: a bordered card above the sections, the agent glyph, Subagent · Fix the timeouts with its task under it, and Back to the chat.",
      props: { ...subagentPanel, header: "card" },
    },
    "subagent-shared-checkout": {
      note: "A subagent in the chat's own checkout (an Explore run): its folder and branch are the chat's, its context its own tokens and tool uses, and it made no outputs.",
      props: {
        summary: subagentSummary(summary, sharedAgent, sharedRows),
        machineName: "Studio",
        repository: "manaflow-ai/cmux",
        made: sessionSummary(sharedRows, "manaflow-ai/cmux"),
        rows: sharedRows,
        agent: sharedAgent,
        scope: scopeOf(sharedAgent),
      },
    },
    "glass-over-transcript": {
      note: "The panel over a busy transcript: liquid glass, never opaque, so the prompts, replies and code under it frost through; no section is a box, only a hairline between its three blocks. Under Reduce Transparency the panel is the opaque theme surface.",
      props: { ...full, transcript: true },
    },
  },
});
