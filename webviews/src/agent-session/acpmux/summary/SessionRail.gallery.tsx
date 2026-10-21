// l10n-allow-file: gallery fixtures (sample sessions and files), not shipped UI.
// The session side rail (Debug Settings `agent.sessionRail`) as the real SessionRail renders it beside a chat: a
// local chat with some context used and three files written, and a Cloud chat before its first
// usage report and edit, a chat whose harness reported MCP servers, and a chat that opened pull requests. Light and dark come from the gallery's theme switch.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { activity, chat, CWD, tool } from "../../../gallery/fixtures/acpmux";
import { SessionRail } from "./SessionRail";
import { sessionSummary } from "./sessionSummary";

type Props = ComponentProps<typeof SessionRail>;

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

function GallerySessionRail(props: Props) {
  return (
    <div className="acpmux-shell" style={{ justifyContent: "flex-end", height: "100%" }}>
      <SessionRail {...props} />
    </div>
  );
}

const toggleContext: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /Context/ });
  await ctx.waitFor(() => /tokens/.test(ctx.document.querySelector(".acpmux-rail")?.textContent ?? ""));
};

/// Pull requests the chat opened (oldest first, as sessionSummary reads them), and what the App
/// read of them.
const pullRequests: NonNullable<Props["pullRequests"]> = [
  { n: 22217, title: "cmux NEXT: Cmd-W closes a pinned tab's split" },
  { n: 22227, title: "New Tab Now Playing: right-click menu and a setting to hide it" },
  { n: 22228, title: "cmux NEXT: the thread minimap feels like the Codex rail" },
  { n: 22229, title: "cmux NEXT Home list: one-row sessions" },
  { n: 22231, title: "cmux NEXT New Tab: paste an image into the composer" },
  { n: 22240, title: "Session rail: a Changes card" },
].map(({ n, title }) => ({
  url: `https://github.com/manaflow-ai/cmux/pull/${n}`,
  repo: "manaflow-ai/cmux",
  number: n,
  title,
  state: n === 22229 ? ("merged" as const) : ("open" as const),
}));
/// The App reads live status for the chat folder's pull request only (the header chip).
const statuses: NonNullable<Props["statuses"]> = {
  "https://github.com/manaflow-ai/cmux/pull/22231": { checks: "failing" },
};

/// Background processes as acpmux's registry lists them: two running, three finished.
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

export default componentEntry<Props>({
  id: "agent-pane.session-rail",
  title: "Session side rail",
  area: "Agent pane",
  pane: true,
  experimental: true,
  height: 560,
  widths: { narrow: 300, normal: 360 },
  covers: [
    "agent-session/acpmux/summary/SessionRail.tsx",
    "agent-session/acpmux/summary/RailChanges.tsx",
    "agent-session/acpmux/summary/RailTasks.tsx",
  ],
  load: async () => GallerySessionRail,
  variants: {
    "local-usage-outputs": {
      note: "A chat on this Mac: its folder and branch, 12% of the context window, three files written.",
      props: {
        summary: { ...local.summary!, usage: { used: 24_000, size: 200_000 }, branch: "feat/fetch-retries" },
        machineName: "Studio",
        outputs: sessionSummary(local.rows).outputs,
      },
      play: toggleContext,
    },
    connectors: {
      note: "A Claude Code chat that loaded three MCP servers, one failed and one still connecting; Connectors open.",
      props: {
        summary: {
          ...local.summary!,
          usage: { used: 24_000, size: 200_000 },
          mcpServers: [
            { name: "github", status: "connected" },
            { name: "linear", status: "failed" },
            { name: "sentry", status: "pending" },
          ],
        },
        machineName: "Studio",
        outputs: sessionSummary(local.rows).outputs,
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /Connectors/ });
        await ctx.waitFor(() => /sentry/.test(ctx.document.querySelector(".acpmux-rail")?.textContent ?? ""));
      },
    },
    changes: {
      note: "A chat that opened six pull requests: newest first, checks failing on the one the App reads, a merged one, the sixth behind Show more.",
      props: {
        summary: { ...local.summary!, usage: { used: 94_000, size: 200_000 }, branch: "feat/rail-changes" },
        machineName: "Studio",
        outputs: sessionSummary(local.rows).outputs,
        pullRequests,
        statuses,
      },
    },
    tasks: {
      note: "A chat running two background commands, newest first with how long each has run and Stop; three finished.",
      props: {
        summary: { ...local.summary!, usage: { used: 94_000, size: 200_000 }, branch: "feat/rail-tasks" },
        machineName: "Studio",
        outputs: sessionSummary(local.rows).outputs,
        processes,
        onStopProcess: async () => undefined,
      },
    },
    "cloud-empty": {
      note: "A Cloud chat before the agent reports usage or edits anything: Context reads a dash.",
      props: {
        summary: {
          ...local.summary!,
          cwd: "/workspace/atlas-web",
          host: "build-runner-2",
          hostKind: "cloud",
          branch: undefined,
          usage: undefined,
        },
        outputs: [],
      },
    },
  },
});
