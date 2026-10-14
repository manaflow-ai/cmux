// l10n-allow-file: gallery fixtures (sample conversations), not shipped UI.
// The channels Home (cmux-page://cmux.home-channels/): the same page main.tsx mounts, over the
// in-memory provider's sample channels and direct messages, so the rail, timeline, message rows,
// composer, thread panel and the Cmd-K switcher show without the app.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { UiProvider } from "../../ui/UiProvider";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { HomeChannelsPage } from "./HomeChannelsPage";
import { MockHomeProvider, type MockDraft, type MockRuns } from "./mockProvider";
import type { Pane } from "./panes";
import type { HomeRoute } from "./routes";
import { HomeChannelsStore } from "./store";

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
  /** A sheet route (routes.ts) to open. */
  route?: HomeRoute;
  /** The host relays the person's click for a Chief's grant and delete (the app). */
  hostGrants?: boolean;
  /** Adds a second Chief (one that can be archived). */
  extraChief?: boolean;
  /** The page's own width (px): below 720 it shows one pane (panes.ts), `pane`. */
  width?: number;
  pane?: Pane;
};

function HomeChannelsGallery({
  select,
  thread,
  offline = false,
  draft,
  longThread = false,
  runs = "none",
  refuseInbox = false,
  media = false,
  route,
  hostGrants = false,
  extraChief = false,
  width,
  pane,
}: Props) {
  const [store] = useState(() => {
    const provider = offline ? null : new MockHomeProvider(draft, longThread, runs, refuseInbox, media);
    if (provider) provider.hostGrants = hostGrants;
    if (provider && extraChief) provider.addChief("Release Chief");
    const created = new HomeChannelsStore(provider, undefined, hostGrants ? provider : null);
    // The gallery owns its window hash: the page never writes it here.
    created.routed = false;
    if (route) created.sheets.show(route);
    if (select)
      void created.select(select).then(() => {
        if (thread) void created.openThread(thread);
      });
    return created;
  });
  const [strings] = useState(() => createStrings(table));
  const [root, setRoot] = useState<HTMLDivElement | null>(null);
  return (
    <div ref={setRoot} style={{ height: "100%", width: width ?? "100%" }}>
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
    "pages/home-channels/ChiefSheet.tsx#ChiefSheet",
    "pages/home-channels/RouteSheets.tsx#RouteSheets",
    "pages/home-channels/MessageRow.tsx#DraftRow",
    "pages/home-channels/icons.tsx#HomeIcon",
    "pages/home-channels/RunCard.tsx",
    "pages/home-channels/RunSheet.tsx",
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
        await ctx.waitFor(() => ctx.document.querySelector(".lg-form .lg-chief-identity input:disabled"));
        await ctx.waitFor(() => ctx.document.querySelector(".lg-form .lg-grant:disabled"));
      },
    },
    "new-chief-grants": {
      note: "In the app the host relays the person's click: the whole profile, the tools and the harnesses can be set.",
      props: { select: "c-chief", route: { kind: "newChief" }, hostGrants: true },
      checks: { longFrameFailMs: openFrame },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-form .lg-grant:not(:disabled)"));
        await ctx.type("Release Chief", { selector: ".lg-form .lg-chief-identity input" });
        // Every harness shows checked (the owner's default means every harness).
        await ctx.waitFor(() => ctx.document.querySelectorAll(".lg-form .lg-grant input:checked").length === 7);
      },
    },
    "new-chief-defaults": {
      note: "Create with the grant left as it is: the sheet names no tools or harnesses, so the owner applies its defaults.",
      props: { select: "c-chief", route: { kind: "newChief" }, hostGrants: true },
      checks: {
        longFrameFailMs: openFrame,
        layoutShiftMax: {
          value: 0.01,
          reason: "Create adds the new Chief's direct message to the list and opens it; the rows below move down.",
        },
      },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-form .lg-grant:not(:disabled)"));
        await ctx.type("Docs Chief", { selector: ".lg-form .lg-chief-identity input" });
        await ctx.click({ selector: ".lg-form-actions .primary" });
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
          () => ctx.document.querySelector<HTMLInputElement>(".lg-form .lg-chief-identity input")?.value === "Chief",
        );
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
      note: "The Chief's finished run under its reply: Worked for, steps, cost; Open shows the whole run.",
      props: { select: "c-chief", runs: "done" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-run.done"));
      },
    },
    "run-open": {
      note: "The run sheet: every step in order (shell output, the read, the diff, the reply), time, tokens and cost.",
      props: { select: "c-chief", runs: "done" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-run.done .lg-run-open"));
        await ctx.click({ selector: ".lg-run.done .lg-run-open" });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".lg-run-sheet .cv-tool").length >= 3);
      },
    },
    "run-live": {
      note: "A run that works now: Working for (ticking), its newest steps under the question, the Chief shown working.",
      props: { select: "c-chief", runs: "live" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-run.running .cv-tool"));
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
      note: "A narrow run card (380 px page): Worked for and Open on the first line, the step count and cost under it.",
      props: { width: 380, pane: "conversation", select: "c-chief", runs: "done" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-run.done .lg-run-metas"));
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
