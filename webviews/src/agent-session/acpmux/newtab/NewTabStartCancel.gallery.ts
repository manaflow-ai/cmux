// l10n-allow-file: gallery fixtures (sample drafts and folders), not shipped UI.
// A cancelled New Tab start is no failure (#28543 follow-ups, #28815). The pane runs its real
// client on the in-page mock daemon (`transport: "mock"`, mock.ts):
// - not-now-keeps-draft: the start waits on the folder's Trust question (`mockTrustPending`); Not now
//   ends it as cancelled. The draft stays in the field and no failure notice shows beside it.
// - stale-folder-reply-ready: the send's folder reply arrives after a newer folder request replaced
//   it. That reply uses nothing and ends the send, so the next Return starts the chat.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { noChat } from "../../../gallery/fixtures/acpmux";

const DRAFT = "Summarize the failing upload tests";
const FOLDER_A = "/Users/you/src/atlas-web";
const FOLDER_B = "/Users/you/src/relay";

const newTab = {
  transport: "mock",
  newSession: true,
  machineName: "This Mac",
  newTab: {
    template: "minimal",
    layout: "b",
    lastAgent: "claude",
    cwd: FOLDER_A,
    home: "/Users/you",
  },
};

type PaneWindow = Window & {
  cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => unknown>;
  cmuxAcpmuxDebug?: { pickFolder(cwd: string): unknown };
};
/// How long the host takes to answer `workspace.useFolder`: long enough for a newer request to
/// replace the send's before its reply lands.
const FOLDER_DELAY_MS = 1200;

const field = (ctx: PlayContext) => ctx.document.querySelector<HTMLTextAreaElement>(".nt-field");
const notice = (ctx: PlayContext) => ctx.document.querySelector('.nt-composer .acpmux-switch-notice[role="alert"]');
const frames = async (ctx: PlayContext, count = 4) => {
  const view = ctx.document.defaultView!;
  for (let i = 0; i < count; i += 1) await new Promise((done) => view.requestAnimationFrame(() => done(undefined)));
};

/// The page's own Return, after the mock's handshake installed the chat's actions.
async function ready(ctx: PlayContext) {
  const view = ctx.document.defaultView as PaneWindow;
  await ctx.waitFor(() => field(ctx));
  await ctx.waitFor(() => !!view.cmuxAcpmuxActions?.["chat.new"], { capMs: 10_000 });
  return view;
}

async function notNow(ctx: PlayContext) {
  const view = await ready(ctx);
  // The direct no-project route (direct.ts create), whose start waits through the Trust answer.
  const actions = view.cmuxAcpmuxActions!;
  const start = actions["chat.new"]!;
  actions["chat.new"] = (params) => start({ ...params, harness: "", noProject: true });
  await ctx.type(DRAFT, { selector: ".nt-field" });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-trust-ask-primary"), {
    capMs: 10_000,
  });
  await ctx.click({ role: "button", name: "Not now" });
  await ctx.waitFor(
    () => [...ctx.document.querySelectorAll(".acpmux-trust-ask-action")].some((node) => node.textContent === "Undo"),
    { capMs: 10_000 },
  );
  await frames(ctx);
  if (notice(ctx)) throw new Error(`a cancelled start shows a failure notice: ${notice(ctx)!.textContent}`);
  if (field(ctx)?.value !== DRAFT) throw new Error(`the draft is gone after Not now (${field(ctx)?.value})`);
}

async function staleFolder(ctx: PlayContext) {
  const view = await ready(ctx);
  const chip = () => ctx.document.querySelector('[aria-label="Folder"]')?.textContent ?? "";
  // Choose folder… takes atlas-web through the host (`project.browse`, then `workspace.useFolder`,
  // which answers after FOLDER_DELAY_MS).
  await ctx.click({ selector: '[aria-label="Folder"]' });
  await ctx.click({ role: "option", name: "Choose folder…" });
  await ctx.waitFor(() => chip().includes("atlas-web"), { capMs: 10_000 });
  await ctx.type(DRAFT, { selector: ".nt-field" });
  // Return asks the host about atlas-web again for this send; before it answers, a newer folder
  // request (the pane's own pick of relay) replaces it. The send's late reply is stale.
  await ctx.press("Enter");
  view.cmuxAcpmuxDebug!.pickFolder(FOLDER_B);
  await ctx.waitFor(() => chip().includes("relay"), { capMs: 10_000 });
  await frames(ctx);
  if (notice(ctx)) throw new Error(`a stale folder reply shows a failure notice: ${notice(ctx)!.textContent}`);
  if (ctx.document.querySelector(".cv-user__bubble")) throw new Error("the stale reply started a chat");
  // Not stuck asking: the next Return starts the chat (in relay).
  if (!field(ctx)?.value) await ctx.type(DRAFT, { selector: ".nt-field" });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector(".cv-user__bubble"), { capMs: 10_000 });
}

export default agentPaneEntry({
  id: "agent-pane.new-tab-start-cancel",
  title: "New Tab: cancelled start",
  area: "New Tab",
  height: 520,
  widths: { narrow: 420, normal: 640, wide: 860 },
  covers: ["agent-session/acpmux/newtab/NewTabScreen.tsx#NewTabScreen"],
  checks: {
    layoutShiftMax: {
      value: 0.1,
      reason:
        "The Trust question opens above the composer on Return and its Undo line replaces it on Not now; the composer below moves with it by design.",
    },
  },
  variants: {
    "not-now-keeps-draft": {
      note: "Return, then Not now on the folder's Trust question: the draft stays in the field and no failure notice shows (#28815).",
      ready: newTab,
      mockTrustPending: true,
      snapshot: noChat([], { listedSessions: true }),
      play: notNow,
    },
    "stale-folder-reply-ready": {
      note: "The send's folder reply lands after a newer folder request: it uses nothing and ends the send, so the next Return starts the chat (#28815).",
      ready: newTab,
      native: { "project.browse": { cwd: FOLDER_A }, "workspace.useFolder": { status: "ok" } },
      nativeDelayMs: { "workspace.useFolder": FOLDER_DELAY_MS },
      snapshot: noChat([], { listedSessions: true }),
      play: staleFolder,
    },
  },
});
