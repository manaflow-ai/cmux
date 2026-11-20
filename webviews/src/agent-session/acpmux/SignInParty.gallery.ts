// l10n-allow-file: gallery-only auth fixtures, never production auth policy.
// User, Nov 19, an OpenCode chat on DeepSeek V4.1 Flash: "bad error message, hard to tell if cmux is
// signed out or the model provider is signed out". The composer's sign-in notice names whose
// credential refused the chat, and its model chip says the one fix (sessionAuth.ts).
import { agentPaneEntry } from "../../gallery/format";
import { noChat } from "../../gallery/fixtures/acpmux";
import type { Play } from "../../gallery/play";

const EVIDENCE_AT = 1_795_086_005_790; // The user's failed turn, Nov 19 2026 03:00 PST.
const HARNESSES = [
  {
    id: "opencode",
    name: "OpenCode",
    models: [{ id: "opencode-go/deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash", efforts: ["low", "high"] }],
  },
  { id: "claude", name: "Claude Code", models: [{ id: "claude-opus-5-5", name: "Opus 5.5" }] },
];
const newTab = (lastAgent: string) => ({
  transport: "mock" as const,
  newSession: true,
  newTab: {
    layout: "b",
    kind: "agent",
    cwd: "/Users/you/src/cmux",
    home: "/Users/you",
    lastAgent,
    template: "default",
  },
});
const waitForNotice: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".nt-screen .acpmux-model"));
  await ctx.waitFor(() => ctx.document.querySelector(".nt-screen .acpmux-composer-remote-note[role=alert]"));
};

export default agentPaneEntry({
  id: "agent-pane.sign-in-party",
  title: "Sign-in notice names who is signed out",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 420, normal: 760, wide: 900 },
  covers: ["agent-session/acpmux/sessionAuth.ts#authText", "agent-session/acpmux/sessionAuth.ts#authChipText"],
  variants: {
    "api-key-expired": {
      note: "The user's case: OpenCode Go expired its API key. The notice names the provider's key, and the chip says Replace key.",
      ready: newTab("opencode"),
      snapshot: noChat(),
      mockHarnesses: HARNESSES,
      mockHarnessHealth: { opencode: { auth: "unknown" } },
      mockSessionAuth: {
        state: "expired",
        source: "turn",
        evidenceAt: EVIDENCE_AT,
        harness: "opencode",
        host: null,
        routeId: null,
        fromSessionId: null,
        detail:
          "its last turn failed: Internal error: This API key has expired. Create a new API key in OpenCode Console and replace it in your client or secret store.",
        credential: "apiKey",
        provider: "opencode-go",
        login: { kind: "terminal", command: "opencode auth login" },
      },
      play: waitForNotice,
    },
    "login-expired": {
      note: "The agent's own sign-in expired: the notice names the agent, and the chip signs in to it.",
      ready: newTab("claude"),
      snapshot: noChat(),
      mockHarnesses: HARNESSES,
      mockHarnessHealth: { claude: { auth: "unknown" } },
      mockSessionAuth: {
        state: "expired",
        source: "turn",
        evidenceAt: EVIDENCE_AT,
        harness: "claude",
        host: null,
        routeId: null,
        fromSessionId: null,
        detail: "its last turn failed: API Error: 401 OAuth token has expired.",
        credential: "login",
        login: { kind: "terminal", command: "claude auth login" },
      },
      play: waitForNotice,
    },
    "cmux-signed-out": {
      note: "The cmux model router refused the chat: the person's cmux account is signed out, not the agent.",
      ready: newTab("opencode"),
      snapshot: noChat(),
      mockHarnesses: HARNESSES,
      mockHarnessHealth: { opencode: { auth: "unknown" } },
      mockSessionAuth: {
        state: "routeAuthNeeded",
        source: "routeProbe",
        evidenceAt: EVIDENCE_AT,
        harness: "opencode",
        host: null,
        routeId: null,
        fromSessionId: null,
        detail: "route cmux answered: HTTP 401",
        credential: "cmux",
        login: { kind: "route", routeId: "cmux" },
      },
      play: waitForNotice,
    },
    "route-signed-out": {
      note: "An account route the person added needs a new sign-in: the notice names that account.",
      ready: newTab("claude"),
      snapshot: noChat(),
      mockHarnesses: HARNESSES,
      mockHarnessHealth: { claude: { auth: "unknown" } },
      mockSessionAuth: {
        state: "routeAuthNeeded",
        source: "routeProbe",
        evidenceAt: EVIDENCE_AT,
        harness: "claude",
        host: null,
        routeId: null,
        fromSessionId: null,
        detail: "route team-route answered: HTTP 401",
        login: { kind: "route", routeId: "team-route" },
      },
      play: waitForNotice,
    },
  },
});
