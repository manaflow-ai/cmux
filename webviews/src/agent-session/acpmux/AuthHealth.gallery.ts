// l10n-allow-file: gallery-only auth fixtures, never production auth policy.
import { agentPaneEntry } from "../../gallery/format";
import { noChat } from "../../gallery/fixtures/acpmux";
import type { Play } from "../../gallery/play";
import { translate } from "./i18n";

const EVIDENCE_AT = 1_793_184_000_000; // Fixed, plausible epoch-ms gallery evidence.

const waitForPage: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".nt-screen .acpmux-model"));
  await ctx.waitFor(() =>
    (ctx.document.defaultView as Window & { cmuxGalleryLog?: { method: string }[] })?.cmuxGalleryLog?.some(
      (call) => call.method === "acpmux health resolved",
    ),
  );
};
const waitForPicker: Play = async (ctx) => {
  await waitForPage(ctx);
  await ctx.click({ selector: ".nt-screen .acpmux-model .acpmux-picker-button" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-quick-menu"));
};
const waitForSignOut: Play = async (ctx) => {
  await waitForPicker(ctx);
  await ctx.waitFor(() =>
    [...ctx.document.querySelectorAll(".acpmux-quick-menu .acpmux-quick-item")].some(
      (item) => item.textContent?.trim() === translate("harness.logIn"),
    ),
  );
};

export default agentPaneEntry({
  id: "agent-pane.auth-health",
  title: "New Tab: mock auth evidence",
  area: "Agent pane",
  height: 600,
  widths: { narrow: 420, normal: 760, wide: 900 },
  covers: ["agent-session/acpmux/mock.ts#MockAcpmuxSocket"],
  variants: {
    "signed-in": {
      note: "New Tab's Claude target has explicit signed-in health and ready target auth.",
      ready: {
        transport: "mock",
        newSession: true,
        newTab: {
          layout: "b",
          kind: "agent",
          cwd: "/Users/you/src/cmux",
          home: "/Users/you",
          lastAgent: "claude",
          template: "default",
        },
      },
      snapshot: noChat(),
      mockHarnessHealth: { claude: { auth: "signedIn" } },
      mockSessionAuth: {
        state: "ready",
        source: "authCheck",
        evidenceAt: EVIDENCE_AT,
        harness: "claude",
        host: null,
        routeId: null,
        fromSessionId: null,
      },
      play: waitForPicker,
    },
    "signed-out": {
      note: "The native harness.health fixture reaches the mock daemon; New Tab's model menu offers Log In.",
      ready: {
        transport: "mock",
        newSession: true,
        newTab: {
          layout: "b",
          kind: "agent",
          cwd: "/Users/you/src/cmux",
          home: "/Users/you",
          lastAgent: "claude",
          template: "default",
        },
      },
      snapshot: noChat(),
      native: { "harness.health": { health: { id: "claude", auth: "signedOut", login: "claude login" } } },
      mockSessionAuth: {
        state: "signedOut",
        source: "authCheck",
        evidenceAt: EVIDENCE_AT + 1,
        harness: "claude",
        host: null,
        routeId: null,
        fromSessionId: null,
        login: { kind: "terminal", command: "claude login" },
      },
      play: waitForSignOut,
    },
    expired: {
      note: "Target-scoped expiration is distinct from harness health. Current base has no session-auth UI; the New Tab visual stays neutral until #26643 lands.",
      ready: {
        transport: "mock",
        newSession: true,
        newTab: {
          layout: "b",
          kind: "agent",
          cwd: "/Users/you/src/cmux",
          home: "/Users/you",
          lastAgent: "claude",
          template: "default",
        },
      },
      snapshot: noChat(),
      mockHarnessHealth: { claude: { auth: "unknown" } },
      mockSessionAuth: {
        state: "expired",
        source: "authCheck",
        evidenceAt: EVIDENCE_AT + 2,
        harness: "claude",
        host: null,
        routeId: null,
        fromSessionId: null,
        detail: "The selected login expired",
        login: { kind: "terminal", command: "claude login" },
      },
      play: waitForPicker,
    },
    unknown: {
      note: "No credential evidence for New Tab's target: no guessed sign-out and no blocking UI.",
      ready: {
        transport: "mock",
        newSession: true,
        newTab: {
          layout: "b",
          kind: "agent",
          cwd: "/Users/you/src/cmux",
          home: "/Users/you",
          lastAgent: "claude",
          template: "default",
        },
      },
      snapshot: noChat(),
      mockHarnessHealth: { claude: { auth: "unknown" } },
      mockSessionAuth: {
        state: "unknown",
        source: "none",
        evidenceAt: null,
        harness: "claude",
        host: null,
        routeId: null,
        fromSessionId: null,
      },
      play: waitForPicker,
    },
  },
});
