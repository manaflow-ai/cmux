// l10n-allow-file: developer gallery fixtures and descriptions, not shipped UI.
import { useEffect } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { experimentArm } from "../../../experiments/experiment";
import { setNativeHost } from "../native";
import type { AcpmuxActivity } from "../model";
import { McpCallRows } from "./McpCallRows";
import { githubConnect } from "./githubConnect.experiment";

type Props = { outcome: "opened" | "failed" | "denied"; grouped?: boolean };

const connect =
  (failed = false): Play =>
  async (ctx) => {
    if (experimentArm(githubConnect) !== "on") return;
    await ctx.click({ role: "button", name: "Connect GitHub" });
    await ctx.waitFor(
      () =>
        ctx.document.documentElement.dataset.galleryGitHubConnect ===
        JSON.stringify({ method: "github.connect", params: {} }),
    );
    if (failed) await ctx.waitFor(() => ctx.document.querySelector('[role="alert"]'));
  };
const refusal = (denied: boolean): AcpmuxActivity => ({
  kind: "tool_call",
  text: "Read GitHub profile",
  tool: {
    id: "github-connect-gallery",
    title: "mcp__github__get_me",
    status: "failed",
    inputSummary: "{}",
    output: JSON.stringify({
      isError: true,
      content: [
        {
          type: "text",
          text: denied ? "Team policy refused this operation." : "GitHub is not connected for this team.",
        },
      ],
      structuredContent: {
        error: {
          code: denied ? "policy.denied" : "github.not_connected",
          retryable: !denied,
          connect: { action: "accounts.githubConnect" },
        },
      },
    }),
  },
});

export default componentEntry<Props>({
  id: "agent-pane.github-connect-inline",
  title: "Inline GitHub connection",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 220,
  widths: { narrow: 360, normal: 560, wide: 720 },
  covers: [
    "agent-session/acpmux/conversation/GitHubConnectCard.tsx#GitHubConnectCard",
    "agent-session/acpmux/conversation/GitHubConnectRecovery.tsx#GitHubConnectRecovery",
  ],
  styles: () => import("./conversation.css"),
  load: async () =>
    function GitHubConnectGallery({ outcome, grouped }: Props) {
      useEffect(() => {
        setNativeHost(async (method, params) => {
          document.documentElement.dataset.galleryGitHubConnect = JSON.stringify({ method, params });
          if (outcome === "failed") throw new Error("github.unavailable");
          return { opened: true };
        });
        return () => {
          setNativeHost(undefined);
          delete document.documentElement.dataset.galleryGitHubConnect;
        };
      }, [outcome]);
      const item = refusal(outcome === "denied");
      const items = grouped ? [item, { ...item, tool: { ...item.tool!, id: "github-connect-gallery-2" } }] : [item];
      return <McpCallRows items={items} disclosureKey="github-connect-gallery" />;
    },
  variants: {
    available: {
      note: "Opt-in adds one Connect GitHub button below the original refusal. Click records the existing bridge call.",
      props: { outcome: "opened" },
      play: connect(),
    },
    failed: {
      note: "Click Connect GitHub to see a launch failure and retry the same button.",
      props: { outcome: "failed" },
      play: connect(true),
    },
    denied: {
      note: "A policy denial never offers connection, even with the experiment enabled.",
      props: { outcome: "denied" },
    },
    grouped: {
      note: "A collapsed group still offers one connection action; expand to inspect its original failures.",
      props: { outcome: "opened", grouped: true },
      play: connect(),
    },
  },
  experiment: { definition: githubConnect, script: [] },
});
