// l10n-allow-file: gallery fixtures (sample replies and reasons), not shipped UI.
// "A connect is one inline card, one tap" (cmuxterm-hq docs/design/remote-integrations.md; Leo,
// 2026-11-10: "Just as few hurdles to jump through as possible"). A Cloud chat's GitHub call found no
// GitHub connection for this chat: one card under the turn, one Connect GitHub. The tap opens
// GitHub's page (or nothing, when an installation already covers the repository), and the chat goes
// on by itself once the person is back. The `walk-*` variants are live: the tap-count walk
// (test/github-connect-taps-browser.test.ts) taps them and reads `window.__githubConnectWalk`.
import type React from "react";
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
  /// The page drawn under the card, dark or light, for the four-state set (idle, connecting,
  /// connected, error) in each.
  scheme?: Scheme;
  /// The settings-ask-card arm a `settings_ask` card is drawn in (component variants pin no experiments).
  askArm?: "needs" | "card" | "rail" | "popover";
};

type Scheme = "dark" | "light";
const SCHEMES: Record<Scheme, React.CSSProperties> = {
  dark: {
    "--agent-text": "#f2f2f2",
    "--agent-muted": "rgba(242, 242, 242, 0.62)",
    "--agent-page-bg": "#18181c",
    colorScheme: "dark",
    background: "#18181c",
  } as React.CSSProperties,
  light: {
    "--agent-text": "#1d1d1f",
    "--agent-muted": "rgba(29, 29, 31, 0.6)",
    "--agent-page-bg": "#ffffff",
    colorScheme: "light",
    background: "#ffffff",
  } as React.CSSProperties,
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

/// An agent's own ask (acpmux `settings_ask`): an org, or a repository, with its one line on why.
const asked = (org = "manaflow-ai", why?: string): GitHubConnectNeed => ({
  reason: "asked",
  org,
  ...(why && { why }),
  callId: "call-ask",
});

/// A cmux connection other than GitHub: a hosted call's lapsed sign-in, or the agent's ask by name.
const service = (name: string, reason: GitHubConnectNeed["reason"] = "needs-reauth", why?: string): GitHubConnectNeed => ({
  reason,
  service: name,
  ...(why && { why }),
  callId: "call-service",
});

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
    return function GalleryGitHubConnectCard({ need, phase, offer = true, walk, scheme, askArm }: Props) {
      if (askArm) globalThis.cmuxExperiments = { ...globalThis.cmuxExperiments, "settings-ask-card": askArm };
      // A fresh row per variant, so one variant's phase never shows in the next.
      const [id] = useState(() => {
        const fresh = `summary-${(rows += 1)}`;
        if (phase) setCardPhase(`${fresh}:${need.callId}`, phase);
        return fresh;
      });
      const record: Walk = (globalThis.__githubConnectWalk ??= {
        asked: [],
        opened: [],
        sent: [],
      });
      const actions = {
        resume: async () => undefined,
        ...(offer && {
          githubConnect: {
            connect: async (repo: string | undefined) => {
              record.asked.push(repo);
              if (walk === "refuse") {
                const reason = "Sign in to cmux to connect GitHub.";
                throw new NativeError({
                  code: "unavailable",
                  userMessage: reason,
                  details: { reason },
                });
              }
              // The host opens what integration.connect answered (GitHubConnections.swift).
              record.opened.push(
                walk === "reuse"
                  ? "https://github.com/login/oauth/authorize"
                  : "https://github.com/apps/cmux/installations/new/permissions",
              );
            },
            // A service card (Linear, Sentry, ...): the host runs `connections.connect` for it.
            connectService: async (service: string) => {
              record.asked.push(service);
              if (walk === "refuse") throw new NativeError({ code: "unavailable", userMessage: `Sign in to cmux to connect ${service}.` });
              record.opened.push(`https://mcp.${service}.app/authorize`);
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
        <div
          style={{
            // The popover arm opens above its chip, as over the composer at a chat's end.
            padding: askArm === "popover" ? "32px 16px 0" : "16px 16px 0",
            ...(scheme ? { ...SCHEMES[scheme], minHeight: "100%" } : {}),
          }}
        >
          <div style={askArm === "popover" ? { marginTop: 56, paddingTop: 32 } : undefined}>
            <TurnActionsContext.Provider value={actions}>
              <TurnFooter row={row as never} />
            </TurnActionsContext.Provider>
          </div>
        </div>
      );
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: {
    // Slice 3 of cmuxterm-hq docs/design/integrations.md: the same card for any other connection.
    "service-needs-auth-dark": {
      note: "A hosted Linear call found its sign-in expired (mcp_server.needs_auth): one line, Connect Linear. Dark page.",
      props: { need: service("linear"), scheme: "dark" },
    },
    "service-needs-auth-light": {
      note: "A hosted Sentry call found its sign-in expired: one line, Connect Sentry. Light page.",
      props: { need: service("sentry"), scheme: "light" },
    },
    "service-asked-needs": {
      note: "The agent asked for Notion by name (settings_ask connection:notion), Needs you arm.",
      props: { need: service("notion", "asked", "The spec lives in Notion; connect it and I'll read it."), askArm: "needs" },
    },
    "service-asked-popover": {
      note: "The agent asked for Linear by name, Popover arm: the chip and its one row.",
      props: { need: service("linear", "asked"), askArm: "popover", scheme: "dark" },
    },
    "service-waiting": {
      note: "After Connect Linear: finish signing in to Linear; the chat goes on when the person is back.",
      props: { need: service("linear"), phase: { kind: "waiting", left: true } },
    },
    "service-refused": {
      note: "The app did not run Connect for the service: its reason, Try again.",
      props: { need: service("cloudflare-docs"), phase: { kind: "refused", reason: "Sign in to cmux to connect Cloudflare Docs." } },
    },
    "service-walk": {
      note: "Live: tap Connect Linear; the sign-in page opens; back in the chat, Continue goes by itself.",
      props: { need: service("linear"), walk: "fresh" },
    },
    // Leo, 2026-11-25: "what about just a simple styled consistently popover for that specific
    // setting? a la something similar to needs you or whatever". The agent's settings_ask card, one
    // per arm of settings-ask-card (default: needs).
    "asked-needs": {
      note: "settings_ask, Needs you arm (default): Needs you header, one row, Connect GitHub at its end.",
      props: { need: asked(), askArm: "needs" },
    },
    "asked-card": {
      note: "settings_ask, Glass card arm: the turn error card's surface, the button under the line.",
      props: { need: asked(), askArm: "card" },
    },
    "asked-rail": {
      note: "settings_ask, Accent rail arm: no surface, a rail beside the line.",
      props: { need: asked(), askArm: "rail" },
    },
    "asked-why-dark": {
      note: "settings_ask with the agent's own line, Needs you arm. Dark page.",
      props: {
        need: asked("manaflow-ai", "Pushing lane/x to manaflow-ai/cmux needs the cmux GitHub app on manaflow-ai."),
        scheme: "dark",
        askArm: "needs",
      },
    },
    "asked-waiting": {
      note: "settings_ask after the tap: finish on GitHub; Continue by hand.",
      props: { need: asked(), phase: { kind: "waiting", left: true }, askArm: "needs" },
    },
    // The popover arm (default off): the Needs you popover's surface over a chip under the turn,
    // holding just the one setting's control.
    "asked-popover": {
      note: "settings_ask, Popover arm: a Needs you popover anchored to the turn's chip, Connect GitHub in its one row.",
      props: { need: asked(), askArm: "popover", scheme: "light" },
    },
    "asked-popover-dark": {
      note: "settings_ask, Popover arm, with the agent's own line. Dark page.",
      props: {
        need: asked("manaflow-ai", "Pushing lane/x to manaflow-ai/cmux needs the cmux GitHub app on manaflow-ai."),
        scheme: "dark",
        askArm: "popover",
      },
    },
    "asked-popover-waiting": {
      note: "settings_ask, Popover arm after the tap: finish on GitHub; Continue by hand.",
      props: {
        need: asked(),
        phase: { kind: "waiting", left: true },
        askArm: "popover",
        scheme: "dark",
      },
    },
    "asked-popover-refused": {
      note: "settings_ask, Popover arm, the app did not run Connect: its reason, Try again.",
      props: {
        need: asked(),
        walk: "refuse",
        phase: {
          kind: "refused",
          reason: "Sign in to cmux to connect GitHub.",
        },
        askArm: "popover",
        scheme: "light",
      },
    },
    "idle-dark": {
      note: "Idle: one line naming the repository, one filled Connect GitHub. Dark page.",
      props: { need: need("not-connected"), scheme: "dark" },
    },
    "idle-light": {
      note: "Idle: one line naming the repository, one filled Connect GitHub. Light page.",
      props: { need: need("not-connected"), scheme: "light" },
    },
    "connecting-dark": {
      note: "Connecting: the tap is in; the button waits while the app opens GitHub's page. Dark page.",
      props: {
        need: need("not-connected"),
        phase: { kind: "opening" },
        scheme: "dark",
      },
    },
    "connecting-light": {
      note: "Connecting: the tap is in; the button waits while the app opens GitHub's page. Light page.",
      props: {
        need: need("not-connected"),
        phase: { kind: "opening" },
        scheme: "light",
      },
    },
    "connected-dark": {
      note: "Connected: back from GitHub, the card sent the chat's Continue once; no button. Dark page.",
      props: {
        need: need("not-connected"),
        phase: { kind: "continuing" },
        scheme: "dark",
      },
    },
    "connected-light": {
      note: "Connected: back from GitHub, the card sent the chat's Continue once; no button. Light page.",
      props: {
        need: need("not-connected"),
        phase: { kind: "continuing" },
        scheme: "light",
      },
    },
    "error-dark": {
      note: "Error: the app did not run Connect; its reason, and the button that tries again. Dark page.",
      props: {
        need: need("not-connected"),
        phase: {
          kind: "refused",
          reason: "Sign in to cmux to connect GitHub.",
        },
        scheme: "dark",
      },
    },
    "error-light": {
      note: "Error: the app did not run Connect; its reason, and the button that tries again. Light page.",
      props: {
        need: need("not-connected"),
        phase: {
          kind: "refused",
          reason: "Sign in to cmux to connect GitHub.",
        },
        scheme: "light",
      },
    },
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
      props: {
        need: need("not-connected"),
        phase: { kind: "waiting", left: true },
      },
    },
    continuing: {
      note: "Back from GitHub: the card sent the chat's Continue, once. No button.",
      props: { need: need("not-connected"), phase: { kind: "continuing" } },
    },
    refused: {
      note: "The app did not run Connect: its reason, and the button that tries again.",
      props: {
        need: need("not-connected"),
        phase: {
          kind: "refused",
          reason: "Sign in to cmux to connect GitHub.",
        },
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
