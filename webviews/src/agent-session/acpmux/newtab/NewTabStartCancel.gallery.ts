// l10n-allow-file: gallery fixtures (sample drafts and folders), not shipped UI.
// A cancelled New Tab start is no failure (#28543 follow-ups, #28815). The pane runs its real
// client on the in-page mock daemon (`transport: "mock"`, mock.ts):
// - not-now-keeps-draft: a start on another machine (devbox) keeps the page until it has started
//   (#28965), so its folder's Trust question (`mockTrustPending`) shows beside the field. Not now
//   ends it as cancelled: the draft stays in the field and no failure notice shows beside it.
// - stale-folder-reply-ready: the send's folder reply arrives after a newer folder request replaced
//   it. That reply uses nothing and ends the send, so the next Return starts the chat.
// - start-refused-shows-notice: beside them, a start acpmux really refused still says why. A local
//   start becomes its chat at once (#28965), so the reason shows in that chat and the prompt is kept
//   there. Only a cancel is quiet.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { noChat } from "../../../gallery/fixtures/acpmux";
import { translate as t } from "../i18n";
import type { MarkdownFieldElement } from "../MarkdownField";

const DRAFT = "Summarize the failing upload tests";
const FOLDER_A = "/Users/you/src/atlas-web";
const FOLDER_B = "/Users/you/src/relay";
/// The tab's own folder, neither of the two picks: a pick of either is a real pick, so its send asks
/// the host about it (`requestFolder`) instead of starting in the inherited folder at once.
const INHERITED = "/Users/you/src/harbor";

const newTab = {
  transport: "mock",
  newSession: true,
  machineName: "This Mac",
  newTab: {
    template: "minimal",
    layout: "b",
    lastAgent: "claude",
    cwd: INHERITED,
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

/// The New Tab field is the Markdown field (#29659): typing goes to its editor, and its draft is its
/// handle's plain text.
const field = (ctx: PlayContext) => ctx.document.querySelector<MarkdownFieldElement>(".nt-field");
const EDITOR = ".nt-field [contenteditable]";
const draft = (ctx: PlayContext) => field(ctx)?.acpmuxMarkdownField?.plainText();
const notice = (ctx: PlayContext) => ctx.document.querySelector('.nt-composer .acpmux-switch-notice[role="alert"]');
const frames = async (ctx: PlayContext, count = 4) => {
  const view = ctx.document.defaultView!;
  for (let i = 0; i < count; i += 1) await new Promise((done) => view.requestAnimationFrame(() => done(undefined)));
};

/// The page's own Return, after the mock's handshake installed the chat's actions.
async function ready(ctx: PlayContext) {
  const view = ctx.document.defaultView as PaneWindow;
  await ctx.waitFor(() => field(ctx)?.acpmuxMarkdownField && ctx.document.querySelector(EDITOR));
  await ctx.waitFor(() => !!view.cmuxAcpmuxActions?.["chat.new"], { capMs: 10_000 });
  return view;
}

/// The live mock daemon's answers, patched for one play (as the unit tests patch its prototype).
type Answer = (method: string, params: Record<string, unknown>) => Promise<unknown>;
async function patchDaemon(
  wrap: (
    method: string,
    params: Record<string, unknown>,
    answer: () => Promise<unknown>,
  ) => Promise<unknown> | undefined,
) {
  const { MockAcpmuxSocket } = await import("../mock");
  const socket = MockAcpmuxSocket.live as unknown as { answer: Answer } | undefined;
  if (!socket) throw new Error("no live mock daemon");
  const answer = socket.answer.bind(socket);
  socket.answer = (method, params) => wrap(method, params, () => answer(method, params)) ?? answer(method, params);
}

/// Picks the devbox machine: the machine chip's main list is This Mac and Cloud, and every machine is
/// in Machines… on its right-click menu (#28999); opening it reads the machines again.
async function pickDevbox(ctx: PlayContext) {
  await patchDaemon((method, _params, answer) =>
    method === "_acpmux/status"
      ? answer().then((status) => ({
          ...(status as Record<string, unknown>),
          peers: [{ name: "devbox", kind: "ssh", connected: true }],
        }))
      : undefined,
  );
  const chip = ctx.document.querySelector<HTMLElement>('.acpmux-location-picker[data-kind="computer"] button')!;
  const box = chip.getBoundingClientRect();
  chip.dispatchEvent(
    new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: box.left + 4, clientY: box.top + 4 }),
  );
  await ctx.waitFor(
    () =>
      [...ctx.document.querySelectorAll('[role="menu"] [role="menuitem"]')].some(
        (node) => node.textContent === t("composer.machinesList"),
      ),
    { capMs: 10_000 },
  );
  await ctx.click({ role: "menuitem", name: t("composer.machinesList") });
  await ctx.waitFor(
    () => [...ctx.document.querySelectorAll(".acpmux-menu-label")].some((node) => node.textContent === "devbox"),
    { capMs: 10_000 },
  );
  const devbox = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-menu-item")].find(
    (node) => node.querySelector(".acpmux-menu-label")?.textContent === "devbox",
  )!;
  devbox.click();
  await frames(ctx);
}

async function notNow(ctx: PlayContext) {
  await ready(ctx);
  // A start on another machine keeps the page until it has started (#28965), so its Trust question
  // and any notice show beside the field.
  await pickDevbox(ctx);
  await ctx.type(DRAFT, { selector: EDITOR });
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
  if (draft(ctx) !== DRAFT) throw new Error(`the draft is gone after Not now (${draft(ctx)})`);
}

async function staleFolder(ctx: PlayContext) {
  const view = await ready(ctx);
  const chip = () => ctx.document.querySelector('[aria-label="Folder"]')?.textContent ?? "";
  const trustAsk = () => ctx.document.querySelector(".acpmux-trust-ask-text")?.textContent ?? "";
  // Choose folder… picks atlas-web (`project.browse`); the tab inherited harbor, so it is a real pick.
  await ctx.click({ selector: '[aria-label="Folder"]' });
  await ctx.click({ role: "option", name: "Choose folder…" });
  await ctx.waitFor(() => chip().includes("atlas-web"), { capMs: 10_000 });
  await ctx.type(DRAFT, { selector: EDITOR });
  // Return asks the host about atlas-web for this send (`workspace.useFolder`, which answers after
  // FOLDER_DELAY_MS); before it answers, a newer folder request (the pane's own pick of relay)
  // replaces it, so the send's late reply is stale.
  await ctx.press("Enter");
  if (ctx.document.querySelector(".cv-user__bubble")) throw new Error("the send started before its folder reply");
  view.cmuxAcpmuxDebug!.pickFolder(FOLDER_B);
  // The newer request's own reply lands last (asked later, same delay) and the pane asks about
  // relay's trust: both replies are in.
  await ctx.waitFor(() => trustAsk().includes("relay"), { capMs: 10_000 });
  await frames(ctx);
  if (notice(ctx)) throw new Error(`a stale folder reply shows a failure notice: ${notice(ctx)!.textContent}`);
  if (ctx.document.querySelector(".cv-user__bubble")) throw new Error("the stale reply started a chat");
  if (draft(ctx) !== DRAFT) throw new Error(`the draft is gone after a stale folder reply (${draft(ctx)})`);
  // Not stuck asking: the next Return starts the chat.
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector(".cv-user__bubble"), { capMs: 10_000 });
}

/// The prompt is still on the page: its queued row in the chat, or the chat's composer.
const kept = (ctx: PlayContext) =>
  !!ctx.document.body.textContent?.includes(DRAFT) ||
  [...ctx.document.querySelectorAll("textarea")].some((node) => node.value.includes(DRAFT));

/// A local start acpmux refuses (`session/new` fails with its reason): the page becomes the chat at
/// once (#28965), which says why it did not start, and the prompt is kept there.
async function refused(ctx: PlayContext) {
  await ready(ctx);
  await patchDaemon((method) => (method === "session/new" ? Promise.reject(new Error(REFUSAL)) : undefined));
  await ctx.type(DRAFT, { selector: EDITOR });
  await ctx.press("Enter");
  await ctx.waitFor(() => !field(ctx), { capMs: 10_000 });
  await ctx.waitFor(() => ctx.document.body.textContent?.includes(REFUSAL), { capMs: 10_000 });
  await frames(ctx);
  if (!kept(ctx)) throw new Error("the refused prompt is gone");
}
const REFUSAL = "acpmux refused session/new: agent unavailable";

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
      note: "A start on devbox, then Not now on the folder's Trust question: the draft stays in the field and no failure notice shows (#28815).",
      ready: newTab,
      mockTrustPending: true,
      checks: {
        layoutShiftMax: {
          value: 0.2,
          reason:
            "A start on another machine holds the page (#28965): Return adds its Starting line and the Trust question above the composer, and Not now swaps that for the Undo line; the composer moves with them by design (measured 0.10-0.14 on Linux Chromium).",
        },
      },
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
    "start-refused-shows-notice": {
      note: "Beside the cancels: a local start acpmux refused becomes its chat, which says why and keeps the prompt (#28815).",
      ready: newTab,
      snapshot: noChat([], { listedSessions: true }),
      checks: {
        longFrameFailMs: {
          value: 120,
          reason:
            "Return replaces the New Tab page with the chat's at once (#28965): that one frame mounts the chat view (measured 80-87 ms on Linux Chromium); the rest of the play stays under the default.",
        },
      },
      play: refused,
    },
  },
});
