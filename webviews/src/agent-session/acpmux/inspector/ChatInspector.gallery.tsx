// l10n-allow-file: gallery fixtures (sample sessions, pull requests and commands), not shipped UI.
// The Inspector (Debug Settings `agent.inspector`, on by default) as the real ChatInspector renders it
// in its panel at the right of a chat: a full chat with every section, its Context and Connectors
// open, its Changes with line breakdowns, failing checks and owners, its subagents' list open, its
// finished tasks open, a Cloud chat before its first usage report, and the panel over the chat
// (Overlay). Light and dark come from the gallery's theme switch.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { activity, chat, CWD, tool } from "../../../gallery/fixtures/acpmux";
import type { Subagent } from "../subagents/subagentFold";
import { sessionSummary } from "../summary/sessionSummary";
import { ChatInspector, InspectorPanel, type InspectorPlacement } from "./ChatInspector";
import { DEFAULT_SECTIONS } from "./inspectorState";

type Props = ComponentProps<typeof ChatInspector> & { placement?: InspectorPlacement };

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

function GalleryInspector({ placement = "push", ...props }: Props) {
  return (
    <div className="acpmux-shell" style={{ display: "flex", justifyContent: "flex-end", height: "100%" }}>
      <InspectorPanel width={320} placement={placement}>
        <ChatInspector {...props} />
      </InspectorPanel>
    </div>
  );
}

/// Pull requests the chat opened or touched (oldest first, as sessionSummary reads them).
const pullRequests: NonNullable<Props["made"]>["pullRequests"] = [
  { n: 22217, title: "cmux NEXT: Cmd-W closes a pinned tab's split", opened: true },
  { n: 22227, title: "New Tab Now Playing: right-click menu and a setting to hide it", opened: false },
  { n: 22228, title: "cmux NEXT: the thread minimap feels like the Codex rail", opened: true },
  { n: 22229, title: "cmux NEXT Home list: one-row sessions", opened: true },
  { n: 22231, title: "cmux NEXT New Tab: paste an image into the composer", opened: true },
  { n: 22240, title: "Inspector: the chat's right-hand panel", opened: true },
].map(({ n, title, opened }) => ({
  url: `https://github.com/manaflow-ai/cmux/pull/${n}`,
  repo: "manaflow-ai/cmux",
  number: n,
  title,
  opened,
  state: n === 22229 ? ("merged" as const) : ("open" as const),
}));
const pr = (n: number) => `https://github.com/manaflow-ai/cmux/pull/${n}`;
/// What the App read of them: line counts split by kind, failing checks against the base, owners.
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
    checks: "failing",
    failing: 3,
    failingOnBase: 2,
    owner: "inspector",
  },
  [pr(22231)]: { additions: 96, deletions: 12, checks: "passing", owner: "newtab" },
  [pr(22228)]: { additions: 240, deletions: 88, checks: "pending" },
  [pr(22227)]: { checks: "failing", failing: 1, owner: "teamleaderleo" },
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
  onStopProcess: async () => undefined,
  onOpenUrl: () => undefined,
  onOpenOutput: () => undefined,
  onOpenSubagent: () => undefined,
  onSaveEnvironment: () => undefined,
  remoteControl: { on: false, set: () => undefined },
};

const text = (ctx: Parameters<Play>[0]) => ctx.document.querySelector(".acpmux-inspector")?.textContent ?? "";

export default componentEntry<Props>({
  id: "agent-pane.chat-inspector",
  title: "Inspector",
  area: "Agent pane",
  pane: true,
  height: 900,
  widths: { narrow: 320, normal: 420 },
  covers: [
    "agent-session/acpmux/inspector/ChatInspector.tsx",
    "agent-session/acpmux/inspector/ChangesSection.tsx",
    "agent-session/acpmux/inspector/EnvironmentSection.tsx",
    "agent-session/acpmux/inspector/InspectorSection.tsx",
    "agent-session/acpmux/inspector/OutputsSection.tsx",
    "agent-session/acpmux/inspector/ServersSection.tsx",
    "agent-session/acpmux/inspector/SubagentsSection.tsx",
    "agent-session/acpmux/inspector/TasksSection.tsx",
  ],
  load: async () => GalleryInspector,
  variants: {
    full: {
      note: "A chat on this Mac with every section: its environment with Save and Remote Control, 47% of the context window, one connector to reconnect, six pull requests, a dev server on :5173, 43 subagents, background tasks with three finished, and its outputs.",
      props: full,
    },
    "context-connectors-open": {
      note: "Context and Connectors open: the token counts, and each MCP server with the one that needs reconnecting.",
      props: { ...full, sections: { ...DEFAULT_SECTIONS, context: true, connectors: true } },
    },
    "changes-breakdown": {
      note: "Changes: hovering a pull request's line counts splits them into Code, Tests, Generated and Docs; its 3 failing checks dim the 2 already on base.",
      props: full,
      play: async (ctx) => {
        await ctx.waitFor(() => /already on base/.test(text(ctx)));
        await ctx.hover({ selector: ".acpmux-inspector-pr__counts" });
        await ctx.waitFor(() => /Generated/.test(ctx.document.body.textContent ?? ""));
      },
    },
    "subagents-open": {
      note: "A click on the avatar row opens the list of the chat's subagents: Active, then Done.",
      props: full,
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /Show 43 subagents/ });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-inspector-subagents__list") !== null);
      },
    },
    "tasks-finished": {
      note: "Background tasks: the running watcher with how long it has run and Stop, then the three finished commands, open.",
      props: full,
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /3 finished/ });
        await ctx.waitFor(() => /cargo build/.test(text(ctx)));
      },
    },
    "cloud-empty": {
      note: "A Cloud chat before the agent reports usage or edits anything: Context reads a dash, Outputs says nothing yet.",
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
    overlay: {
      note: "Settings > Agent Chat > Inspector set to Overlay: the panel lies over the chat with a shadow instead of pushing it aside.",
      props: { ...full, placement: "overlay" },
    },
  },
});
