// l10n-allow-file: gallery fixtures (sample conversations), not shipped UI.
// The channels Home (cmux-page://cmux.home-channels/): the same page main.tsx mounts, over the
// in-memory provider's sample channels and direct messages, so the rail, timeline, message rows,
// composer, thread panel and the Cmd-K switcher show without the app.
import { useState, type CSSProperties } from "react";
import { componentEntry } from "../../gallery/format";
import { UiProvider } from "../../ui/UiProvider";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { HomeChannelsPage } from "./HomeChannelsPage";
import { BridgePageClient } from "../shared/pageClient";
import { CURRENT_SELECTION_OP, type HomeSelection } from "./hostSelection";
import { ana, MockHomeProvider, sam, type MockDraft, type MockRuns } from "./mockProvider";
import type { Pane } from "./panes";
import type { HomeRoute } from "./routes";
import { HomeChannelsStore } from "./store";
import { CHIEF_HARNESSES, DEFAULT_CHIEF_TOOLS } from "./types";

type Props = {
  /** The conversation the page opens with; default: the page's own first choice. */
  select?: string;
  /** A thread root message to open in the thread sheet. */
  thread?: string;
  /** No host: the page shows its offline state. */
  offline?: boolean;
  /** The Chief's running reply in the Chief DM. */
  draft?: MockDraft;
  /** Adds #incident, a thread with more replies than one page. */
  longThread?: boolean;
  /** Sample agent runs in the Chief DM. */
  runs?: MockRuns;
  /** The owner refuses pins and marks. */
  refuseInbox?: boolean;
  /** Adds #media: images, a video with its poster and a PDF. */
  media?: boolean;
  /** Adds #launch, a channel two teammates share; Ana types in it. */
  teammates?: boolean;
  /** The theme's terminal selection color, as the app sets `--cmux-text-selection`. */
  terminalSelection?: string;
  /** A sheet route (routes.ts) to open. */
  route?: HomeRoute;
  /** The host relays the person's click for a Chief's grant and delete (the app). */
  hostGrants?: boolean;
  /** Adds a second Chief (one that can be archived). */
  extraChief?: boolean;
  /** The page's own width (px): below 720 it shows one pane (panes.ts), `pane`. */
  width?: number;
  pane?: Pane;
  /** The app's page bridge (a real BridgePageClient over GalleryBridgeHost): the host calls the
   * page's ops the way PageRouter.callPage does. */
  hostBridge?: boolean;
  /** A cmux link the page opens (as the Messages view's switch does through the hash). */
  link?: string;
};

/** The app's side of the page bridge, in the gallery frame. The page's own calls and subscribes
 * answer `cmux.protocol.unknown_op` (this host serves no ops); the host's calls go in through the
 * client's receive (what `window.__cmuxPageReceive` calls in the app) and resolve with the reply
 * envelope the page posts back. */
class GalleryBridgeHost {
  private nextCall = 1_000_000;
  private readonly waiting = new Map<number, (reply: unknown) => void>();
  readonly client: BridgePageClient;

  constructor() {
    // A private target: the frame's own `__cmuxPageReceive` global stays untouched.
    this.client = new BridgePageClient({ postMessage: async (body) => this.post(body) }, {});
  }

  private post(body: unknown): unknown {
    const envelope = body as { t?: string; id?: number; op?: string; stream?: string };
    if ((envelope.t === "ok" || envelope.t === "err") && typeof envelope.id === "number") {
      this.waiting.get(envelope.id)?.(envelope);
      this.waiting.delete(envelope.id);
      return null;
    }
    if (envelope.t === "call" || envelope.t === "sub")
      return {
        t: "err",
        id: envelope.id,
        code: "cmux.protocol.unknown_op",
        message: envelope.op ?? envelope.stream ?? "",
      };
    return null;
  }

  /** PageRouter.callPage: one `call` envelope to the page; resolves with its `ok`/`err` reply. */
  callPage(op: string, params: unknown = {}): Promise<unknown> {
    const id = this.nextCall++;
    return new Promise((resolve) => {
      this.waiting.set(id, resolve);
      this.client.receive({ t: "call", id, op, params });
    });
  }
}

type GalleryHostWindow = Window & { cmuxGalleryHost?: GalleryBridgeHost };

function HomeChannelsGallery({
  select,
  thread,
  offline = false,
  draft,
  longThread = false,
  runs = "none",
  refuseInbox = false,
  media = false,
  teammates = false,
  terminalSelection,
  route,
  hostGrants = false,
  extraChief = false,
  width,
  pane,
  hostBridge = false,
  link,
}: Props) {
  const [store] = useState(() => {
    const provider = offline ? null : new MockHomeProvider(draft, longThread, runs, refuseInbox, media, teammates);
    if (provider) provider.hostGrants = hostGrants;
    if (provider && extraChief) provider.addChief("Release Chief");
    let host: BridgePageClient | MockHomeProvider | null = hostGrants ? provider : null;
    if (hostBridge) {
      const bridge = new GalleryBridgeHost();
      (window as GalleryHostWindow).cmuxGalleryHost = bridge;
      host = bridge.client;
    }
    const created = new HomeChannelsStore(provider, undefined, host);
    // The gallery owns its window hash: the page never writes it here.
    created.routed = false;
    if (route) created.sheets.show(route);
    if (link) void created.start().then(() => created.openLink(link));
    if (select)
      void created.select(select).then(() => {
        if (thread) void created.openThread(thread);
        if (teammates) {
          provider?.viewing("c-launch", [sam.id, ana.id]);
          provider?.typing("c-launch", ana.id, true);
        }
      });
    return created;
  });
  const [strings] = useState(() => createStrings(table));
  const [root, setRoot] = useState<HTMLDivElement | null>(null);
  return (
    <div
      ref={setRoot}
      style={{ height: "100%", width: width ?? "100%", "--cmux-text-selection": terminalSelection } as CSSProperties}
    >
      {root ? (
        <UiProvider container={root}>
          <HomeChannelsPage store={store} strings={strings} pane={width ? pane : undefined} />
        </UiProvider>
      ) : null}
    </div>
  );
}

// The first Cmd-K mounts ui/Dialog (focus trap, the page behind made inert) and the palette; on
// the CPU-only VM the first case of a run has one ~50-58 ms frame, warm repeats stay under 33 ms.
const openFrame = {
  value: 66,
  reason:
    "Cold first open of the shared Dialog and the palette: one ~55 ms frame on the CPU-only VM, warm runs pass at 33 ms.",
};
const switcherField = ".lg-palette input";
// Open, with the keyboard focus in its field (ui/Dialog moves focus to the first field).
const switcherOpen = (ctx: { document: Document }) => {
  const field = ctx.document.querySelector(switcherField);
  return field !== null && ctx.document.activeElement === field;
};

// The host's `home.currentSelection` (hostSelection.ts), called over the page bridge the way the
// app's PageRouter.callPage calls it.
async function askSelection(document: Document): Promise<unknown> {
  const host = (document.defaultView as GalleryHostWindow | null)?.cmuxGalleryHost;
  if (!host) throw new Error("no gallery bridge host");
  return host.callPage(CURRENT_SELECTION_OP);
}

function expectSelection(reply: unknown, expected: HomeSelection | null): void {
  const envelope = reply as { t?: string; value?: unknown };
  const actual = envelope.t === "ok" ? envelope.value : reply;
  if (envelope.t !== "ok" || JSON.stringify(actual) !== JSON.stringify(expected))
    throw new Error(`home.currentSelection: ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`);
}

export default componentEntry<Props>({
  id: "pages.home-channels",
  title: "Home channels",
  area: "Home and Chief",
  height: 640,
  covers: [
    "page:cmux.home-channels",
    "pages/home-channels/HomeChannelsPage.tsx#HomeChannelsPage",
    "pages/home-channels/ConversationList.tsx#ConversationList",
    "pages/home-channels/Timeline.tsx#Timeline",
    "pages/home-channels/MessageRow.tsx#MessageRow",
    "pages/home-channels/Avatar.tsx#Avatar",
    "pages/home-channels/Avatar.tsx#ChannelMark",
    "pages/home-channels/Avatar.tsx#PicturesContext",
    "pages/home-channels/Composer.tsx#Composer",
    "pages/home-channels/ThreadSheet.tsx#ThreadSheet",
    "pages/home-channels/ThreadRow.tsx#ThreadRow",
    "pages/home-channels/Palette.tsx#Palette",
    "pages/home-channels/MessageActions.tsx#MessageActions",
    "pages/home-channels/EmojiPicker.tsx#EmojiPicker",
    "pages/home-channels/FormDialog.tsx#FormDialog",
    "pages/home-channels/PeoplePicker.tsx#PeoplePicker",
    "pages/home-channels/ConversationSheets.tsx#NewMessageSheet",
    "pages/home-channels/ConversationSheets.tsx#InviteSheet",
    "pages/home-channels/ChiefPage.tsx#ChiefPage",
    "pages/home-channels/ChiefBackendPicker.tsx#ChiefBackendPicker",
    "pages/home-channels/ChiefHistory.tsx#ChiefHistory",
    "pages/home-channels/RouteSheets.tsx#RouteSheets",
    "pages/home-channels/RouteSheets.tsx#ChiefRoutePage",
    "pages/home-channels/MessageRow.tsx#DraftRow",
    "pages/home-channels/icons.tsx#HomeIcon",
    "pages/home-channels/RunCard.tsx",
    "pages/home-channels/RunSheet.tsx",
    "pages/home-channels/GoalStrip.tsx#GoalStrip",
    "pages/home-channels/LiveTyping.tsx#LiveTyping",
    "pages/home-channels/AttachmentViews.tsx",
  ],
  load: async () => HomeChannelsGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("../../ui/ui.css");
    await import("../../agent-session/acpmux/conversation/conversation.css");
    await import("./styles.css");
    await import("./ledger.css");
  },
  variants: {
    "stable-thread-counts": {
      note: "Thread metadata keeps equal-width digits as reply and participant totals change.",
      props: { select: "c-incident", thread: "c-incident-m1", longThread: true },
    },
    "stable-picker-counts": {
      note: "The selected-person count uses tabular digits while choices change.",
      props: { select: "c-release", route: { kind: "newMessage" } },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-form .lg-picker-row input"));
        await ctx.click({ selector: ".lg-form .lg-picker-row input" });
      },
    },
    normal: { note: "The conversation list and the page's first conversation.", props: {} },
    channel: {
      note: "The #release channel: day separator, grouped rows, a reply, a thread summary, code.",
      props: { select: "c-release" },
    },
    thread: {
      note: "The thread sheet open on the sidebar-fix message.",
      props: { select: "c-release", thread: "c-release-m2" },
    },
    "thread-long": {
      note: "A thread past one page: the sheet counts every reply that is not retracted (the owner's stats), then loads the rest.",
      props: { select: "c-incident", thread: "c-incident-m1", longThread: true },
      play: async (ctx) => {
        const panelText = (selector: string) =>
          [...ctx.document.querySelectorAll(`.lg-sheet ${selector}`)].map((node) => node.textContent?.trim() ?? "");
        const scroller = { selector: ".lg-sheet .hc-timeline" };
        // The first page: 100 of the 130 replies, and the control for the rest.
        await ctx.waitFor(
          () => panelText(".hc-md").includes("Update 100.") && ctx.document.querySelector(".hc-thread-more"),
        );
        // The count is the owner's (every reply that is not retracted), not the loaded ones.
        await ctx.scroll(scroller, "top");
        await ctx.waitFor(() => panelText(".hc-replies-line").some((line) => line.includes("129")));
        await ctx.click({ selector: ".hc-thread-more" });
        await ctx.waitFor(() => !ctx.document.querySelector(".hc-thread-more"));
        await ctx.scroll(scroller, "bottom");
        await ctx.waitFor(() => panelText(".hc-md").includes("Update 130."));
      },
    },
    switcher: {
      note: "Cmd-K opens the palette; the best match is highlighted.",
      props: { select: "c-release" },
      checks: { longFrameFailMs: openFrame },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-list"));
        await ctx.press("Meta+k");
        await ctx.waitFor(() => switcherOpen(ctx));
      },
    },
    "switcher-filtered": {
      note: "The palette ranks conversations, threads and actions with the palette ranker as you type.",
      props: { select: "c-release" },
      checks: {
        longFrameFailMs: openFrame,
        layoutShiftMax: {
          value: 0.1,
          reason:
            "Filtering removes the rows and group headings above a match, so the kept rows move up; the dialog keeps its height.",
        },
      },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-list"));
        await ctx.press("Meta+k");
        await ctx.waitFor(() => switcherOpen(ctx));
        await ctx.type("rev", { selector: switcherField });
        await ctx.waitFor(() => ctx.document.querySelectorAll("[role='dialog'] [role='option']").length < 5);
      },
    },
    "switcher-empty": {
      note: "No conversation matches the query.",
      props: { select: "c-release" },
      checks: { longFrameFailMs: openFrame },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-list"));
        await ctx.press("Meta+k");
        await ctx.waitFor(() => switcherOpen(ctx));
        await ctx.type("zzzz", { selector: switcherField });
        await ctx.waitFor(() => ctx.document.querySelector(".lg-palette-none"));
      },
    },
    "selected-text": {
      note: "Selected message text under the default theme: it takes the theme's terminal selection color (slate blue), like every page (cx-wqn5).",
      props: { select: "c-release", terminalSelection: "#3f638b" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-main .hc-msg.head .hc-md"));
        await ctx.selectText({ selector: ".lg-main .hc-msg.head .hc-md" });
      },
    },
    teammates: {
      note: "A channel two teammates share: Sam has it open and Ana types, so both faces show in the header's presence stack.",
      props: { select: "c-launch", teammates: true },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-header .cv-presence"));
      },
    },
    offline: { note: "No host answers: the page is offline and empty.", props: { offline: true } },
    attachments: {
      note: "A message with three images (a grid), a video with its poster and a PDF row.",
      props: { select: "c-media", media: true },
      play: async (ctx) => {
        await ctx.scroll({ selector: ".lg-main .hc-timeline" }, "bottom");
        await ctx.waitFor(() => ctx.document.querySelectorAll(".hc-att-grid img").length === 3);
        await ctx.waitFor(() => Boolean(ctx.document.querySelector(".hc-att-video video")?.getAttribute("poster")));
      },
    },
    "attachments-lightbox": {
      note: "A click on an image opens the lightbox; the arrow keys move to the next image.",
      props: { select: "c-media", media: true },
      checks: {
        longFrameFailMs: openFrame,
        layoutShiftMax: {
          value: 0.05,
          reason: "The arrow key swaps the lightbox's image for the next one, which has its own size.",
        },
      },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".hc-att-grid img").length === 3);
        await ctx.click({ selector: ".hc-att-image" });
        await ctx.waitFor(() => ctx.document.querySelector(".hc-lightbox img"));
        await ctx.press("ArrowRight");
        await ctx.waitFor(
          () => ctx.document.querySelector(".hc-lightbox-bar .hc-att-name")?.textContent === "sidebar-after.png",
        );
      },
    },
    "attachments-composer": {
      note: "Files pasted into the composer show in its tray with their progress, then are ready to send.",
      props: { select: "c-media", media: true },
      play: async (ctx) => {
        const field = ".lg-main-compose .hc-composer-field";
        await ctx.waitFor(() => ctx.document.querySelector('.lg-main-compose button[aria-label="Attach files"]'));
        await ctx.click({ selector: field });
        const data = new DataTransfer();
        data.items.add(new File(["# Notes\n"], "notes.md", { type: "text/markdown" }));
        data.items.add(new File(["{}"], "result.json", { type: "application/json" }));
        ctx.document
          .querySelector(field)
          ?.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
        await ctx.waitFor(() => ctx.document.querySelectorAll(".lg-main-compose .hc-tray-item.done").length === 2);
      },
    },
    "composer-menu": {
      note: "Right-click in the composer: its own menu (Cut, Copy, Paste, Paste as Plain Text, Attach Files…, Insert Mention), never WebKit's. The gallery has no app host, so the edits are off.",
      props: { select: "c-chief" },
      play: async (ctx) => {
        const field = ".lg-main-compose .hc-composer-field";
        await ctx.waitFor(() => ctx.document.querySelector(field));
        await ctx.contextMenu({ selector: field });
        await ctx.waitFor(() => ctx.find({ role: "menuitem", name: "Paste as Plain Text" }));
        await ctx.waitFor(() => ctx.find({ role: "menuitem", name: "Attach Files…" }));
      },
    },
    "row-menu": {
      note: "Right-click a list row: Pin, Mark as Read (it has unread messages) and Copy Link, on the popup layer.",
      props: { select: "c-chief" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector('[data-list-row="c-release"]'));
        await ctx.contextMenu({ selector: '[data-list-row="c-release"]' });
        await ctx.waitFor(() => ctx.find({ role: "menuitem", name: "Mark as Read" }));
      },
    },
    pin: {
      note: "Shift-F10 on a row and Pin: the row moves under a quiet Pinned label; a later pin goes after it. Mark as Unread shows the dot; opening the conversation clears it.",
      props: { select: "c-chief" },
      checks: {
        layoutShiftMax: {
          value: 0.2,
          reason: "Pinning moves the row to the top of the list and adds the Pinned label; the other rows move down.",
        },
      },
      play: async (ctx) => {
        const row = (id: string) => ctx.document.querySelector<HTMLElement>(`[data-list-row="${id}"]`);
        const order = () =>
          [...ctx.document.querySelectorAll("[data-list-row]")].map((node) => node.getAttribute("data-list-row"));
        await ctx.waitFor(() => row("c-design"));
        await ctx.focus({ selector: '[data-list-row="c-design"]' });
        await ctx.press("Shift+F10");
        await ctx.waitFor(() => ctx.find({ role: "menuitem", name: "Pin" }));
        await ctx.press("Enter");
        await ctx.waitFor(() => ctx.document.querySelector(".lg-list-section") && order()[0] === "c-design");
        await ctx.contextMenu({ selector: '[data-list-row="c-reviewer"]' });
        await ctx.click({ role: "menuitem", name: "Pin" });
        await ctx.waitFor(() => order().slice(0, 2).join() === "c-design,c-reviewer");
        // Mark as Unread on a read conversation, then open it: the mark goes.
        await ctx.contextMenu({ selector: '[data-list-row="c-design"]' });
        await ctx.click({ role: "menuitem", name: "Mark as Unread" });
        await ctx.waitFor(() => row("c-design")?.classList.contains("unread"));
        await ctx.click({ selector: '[data-list-row="c-design"]' });
        await ctx.waitFor(() => row("c-design") && !row("c-design")!.classList.contains("unread"));
      },
    },
    "pin-refused": {
      note: "The owner refuses the pin: the row goes back to its place and the page says why.",
      props: { select: "c-chief", refuseInbox: true },
      checks: {
        layoutShiftMax: {
          value: 0.05,
          reason: "The refusal shows the error line above the timeline; the timeline moves down by its height.",
        },
      },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector('[data-list-row="c-design"]'));
        await ctx.contextMenu({ selector: '[data-list-row="c-design"]' });
        await ctx.click({ role: "menuitem", name: "Pin" });
        await ctx.waitFor(
          () =>
            ctx.document.querySelector(".hc-error") !== null &&
            ctx.document.querySelector(".lg-list-section") === null &&
            !ctx.document.querySelector('[data-list-row="c-design"]')?.hasAttribute("data-pinned"),
        );
      },
    },
    hover: {
      note: "Hovering a message shows its card: quick reactions, Add reaction, Reply in thread, More.",
      props: { select: "c-release" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-main .hc-msg.head"));
        await ctx.hover({ selector: ".lg-main .hc-msg.head" });
        await ctx.waitFor(() => ctx.document.querySelector(".hc-msg:hover .hc-msg-actions"));
      },
    },
    "thread-reply": {
      note: "A reply sent from the thread sheet lands in the thread and the thread row counts it.",
      props: { select: "c-release", thread: "c-release-m2" },
      checks: {
        layoutShiftMax: {
          value: 0.001,
          reason: "The new reply rewrites the thread row's count and last-reply time in place (a few pixels of text).",
        },
      },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-sheet .hc-composer [contenteditable]"));
        await ctx.type("Shipping it.", { selector: ".lg-sheet .hc-composer [contenteditable]" });
        await ctx.press("Enter");
        await ctx.waitFor(() =>
          [...ctx.document.querySelectorAll(".lg-sheet .hc-md")].some(
            (node) => node.textContent?.trim() === "Shipping it.",
          ),
        );
        // The owner took it: no pending row is left (the optimistic row ends on the owner's event).
        await ctx.waitFor(() => !ctx.document.querySelector(".hc-msg.pending"));
        // The summary had 3 replies (one inline reply, two thread replies); the new one makes 4.
        await ctx.waitFor(() => ctx.document.querySelector(".lg-main .lg-thread-count")?.textContent?.includes("4"));
      },
    },
    composer: {
      note: "Formatting (shown on demand): Bold applies a Markdown mark to the typed text; the toolbar shows it pressed.",
      props: { select: "c-chief" },
      checks: {
        layoutShiftMax: {
          value: 0.01,
          reason: "Show formatting adds the toolbar row on top of the field; the timeline above gives up that height.",
        },
      },
      play: async (ctx) => {
        const field = { selector: ".lg-main .hc-composer [contenteditable]" };
        await ctx.waitFor(() => ctx.document.querySelector(field.selector));
        await ctx.click(field);
        await ctx.click({ role: "button", name: "Show formatting" });
        await ctx.click({ role: "button", name: "Bold" });
        await ctx.type("Ship the fix today", field);
        await ctx.waitFor(() => ctx.document.querySelector(".lg-main .hc-composer strong"));
      },
    },
    emoji: {
      note: "The composer's emoji popover over the bundled emoji table.",
      props: { select: "c-chief" },
      checks: {
        longFrameFailMs: {
          value: 80,
          reason: "The first open decodes the bundled emoji table (~290 KB JSON) once; later opens reuse it.",
        },
      },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector('.lg-main [data-bar="emoji"]'));
        await ctx.click({ role: "button", name: "Emoji" });
        await ctx.waitFor(() => ctx.document.querySelector(".hc-emoji-cell"));
      },
    },
    "emoji-return": {
      note: "Return in the emoji search inserts the first result into the composer and closes the popover.",
      props: { select: "c-chief" },
      checks: {
        longFrameFailMs: {
          value: 80,
          reason: "The first open decodes the bundled emoji table (~290 KB JSON) once; later opens reuse it.",
        },
        layoutShiftMax: {
          value: 0.05,
          reason: "Typing filters the grid a letter at a time, so the cells it keeps move to new places.",
        },
      },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector('.lg-main [data-bar="emoji"]'));
        await ctx.click({ role: "button", name: "Emoji" });
        await ctx.type("rocket", { selector: ".hc-emoji-search" });
        await ctx.waitFor(() => ctx.document.querySelector(".hc-emoji-cell"));
        const first = ctx.document.querySelector(".hc-emoji-cell")?.textContent?.trim() ?? "";
        await ctx.press("Enter");
        await ctx.waitFor(
          () =>
            !ctx.document.querySelector(".hc-emoji") &&
            (ctx.document.querySelector(".lg-main .hc-composer [contenteditable]")?.textContent ?? "").includes(first),
        );
      },
    },
    "new-message": {
      note: "The list header's compose button opens #/new/message: pick people and Chiefs, name it to make a channel.",
      props: { select: "c-chief" },
      checks: {
        longFrameFailMs: openFrame,
        layoutShiftMax: {
          value: 0.01,
          reason: "A picked person moves to the top of the picker, so the rows above their old place move down.",
        },
      },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-list-header .hc-icon-button"));
        await ctx.click({ selector: ".lg-list-header .hc-icon-button" });
        await ctx.waitFor(() => ctx.document.querySelector(".lg-form .lg-picker-row"));
        await ctx.click({ selector: '.lg-form input[aria-label="Builder"]' });
        await ctx.click({ selector: '.lg-form input[aria-label="Reviewer"]' });
        await ctx.type("launch", { selector: ".lg-form-field .hc-link-field" });
        await ctx.waitFor(() => ctx.document.querySelector(".lg-form-actions .primary:not(:disabled)"));
      },
    },
    "new-message-search": {
      note: "Typing in the sheet's search narrows the people and Chiefs; the picked ones stay on top.",
      props: { select: "c-chief", route: { kind: "newMessage" } },
      checks: {
        longFrameFailMs: openFrame,
        layoutShiftMax: { value: 0.05, reason: "The search removes rows that do not match; the kept rows move up." },
      },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-form .lg-picker-search"));
        await ctx.type("rev", { selector: ".lg-form .lg-picker-search" });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".lg-form .lg-picker-row").length === 1);
      },
    },
    "new-chief": {
      note: "#/new/chief in a plain browser: a new Chief needs the person's click in the cmux app, so the sheet is read-only and says so.",
      props: { select: "c-chief", route: { kind: "newChief" } },
      checks: { longFrameFailMs: openFrame },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".chief-editor .lg-chief-identity input:disabled"));
        await ctx.waitFor(() => ctx.document.querySelector(".chief-editor .lg-grant:disabled"));
      },
    },
    "new-chief-grants": {
      note: "In the app the host relays the person's click: the whole profile, the tools and the harnesses can be set.",
      props: { select: "c-chief", route: { kind: "newChief" }, hostGrants: true },
      checks: { longFrameFailMs: openFrame },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".chief-editor .lg-grant:not(:disabled)"));
        await ctx.type("Release Chief", { selector: ".chief-editor .lg-chief-identity input" });
        // The default tools and every harness show checked (the owner's default means every harness).
        const checked = DEFAULT_CHIEF_TOOLS.length + CHIEF_HARNESSES.length;
        await ctx.waitFor(
          () => ctx.document.querySelectorAll(".chief-editor .lg-grant input:checked").length === checked,
        );
      },
    },
    "primary-hover": {
      note: "The pointer on an enabled primary button keeps its light fill (a soft ring shows the hover); it never looks disabled.",
      props: { select: "c-chief", route: { kind: "newChief" }, hostGrants: true },
      checks: { longFrameFailMs: openFrame },
      play: async (ctx) => {
        const primary = ".chief-editor .lg-form-actions .primary";
        await ctx.waitFor(() => ctx.document.querySelector(".chief-editor .lg-grant:not(:disabled)"));
        await ctx.type("Docs Chief", { selector: ".chief-editor .lg-chief-identity input" });
        await ctx.waitFor(() => ctx.document.querySelector(`${primary}:not(:disabled)`));
        const look = () => {
          const button = ctx.document.querySelector<HTMLElement>(primary)!;
          const style = ctx.document.defaultView!.getComputedStyle(button);
          return {
            background: style.backgroundColor,
            opacity: style.opacity,
            color: style.color,
            ring: style.boxShadow,
          };
        };
        const resting = look();
        await ctx.hover({ selector: primary });
        await ctx.waitFor(() => {
          const hovered = look();
          // The hover rule applied (its ring shows) and the fill, ink and opacity stayed the primary's.
          return (
            hovered.ring !== resting.ring &&
            hovered.background === resting.background &&
            hovered.color === resting.color &&
            hovered.opacity === "1"
          );
        });
      },
    },
    "new-chief-defaults": {
      note: "Create with the grant left as it is: the sheet names no tools or harnesses, so the owner applies its defaults.",
      props: { select: "c-chief", route: { kind: "newChief" }, hostGrants: true },
      checks: {
        longFrameFailMs: {
          value: 200,
          reason:
            "Create closes the sheet and opens the new Chief's direct message (list, header, empty timeline, composer) in one frame: ~150 ms on the CPU-only VM.",
        },
        layoutShiftMax: {
          value: 0.01,
          reason: "Create adds the new Chief's direct message to the list and opens it; the rows below move down.",
        },
      },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".chief-editor .lg-grant:not(:disabled)"));
        await ctx.type("Docs Chief", { selector: ".chief-editor .lg-chief-identity input" });
        await ctx.click({ selector: ".chief-editor .lg-form-actions .primary" });
        await ctx.waitFor(() => {
          const sent = ctx.document.documentElement.dataset.mockChiefCreate ?? "";
          return sent.includes("display_name") && !sent.includes("tools") && !sent.includes("harnesses");
        });
      },
    },
    "edit-chief": {
      note: "#/chief/<agent>/edit from the Chief's header: the profile with its current values.",
      props: { select: "c-chief" },
      checks: { longFrameFailMs: openFrame },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.find({ role: "button", name: "Edit Chief" }));
        await ctx.click({ role: "button", name: "Edit Chief" });
        await ctx.waitFor(
          () =>
            ctx.document.querySelector<HTMLInputElement>(".chief-editor .lg-chief-identity input")?.value === "Chief",
        );
      },
    },
    "chief-backend": {
      note: "Edit Chief's Backend: the installed acpmux harnesses, a model and its effort from the harness's capabilities, and History with Undo.",
      props: { select: "c-chief", route: { kind: "editChief", chief: "agent_chief" }, hostGrants: true },
      checks: { longFrameFailMs: openFrame },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".chief-editor [data-chief-backend] option").length > 3);
        await ctx.waitFor(() => ctx.document.querySelector(".chief-editor [data-chief-history] .ce-history-row"));
      },
    },
    "chief-bring-your-own": {
      note: "Bring your own…: an Anthropic-compatible endpoint with its key; the check fails at the hello turn and shows the fix.",
      props: { select: "c-chief", route: { kind: "editChief", chief: "agent_chief" }, hostGrants: true },
      checks: { longFrameFailMs: openFrame },
      play: async (ctx) => {
        const picker = ".chief-editor [data-chief-backend] select";
        await ctx.waitFor(() => ctx.document.querySelectorAll(`${picker} option`).length > 3);
        const select = ctx.document.querySelector<HTMLSelectElement>(picker)!;
        select.value = select.options[select.options.length - 1]!.value;
        select.dispatchEvent(new Event("change", { bubbles: true }));
        await ctx.waitFor(() => ctx.document.querySelector(".chief-editor [data-chief-byo]"));
        await ctx.type("Broken endpoint", { selector: ".chief-editor [data-chief-byo] input[aria-label='Name']" });
      },
    },
    invite: {
      note: "#/conversation/<id>/invite from the header: add people or Chiefs who are not in it yet.",
      props: { select: "c-release" },
      checks: { longFrameFailMs: openFrame },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.find({ role: "button", name: "Add people" }));
        await ctx.click({ role: "button", name: "Add people" });
        // Everyone the sample Home knows is in #release already: the picker says so.
        await ctx.waitFor(() => ctx.document.querySelector(".lg-form .lg-picker-none"));
      },
    },
    "archive-chief": {
      note: "#/chief/<agent>/archive asks once: the Chief stops and its memory is kept for 30 days.",
      props: {
        select: "c-chief",
        route: { kind: "archiveChief", chief: "agent_new1" },
        hostGrants: true,
        extraChief: true,
      },
      checks: { longFrameFailMs: openFrame },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-form .hc-text-button.danger"));
      },
    },
    draft: {
      note: "The Chief's reply grows in its row while it is written (conversation-draft events).",
      props: { select: "c-chief", draft: "growing" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".hc-msg.draft"));
      },
    },
    run: {
      note: "The Chief's finished run under its reply: Worked for, steps, tokens (no dollar figure); Open shows the whole run.",
      props: { select: "c-chief", runs: "done" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-run.done"));
      },
    },
    "run-messages": {
      note: "Chief's tell and an agent report remain visible with the finished run folded.",
      props: { select: "c-chief", runs: "messages" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-run.done"));
      },
    },
    "run-messages-open": {
      note: "Either message expands independently of the run, preserving its complete body.",
      props: { select: "c-chief", runs: "messages" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".lg-run-messages .cv-agentmsg").length === 2);
        await ctx.click({
          selector: '.lg-run-messages [data-direction="sent"] .cv-agentmsg__toggle',
        });
        await ctx.click({
          selector: '.lg-run-messages [data-direction="received"] .cv-agentmsg__toggle',
        });
      },
    },
    "run-messages-narrow": {
      note: "Both message rows remain readable in a narrow Home conversation.",
      props: { width: 380, pane: "conversation", select: "c-chief", runs: "messages" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".lg-run-messages .cv-agentmsg").length === 2);
      },
    },
    "run-open": {
      note: "The run sheet: every step in order (shell output, the read, a folded thought, the diff, the reply), time, tokens and the cost labelled as API prices.",
      props: { select: "c-chief", runs: "done" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-run.done .lg-run-open"));
        await ctx.click({ selector: ".lg-run.done .lg-run-open" });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".lg-run-sheet .cv-tool").length >= 3);
        await ctx.waitFor(() => ctx.document.querySelector(".lg-run-sheet details.thought:not([open])"));
      },
    },
    "run-live": {
      note: "A run that works now: Working for (ticking), its reply as it streams and its newest steps under the question; the typing row shows the reply's end and what it works on.",
      props: { select: "c-chief", runs: "live" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-run.running .cv-tool"));
        await ctx.waitFor(() => ctx.document.querySelector(".lg-run.running .lg-run-live"));
        await ctx.waitFor(() => ctx.document.querySelector(".lg-typing.live .lg-live-activity"));
      },
    },
    "run-live-sheet": {
      note: "A tap on the typing row's live line opens the running run in the run sheet.",
      props: { select: "c-chief", runs: "live" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-typing.live .lg-live"));
        await ctx.click({ selector: ".lg-typing.live .lg-live" });
        await ctx.waitFor(() => ctx.document.querySelector('.lg-run-sheet[data-status="running"]'));
      },
    },
    "narrow-run-live": {
      note: "A streaming run on a 380 px page: the reply's end wraps in the card, the typing row keeps one line each.",
      props: { width: 380, pane: "conversation", select: "c-chief", runs: "live" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-run.running .lg-run-live"));
      },
    },
    "narrow-list": {
      note: "The docked Home (600 px): one pane at a time; with no conversation in the hash, the list.",
      props: { width: 600, pane: "list" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-list [data-list-row]"));
      },
    },
    "narrow-conversation": {
      note: "600 px with a conversation open: the conversation fills the page, Back in its header, the run card on one line.",
      props: { width: 600, pane: "conversation", select: "c-chief", runs: "done" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-back") && ctx.document.querySelector(".lg-run.done"));
      },
    },
    "narrow-thread": {
      note: "600 px: the thread sheet covers the conversation pane.",
      props: { width: 600, pane: "conversation", select: "c-release", thread: "c-release-m2" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-sheet"));
      },
    },
    "narrow-run-card": {
      note: "A narrow run card (380 px page): Worked for and Open on the first line, the step count and tokens under it.",
      props: { width: 380, pane: "conversation", select: "c-chief", runs: "done" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-run.done .lg-run-metas"));
      },
    },
    "narrow-run-card-480": {
      note: "A run card on a 480 px page: the step count and tokens move under Worked for as one line, never starting with a separator.",
      props: { width: 480, pane: "conversation", select: "c-chief", runs: "done" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-run.done .lg-run-metas"));
      },
    },
    "host-selection": {
      note: "The host asks home.currentSelection over the page bridge: the open conversation, then the keyboard's current message.",
      props: { select: "c-release", hostBridge: true },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector('.lg-main [data-key="c-release-m7"]'));
        expectSelection(await askSelection(ctx.document), { conversation: "c-release" });
        // j/k need the focus outside a text field: the open conversation's list row.
        await ctx.focus({ selector: "[data-list-row][aria-current]" });
        await ctx.press("k");
        await ctx.waitFor(() => ctx.document.querySelector('[data-key="c-release-m7"] [aria-current="true"]'));
        expectSelection(await askSelection(ctx.document), { conversation: "c-release", message: "c-release-m7" });
        await ctx.press("k");
        await ctx.waitFor(() => ctx.document.querySelector('[data-key="c-release-m6"] [aria-current="true"]'));
        expectSelection(await askSelection(ctx.document), { conversation: "c-release", message: "c-release-m6" });
      },
    },
    "host-selection-thread": {
      note: "An open thread and no keyboard message: home.currentSelection names the thread's root.",
      props: { select: "c-release", thread: "c-release-m2", hostBridge: true },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-sheet"));
        expectSelection(await askSelection(ctx.document), { conversation: "c-release", message: "c-release-m2" });
      },
    },
    "host-selection-empty": {
      note: "The docked Home's list pane: nothing is open, so home.currentSelection answers null.",
      props: { width: 600, pane: "list", select: "c-release", hostBridge: true },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-list [data-list-row]"));
        expectSelection(await askSelection(ctx.document), null);
      },
    },
    "link-no-resolver": {
      note: "A message link to a reply when the owner has no link read (a Cloud conversation): the page finds it in its pages, opens its thread and marks it.",
      props: { link: "cmux://conversation/c-release/message/c-release-m4" },
      play: async (ctx) => {
        await ctx.waitFor(() =>
          [...ctx.document.querySelectorAll(".lg-sheet .hc-msg.highlighted .hc-md")].some((node) =>
            node.textContent?.includes("restoreAnchor"),
          ),
        );
        if (ctx.document.querySelector(".lg-error, .hc-error")) throw new Error("the page shows an error");
      },
    },
    "link-no-resolver-timeline": {
      note: "A message link to a timeline message with no link read: the conversation opens with the message marked.",
      props: { link: "cmux://conversation/c-release/message/c-release-m6" },
      play: async (ctx) => {
        await ctx.waitFor(() =>
          [...ctx.document.querySelectorAll(".lg-main .hc-msg.highlighted .hc-md")].some((node) =>
            node.textContent?.includes("Changelog draft"),
          ),
        );
      },
    },
    "draft-posted": {
      note: "The reply posts: its draft row ends, the message shows once, and a late draft item stays hidden.",
      props: { select: "c-chief", draft: "posted" },
      play: async (ctx) => {
        await ctx.waitFor(
          () =>
            !ctx.document.querySelector(".hc-msg.draft") &&
            [...ctx.document.querySelectorAll(".hc-msg .hc-md")].filter((node) =>
              node.textContent?.startsWith("Checking the release"),
            ).length === 1,
        );
      },
    },
  },
});
