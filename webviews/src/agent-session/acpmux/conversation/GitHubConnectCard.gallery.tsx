// l10n-allow-file: gallery fixtures (sample replies and reasons), not shipped UI.
// "A connect is one inline card, one tap" (cmuxterm-hq docs/design/remote-integrations.md; Leo,
// 2026-11-10: "Just as few hurdles to jump through as possible"). A Cloud chat's GitHub call found no
// GitHub connection for this chat: one card under the turn, one Connect GitHub. The tap opens
// GitHub's page (or nothing, when an installation already covers the repository), and the chat goes
// on by itself once the person is back. The `walk-*` variants are live: the tap-count walk
// (test/github-connect-taps-browser.test.ts) taps them and reads `window.__githubConnectWalk`.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { GitHubConnectNeed, GitHubConnectPhase } from "./githubConnect";

type Props = {
  need: GitHubConnectNeed;
  /// The card's phase as drawn; the live walks start idle.
  phase?: GitHubConnectPhase;
  /// A pane that can run the app's actions (off: View Only, a read-only pane).
  offer?: boolean;
  /// A live walk: `fresh` (GitHub's page opens; the person installs there), `reuse` (an installation
  /// covers the repository: GitHub's authorize page passes straight back), `refuse` (the app did not run it).
  walk?: "fresh" | "reuse" | "refuse";
};

const need = (reason: GitHubConnectNeed["reason"], repo: string | undefined = "acme/web"): GitHubConnectNeed => ({
  reason,
  ...(repo && { repo }),
  callId: "call-push",
});

type Walk = { asked: (string | undefined)[]; opened: string[]; sent: string[] };
declare global {
  // eslint-disable-next-line no-var
  var __githubConnectWalk: Walk | undefined;
}

let rows = 0;

export default componentEntry<Props>({
  id: "agent-pane.github-connect-card",
  title: "Connect GitHub card",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 390, normal: 560, wide: 760 },
  covers: [
    "agent-session/acpmux/conversation/githubConnect.ts",
    "agent-session/acpmux/conversation/GitHubConnectCard.tsx",
    "agent-session/acpmux/conversation/TurnRows.tsx#TurnFooter",
  ],
  keywords: ["github", "connect", "integration", "cloud", "not connected", "one tap", "install"],
  load: async () => {
    const [{ TurnFooter }, { TurnActionsContext }, { setCardPhase }, { NativeError }] = await Promise.all([
      import("./TurnRows"),
      import("./turnActions"),
      import("./githubConnect"),
      import("../nativeError"),
    ]);
    return function GalleryGitHubConnectCard({ need, phase, offer = true, walk }: Props) {
      // A fresh row per variant, so one variant's phase never shows in the next.
      const [id] = useState(() => {
        const fresh = `summary-${(rows += 1)}`;
        if (phase) setCardPhase(`${fresh}:${need.callId}`, phase);
        return fresh;
      });
      const record: Walk = (globalThis.__githubConnectWalk ??= { asked: [], opened: [], sent: [] });
      const actions = {
        resume: async () => undefined,
        ...(offer && {
          githubConnect: {
            connect: async (repo: string | undefined) => {
              record.asked.push(repo);
              if (walk === "refuse") {
                const reason = "Sign in to cmux to connect GitHub.";
                throw new NativeError({ code: "unavailable", message: reason, details: { reason } });
              }
              // The host opens what integration.connect answered (GitHubConnections.swift).
              record.opened.push(
                walk === "reuse"
                  ? "https://github.com/login/oauth/authorize"
                  : "https://github.com/apps/cmux/installations/new/permissions",
              );
            },
            continue: async () => void record.sent.push("Continue"),
          },
        }),
      };
      const row = {
        id,
        version: 1,
        at: Date.UTC(2026, 10, 10, 9, 41),
        kind: "turnSummary" as const,
        status: "completed" as const,
        durationMs: 14_000,
        text: "The push failed: GitHub isn't connected for this chat. Connect it and I'll push again.",
        retryable: true,
        githubConnect: need,
      };
      return (
        <div style={{ padding: "16px 16px 0" }}>
          <TurnActionsContext.Provider value={actions}>
            <TurnFooter row={row as never} />
          </TurnActionsContext.Provider>
        </div>
      );
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: {
    "not-connected": {
      note: "A push found no GitHub connection: one line naming the repository, one filled Connect GitHub.",
      props: { need: need("not-connected") },
    },
    "not-connected-no-repo": {
      note: "A call that named no repository: the line alone; Connect asks GitHub without one.",
      props: { need: need("not-connected", undefined) },
    },
    "needs-reauth": {
      note: "The team's connection needs linking again: the same one button.",
      props: { need: need("needs-reauth") },
    },
    "not-covered": {
      note: "The connection leaves the repository out: Connect opens GitHub's page to add it.",
      props: { need: need("not-covered") },
    },
    waiting: {
      note: "After the tap: finish on GitHub; the chat goes on when the person is back. Continue does it by hand.",
      props: { need: need("not-connected"), phase: { kind: "waiting", left: true } },
    },
    continuing: {
      note: "Back from GitHub: the card sent the chat's Continue, once. No button.",
      props: { need: need("not-connected"), phase: { kind: "continuing" } },
    },
    refused: {
      note: "The app did not run Connect: its reason, and the button that tries again.",
      props: {
        need: need("not-connected"),
        phase: { kind: "refused", reason: "Sign in to cmux to connect GitHub." },
      },
    },
    "read-only": {
      note: "View Only or a read-only pane: the line alone, no dead button.",
      props: { need: need("not-connected"), offer: false },
    },
    "walk-fresh": {
      note: "Live: tap Connect; GitHub's install page opens; back in the chat, Continue goes by itself.",
      props: { need: need("not-connected"), walk: "fresh" },
    },
    "walk-reuse": {
      note: "Live: an installation covers the repository; GitHub's authorize page passes straight back.",
      props: { need: need("not-connected"), walk: "reuse" },
    },
    "walk-refuse": {
      note: "Live: the app refuses Connect; the card says why and offers Try again.",
      props: { need: need("not-connected"), walk: "refuse" },
    },
  },
});
