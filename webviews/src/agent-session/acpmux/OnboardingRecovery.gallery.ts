// l10n-allow-file: synthetic gallery evidence, not product copy or authentication policy.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { noChat } from "../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../gallery/play";
import { translate } from "./i18n";
import { BUNDLED_MODEL_CATALOG } from "./modelCatalogData";
import { INSTALL_COMMANDS } from "./harnesses/harnessRows";

type HarnessState = "none" | "signed-out" | "signed-in";
type Call = { method: string; params?: Record<string, unknown> };
const PROJECT = "/Users/you/onboarding-fixture";
const GUIDE = BUNDLED_MODEL_CATALOG.harnesses.find((harness) => harness.id === "claude")!.docsUrl!;
const PROMPT = "Describe this synthetic onboarding fixture";
const calls = (ctx: PlayContext): Call[] =>
  (ctx.document.defaultView as Window & { cmuxGalleryLog?: Call[] })?.cmuxGalleryLog ?? [];

function record(ctx: PlayContext, harness: HarnessState, action: string, observed: unknown, labs = false) {
  // Retained by the capture adapter's actual DOM, never presented as an account/plan input.
  ctx.document.body.dataset.onboardingRecovery = JSON.stringify({
    entry: "new-tab",
    labs,
    harness: { mode: "synthetic", value: harness },
    machine: "local mock daemon; cloud actions stop at the native handoff",
    providerAccount: "unobserved: this surface has no provider billing input",
    cmuxIdentity: "unobserved: native cloud action owns account gating",
    cmuxPlan: "unobserved: native cloud action owns sizing and entitlement",
    action,
    observed,
    calls: calls(ctx),
  });
}

async function page(ctx: PlayContext, harness: HarnessState) {
  await ctx.waitFor(() => ctx.document.querySelector(".nt-screen .nt-field"));
  if (harness === "none") await ctx.waitFor(() => ctx.document.querySelector(".acpmux-add-harness"));
  else
    await ctx.waitFor(() =>
      calls(ctx).some((call) => {
        const rows = call.params?.harnesses as { id: string; auth: string }[] | undefined;
        return (
          call.method === "acpmux health resolved" &&
          rows?.some((row) => row.id === "claude" && row.auth === (harness === "signed-out" ? "signedOut" : "signedIn"))
        );
      }),
    );
  // The first settled step retains the actual entry page before opening a recovery surface.
  await ctx.focus({ selector: ".nt-field" });
}

function fixture(harness: HarnessState): AgentPaneVariant {
  const signedOut = harness === "signed-out";
  return {
    ready: {
      transport: "mock",
      newSession: true,
      newTab: {
        layout: "b",
        kind: "agent",
        cwd: PROJECT,
        home: "/Users/you",
        lastAgent: "claude",
        template: "minimal",
      },
    },
    snapshot: noChat(),
    ...(harness === "none" ? { mockHarnesses: [] } : {}),
    mockHarnessHealth: {
      claude: { auth: harness === "none" ? "unknown" : signedOut ? "signedOut" : "signedIn", login: "claude login" },
    },
    mockSessionAuth: {
      state: harness === "none" ? "unknown" : signedOut ? "signedOut" : "ready",
      source: harness === "none" ? "none" : "authCheck",
      evidenceAt: harness === "none" ? null : 1_793_184_000_000,
      harness: "claude",
      host: null,
      routeId: null,
      fromSessionId: null,
      ...(signedOut ? { login: { kind: "terminal" as const, command: "claude login" } } : {}),
    },
  };
}

function cloud(harness: HarnessState, storefront: boolean): AgentPaneVariant {
  const id = storefront ? "palette.openCloudPane" : "newCloudMachine";
  return {
    ...fixture(harness),
    note: `Synthetic ${harness}, Labs explicitly enabled: click the real cloud action; verify ${id}, not provisioning or entitlement.`,
    play: async (ctx) => {
      ctx.document.defaultView?.cmuxAcpmuxBridge?.applyPreview?.(true);
      await page(ctx, harness);
      await ctx.click({
        selector: '.nt-location .acpmux-location-picker[data-kind="computer"] button',
      });
      const label = translate(storefront ? "composer.openCloud" : "composer.newCloudMachine");
      await ctx.click({ text: label });
      await ctx.waitFor(() => calls(ctx).some((call) => call.method === "action.run" && call.params?.id === id));
      if (calls(ctx).some((call) => call.method === "acpmux session/prompt"))
        throw new Error("Cloud setup unexpectedly sent an agent prompt");
      record(ctx, harness, `cloud action ${id}`, { method: "action.run", id }, true);
    },
  };
}

export default agentPaneEntry({
  id: "agent-pane.onboarding-recovery",
  title: "New Tab: executed onboarding handoffs",
  area: "Agent pane",
  height: 650,
  widths: { normal: 900 },
  covers: ["agent-session/acpmux/App.tsx", "agent-session/acpmux/harnesses/HarnessesScreen.tsx"],
  variants: {
    "none-install-failure": {
      ...fixture("none"),
      note: "Add harness opens the real setup page; a synthetic failed installer offers its setup guide. No command executes.",
      native: {
        "shell.run": { id: "synthetic-installer" },
        "shell.read": { output: "Synthetic installer failed", next: 1, exit: { code: 1 } },
      },
      play: async (ctx) => {
        await page(ctx, "none");
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-add-harness"));
        await ctx.click({ selector: ".acpmux-add-harness" });
        const row = '[data-harness-row="claude"]';
        await ctx.waitFor(() => ctx.document.querySelector(`${row}[data-harness-status="notInstalled"]`));
        await ctx.click({ selector: `${row} .acpmux-harness-action` });
        await ctx.waitFor(() => ctx.document.querySelector(`${row}[data-harness-status="failed"]`));
        if (!ctx.document.querySelector(row)?.textContent?.includes("Synthetic installer failed"))
          throw new Error("Installer failure advice was lost");
        await ctx.click({ selector: `${row} .acpmux-harness-action` });
        await ctx.waitFor(() =>
          calls(ctx).some(
            (call) => call.method === "tab.open" && call.params?.kind === "browser" && call.params?.text === GUIDE,
          ),
        );
        if (!calls(ctx).some((call) => call.method === "shell.run" && call.params?.command === INSTALL_COMMANDS.claude))
          throw new Error("The intended Claude installer was not requested");
        record(ctx, "none", "Add harness → failed install → setup guide", ctx.document.querySelector(row)?.textContent);
      },
    },
    "signed-out-login": {
      ...fixture("signed-out"),
      note: "The real New Tab Log In action requests a terminal with claude login. No provider sign-in occurs.",
      play: async (ctx) => {
        await page(ctx, "signed-out");
        await ctx.waitFor(() => calls(ctx).some((call) => call.method === "acpmux health resolved"));
        await ctx.click({ selector: ".nt-screen .acpmux-model .acpmux-picker-button" });
        await ctx.click({ role: "menuitem", name: translate("harness.logIn") });
        await ctx.waitFor(() =>
          calls(ctx).some(
            (call) =>
              call.method === "tab.open" && call.params?.kind === "terminal" && call.params?.text === "claude login",
          ),
        );
        if (calls(ctx).some((call) => call.method === "acpmux session/prompt"))
          throw new Error("Login unexpectedly sent a prompt");
        record(ctx, "signed-out", "Log In", {
          method: "tab.open",
          kind: "terminal",
          text: "claude login",
        });
      },
    },
    "signed-in-send": {
      ...fixture("signed-in"),
      note: "The real New Tab submits to the isolated mock daemon; its reply is synthetic, not provider success.",
      play: async (ctx) => {
        await page(ctx, "signed-in");
        await ctx.type(PROMPT, { selector: ".nt-field" });
        await ctx.press("Enter");
        await ctx.waitFor(() => {
          const state = ctx.document.defaultView?.cmuxAcpmuxDebug?.chatState();
          return (
            state?.harness === "claude" &&
            calls(ctx).some((call) => {
              const prompt = call.params?.prompt as { type: string; text?: string }[] | undefined;
              return (
                call.method === "acpmux session/prompt" &&
                call.params?.sessionId === state.sessionId &&
                prompt?.some((block) => block.type === "text" && block.text === PROMPT)
              );
            })
          );
        });
        record(
          ctx,
          "signed-in",
          "submit New Tab prompt",
          calls(ctx).filter((call) => call.method === "acpmux session/prompt"),
        );
      },
    },
    "signed-in-local-terminal": {
      ...fixture("signed-in"),
      note: "New Tab shell entry requests the local terminal independently of provider billing. The host is stubbed.",
      play: async (ctx) => {
        await page(ctx, "signed-in");
        await ctx.type("!pwd", { selector: ".nt-field" });
        await ctx.press("Enter");
        await ctx.waitFor(() =>
          calls(ctx).some(
            (call) => call.method === "tab.open" && call.params?.kind === "terminal" && call.params?.text === "pwd",
          ),
        );
        record(ctx, "signed-in", "local terminal", {
          method: "tab.open",
          kind: "terminal",
          text: "pwd",
        });
      },
    },
    "none-cloud-create": cloud("none", false),
    "signed-out-cloud-create": cloud("signed-out", false),
    "signed-in-cloud-create": cloud("signed-in", false),
    "none-cloud-page": cloud("none", true),
    "signed-out-cloud-page": cloud("signed-out", true),
    "signed-in-cloud-page": cloud("signed-in", true),
  },
});
