// l10n-allow-file: gallery fixtures (sample sessions, pull requests and commands), not shipped UI.
// The Inspector (Debug Settings `agent.inspector`, on by default) as the real ChatInspector renders it
// in its panel at the right of a chat: a full chat with every section, its Context and Connectors
// open, its Changes across repositories with line breakdowns, comments, failing checks and owners
// (all of them after Show more), its running subagents and chats named one per line with the ended
// ones folded into one row (and that row open), a busy chat's seventeen running past "Show more", the
// running lines' wave held mid-sweep, its finished tasks open (a background Bash only the transcript
// knows among them), a Cloud chat before its first usage report, and the panel over the chat
// (Overlay). Light and dark come from the gallery's theme switch.
import type { ComponentProps, CSSProperties } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play, PlayContext } from "../../../gallery/play";
import { WAVE_CLASS, WAVE_KEYFRAMES } from "../../../ui/wave";
import { activity, assistant, chat, CONTEXT_BREAKDOWN, CWD, tool } from "../../../gallery/fixtures/acpmux";
import type { StartedSession } from "../started/startedSessions";
import type { Subagent } from "../subagents/subagentFold";
import { sessionSummary } from "../summary/sessionSummary";
import { ChatInspector, InspectorPanel, type InspectorPlacement } from "./ChatInspector";
import { outputArtifacts } from "./OutputsSection";
import { DEFAULT_SECTIONS } from "./inspectorState";

type Props = ComponentProps<typeof ChatInspector> & {
  placement?: InspectorPlacement;
  transcript?: boolean;
  /// A gallery-only palette for the Context breakdown's categories (ContextSection.css tones).
  tones?: CSSProperties;
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
  "Make the Inspector glass, and its cards bordered with no fill.",
  "The panel paints the chat's page color, so nothing behind it shows. I'll give it the shared glass and drop the cards' fill.",
  '<aside className="ui-glass ui-glass-floats acpmux-chat-inspector">\n  {sections}\n</aside>',
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

function GalleryInspector({ placement = "overlay", transcript = false, tones, ...props }: Props) {
  return (
    <div className="acpmux-shell" style={{ display: "flex", justifyContent: "flex-end", height: "100%", ...tones }}>
      {transcript ? <Transcript /> : null}
      <InspectorPanel width={320} placement={placement}>
        <ChatInspector {...props} />
      </InspectorPanel>
    </div>
  );
}

/// Pull requests the chat opened or touched across repositories (oldest first, as sessionSummary
/// reads them).
const pullRequests: NonNullable<Props["made"]>["pullRequests"] = [
  { n: 22217, title: "cmux NEXT: Cmd-W closes a pinned tab's split", opened: true, state: "merged" },
  { repo: "acme/billing", n: 7, title: "billing: retry webhooks on a 502", opened: false, state: "closed" },
  { n: 22227, title: "New Tab Now Playing: right-click menu and a setting to hide it", opened: false },
  { n: 22228, title: "cmux NEXT: the thread minimap feels like the Codex rail", opened: true },
  { n: 22229, title: "cmux NEXT Home list: one-row sessions", opened: true, state: "merged" },
  { repo: "acme/atlas-web", n: 412, title: "atlas: dark mode tokens for the settings page", opened: true },
  { n: 22231, title: "cmux NEXT New Tab: paste an image into the composer", opened: true },
  { n: 22240, title: "Inspector: the chat's right-hand panel", opened: true },
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
    owner: "inspector",
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
  ...(index < 3 ? { action: "Reading ChatInspector.tsx" } : { endedAt: started - index * 100_000 }),
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
  ...(index < RUNNING ? { action: "Reading ChatInspector.tsx" } : { endedAt: started - index * 30_000 }),
}));

/// Where the play holds every wave loop: one point on each loop's own timeline, past its delay (the
/// delay is never positive, wave.css), so each icon's phase differs only by its index. At 560 ms
/// the crest (20% of the 1.6 s period) is on the third line: the two before it fall from it, the
/// two after it rise toward it, so a still reads dim, brighter, crest, brighter, dim.
const WAVE_HOLD_MS = 560;

/// The page's wave loops (CSS animations of `cmux-wave`).
const waveLoops = (ctx: PlayContext) =>
  ctx.document
    .getAnimations()
    .filter((animation) => (animation as CSSAnimation).animationName === WAVE_KEYFRAMES) as CSSAnimation[];

/// Holds the wave mid-sweep for a still. A loop is held only once installWave has moved it onto the
/// shared epoch (its start is a whole number of periods of Unix time): a loop paused before that is
/// restarted by the realignment, which scrambled the wave. Then all of them pause at one point.
const holdWave: Play = async (ctx) => {
  const items = () => ctx.document.querySelectorAll(`.acpmux-chat-inspector-subagents .${WAVE_CLASS}`);
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

const summary = {
  ...local.summary!,
  usage: { used: 94_000, size: 200_000 },
  branch: "feat/next-inspector",
  mcpServers: [
    { name: "github", status: "connected" as const },
    { name: "linear", status: "failed" as const },
    { name: "sentry", status: "pending" as const },
  ],
};

const full: Props = {
  summary,
  machineName: "Studio",
  repository: "manaflow-ai/cmux",
  made: { ...made, pullRequests },
  links: [
    { url: "https://cmux.com/docs/inspector", label: "cmux.com/docs/inspector" },
    { url: "https://claude.ai/artifact/inspector-plan", label: "claude.ai/artifact/inspector-plan" },
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
  onOpenSubagent: () => undefined,
  onSaveEnvironment: () => undefined,
  remoteControl: { on: false, set: () => undefined },
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
}));
const LANES = ["summary-panel", "priority-view", "lane-host", "machine-hygiene", "paired-approvals"];
const busySessions: StartedSession[] = LANES.map((title, index) => ({
  sessionId: `lane-${index}`,
  title,
  state: index === 1 ? "waiting" : "running",
  createdAt: started - (index + 1) * 300_000,
}));
const busy: Props = { ...full, agents: busyAgents, sessions: busySessions };

/// A chat in ~/Projects that worked across several projects, as Claude Code desktop lists them.
const PROJECTS = "/Users/you/Projects";
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
      touched("glaeda/main.go"),
    ],
    6,
  ),
];

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
  assistant("Here is the plan:\n\n```markdown\n# Inspector rollout\n\n- Context\n- Outputs\n```\n", 2),
];

/// A Claude Code chat with its /context breakdown, Context open and the long sections folded so the
/// card shows whole.
const breakdownProps: Props = {
  ...full,
  summary: { ...summary, usage: { used: 171_400, size: 400_000 }, contextBreakdown: CONTEXT_BREAKDOWN },
  sections: { ...DEFAULT_SECTIONS, environment: false, context: true, changes: false, subagents: false, tasks: false },
};
/// A gallery-only palette for the breakdown's used categories, largest first.
const palette = (colors: string[]) =>
  Object.fromEntries(colors.map((color, index) => [`--acpmux-context-tone-${index}`, color])) as CSSProperties;
const openMcpTools: Play = async (ctx) => {
  await ctx.click({ selector: '[data-list="mcpTools"] button' });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-context-breakdown__items") !== null);
};

const text = (ctx: Parameters<Play>[0]) => ctx.document.querySelector(".acpmux-chat-inspector")?.textContent ?? "";

export default componentEntry<Props>({
  id: "agent-pane.chat-inspector",
  title: "Inspector",
  area: "Agent pane",
  pane: true,
  height: 900,
  widths: { narrow: 320, normal: 420 },
  covers: [
    "agent-session/acpmux/inspector/ChatInspector.tsx",
    "agent-session/acpmux/inspector/chatFolders.ts",
    "agent-session/acpmux/inspector/ChildSessionRows.tsx",
    "agent-session/acpmux/inspector/ChangesSection.tsx",
    "agent-session/acpmux/inspector/ContextSection.tsx",
    "agent-session/acpmux/inspector/PullRequestGlyph.tsx",
    "agent-session/acpmux/inspector/EnvironmentSection.tsx",
    "agent-session/acpmux/inspector/InspectorSection.tsx",
    "agent-session/acpmux/inspector/OutputsSection.tsx",
    "agent-session/acpmux/inspector/ServersSection.tsx",
    "agent-session/acpmux/inspector/SubagentsSection.tsx",
    "agent-session/acpmux/inspector/TasksSection.tsx",
    "agent-session/acpmux/subagents/AgentLine.tsx",
  ],
  load: async () => GalleryInspector,
  variants: {
    full: {
      note: "A chat on this Mac with every section: its environment with Save and Remote Control, 47% of the context window, one connector to reconnect, eight pull requests across three repositories (five shown, then Show more), a dev server on :5173, three running subagents and two running chats named one per line with the 40 done · 1 failed row under them, background tasks (one only the transcript knows, without Stop) with four finished, and its outputs.",
      props: full,
    },
    "environment-folders": {
      note: "Environment for a chat in ~/Projects/cmux that worked across six projects: the machine with Save, its folder with its parent, each other project it touched (each opens in Files), the repository and the branch (each links to GitHub).",
      props: {
        ...full,
        summary: { ...summary, cwd: `${PROJECTS}/cmux`, branch: "leo/next-backgrounds-batch" },
        rows: projectRows,
        onOpenFolder: () => undefined,
        remoteControl: undefined,
      },
    },
    "context-connectors-open": {
      note: "Context and Connectors open: the percent used with the tokens, the bar, used and free space with their shares; each MCP server with its status.",
      props: { ...full, sections: { ...DEFAULT_SECTIONS, context: true, connectors: true } },
    },
    "context-breakdown": {
      note: "Shipped: a Claude Code chat's /context in Context, open: 43% used with 171.4k / 400k, the bar split by category in steps of the theme accent (largest first; the autocompact buffer grey; free space the track), a row per category with its tokens and share, the deferred ones dimmed with no share, then the MCP tools, Memory files and Skills folds, MCP tools open.",
      props: breakdownProps,
      play: openMcpTools,
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
        await ctx.hover({ selector: ".acpmux-chat-inspector-pr__counts" });
        await ctx.waitFor(() => /Generated/.test(ctx.document.body.textContent ?? ""));
      },
    },
    "changes-all": {
      note: "Changes after Show more: the open pull requests first (a draft in orange, one with conflicts in red), then the closed and merged ones by their glyphs, with no state word, and Show less.",
      props: full,
      play: async (ctx) => {
        await ctx.click({ selector: "button.acpmux-chat-inspector-pr-fold" });
        await ctx.waitFor(() => /Show less/.test(text(ctx)));
      },
    },
    "row-hover": {
      note: "The pointer on a pull request's row: a faint tint of the text inside the card's padding, with the card's radius less that padding, never a solid fill and never past the card's edge. Every row in the panel hovers the same way.",
      props: full,
      play: async (ctx) => {
        await ctx.waitFor(() => /already on base/.test(text(ctx)));
        await ctx.hover({ selector: ".acpmux-chat-inspector-pr" });
      },
    },
    "subagents-open": {
      note: "A click on the ended row (40 done · 1 failed) opens their lines, the failed one first; each opens its subagent or chat.",
      props: full,
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /40 done · 1 failed/ });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-chat-inspector-subagents__list") !== null);
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
    "cloud-empty": {
      note: "A Cloud chat before the agent reports usage or edits anything: Context and Outputs have no sections yet.",
      props: {
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
    push: {
      note: "Settings > Agent Chat > Inspector set to Push: the panel sits beside the chat and narrows it, instead of lying over it with a shadow. It is glass there too, with its left hairline as its only edge.",
      props: { ...full, placement: "push" },
    },
    "glass-over-transcript": {
      note: "The panel over a busy transcript: liquid glass, never opaque, so the prompts, replies and code under it frost through; its cards are hairline borders with no fill. Under Reduce Transparency the panel is the opaque theme surface.",
      props: { ...full, transcript: true },
    },
  },
});
