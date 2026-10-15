// l10n-allow-file: gallery fixtures (sample sessions and files), not shipped UI.
// The session side rail (Debug Settings `agent.sessionRail`) as the real SessionRail renders it beside a chat: a
// local chat with some context used and three files written, and a Cloud chat before its first
// usage report and edit, and a chat whose harness reported MCP servers. Light and dark come from the gallery's theme switch.
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

export default componentEntry<Props>({
  id: "agent-pane.session-rail",
  title: "Session side rail",
  area: "Agent pane",
  pane: true,
  experimental: true,
  height: 420,
  widths: { narrow: 300, normal: 360 },
  covers: ["agent-session/acpmux/summary/SessionRail.tsx"],
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
