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
import { MockHomeProvider, type MockDraft } from "./mockProvider";
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
};

function HomeChannelsGallery({ select, thread, offline = false, draft, longThread = false }: Props) {
  const [store] = useState(() => {
    const created = new HomeChannelsStore(offline ? null : new MockHomeProvider(draft, longThread));
    if (select)
      void created.select(select).then(() => {
        if (thread) void created.openThread(thread);
      });
    return created;
  });
  const [strings] = useState(() => createStrings(table));
  const [root, setRoot] = useState<HTMLDivElement | null>(null);
  return (
    <div ref={setRoot} style={{ height: "100%" }}>
      {root ? (
        <UiProvider container={root}>
          <HomeChannelsPage store={store} strings={strings} />
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
    "pages/home-channels/Composer.tsx#Composer",
    "pages/home-channels/ThreadSheet.tsx#ThreadSheet",
    "pages/home-channels/ThreadRow.tsx#ThreadRow",
    "pages/home-channels/Palette.tsx#Palette",
    "pages/home-channels/MessageActions.tsx#MessageActions",
    "pages/home-channels/EmojiPicker.tsx#EmojiPicker",
    "pages/home-channels/AddChannel.tsx#AddChannel",
    "pages/home-channels/MessageRow.tsx#DraftRow",
    "pages/home-channels/icons.tsx#HomeIcon",
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
          value: 0.03,
          reason:
            "Filtering removes the rows above a match, so the kept rows move up (the same before the primitives); rows are 34 px since cx-doy6.",
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
        // The summary had 3 replies (one inline reply, two thread replies); the new one makes 4.
        await ctx.waitFor(() => ctx.document.querySelector(".lg-main .lg-thread-count")?.textContent?.includes("4"));
      },
    },
    composer: {
      note: "Formatting (shown on demand): Bold applies a Markdown mark to the typed text; the toolbar shows it pressed.",
      props: { select: "c-chief" },
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
    "add-channel": {
      note: "Add channel in the list header; the popover asks for a name and members.",
      props: { select: "c-chief" },
      checks: {
        longFrameFailMs: {
          value: 66,
          reason:
            "Cold first open of the shared Popover (Floating UI positioning): one ~54 ms frame on the CPU-only VM.",
        },
      },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".lg-list-header .hc-icon-button"));
        await ctx.click({ selector: ".lg-list-header .hc-icon-button" });
        await ctx.waitFor(() => ctx.document.querySelector(".hc-add-channel input"));
        await ctx.type("launch", { selector: ".hc-add-channel input" });
      },
    },
    draft: {
      note: "The Chief's reply grows in its row while it is written (conversation-draft events).",
      props: { select: "c-chief", draft: "growing" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".hc-msg.draft"));
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
