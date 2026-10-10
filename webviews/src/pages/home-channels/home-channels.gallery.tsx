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
import { MockHomeProvider } from "./mockProvider";
import { HomeChannelsStore } from "./store";

type Props = {
  /** The conversation the page opens with; default: the page's own first choice. */
  select?: string;
  /** A thread root message to open in the thread panel. */
  thread?: string;
  /** No host: the page shows its offline state. */
  offline?: boolean;
};

function HomeChannelsGallery({ select, thread, offline = false }: Props) {
  const [store] = useState(() => {
    const created = new HomeChannelsStore(offline ? null : new MockHomeProvider());
    if (select)
      void created.select(select).then(() => {
        if (thread) created.openThread(thread);
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

// The first Cmd-K mounts ui/Dialog (focus trap, the page behind made inert) and ui/Combobox; on
// the CPU-only VM the first case of a run has one ~50-58 ms frame, warm repeats stay under 33 ms.
const openFrame = {
  value: 66,
  reason:
    "Cold first open of the shared Dialog + Combobox: one ~55 ms frame on the CPU-only VM, warm runs pass at 33 ms.",
};
const switcherField = ".hc-switcher input";
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
    "pages/home-channels/Rail.tsx#Rail",
    "pages/home-channels/Timeline.tsx#Timeline",
    "pages/home-channels/MessageRow.tsx#MessageRow",
    "pages/home-channels/Avatar.tsx#Avatar",
    "pages/home-channels/Composer.tsx#Composer",
    "pages/home-channels/ThreadPanel.tsx#ThreadPanel",
    "pages/home-channels/Switcher.tsx#Switcher",
  ],
  load: async () => HomeChannelsGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("../../ui/ui.css");
    await import("../../agent-session/acpmux/conversation/conversation.css");
    await import("./styles.css");
  },
  variants: {
    normal: { note: "The rail and the page's first conversation.", props: {} },
    channel: {
      note: "The #release channel: day separator, grouped rows, a reply, a thread summary, code.",
      props: { select: "c-release" },
    },
    thread: {
      note: "The thread panel open on the sidebar-fix message.",
      props: { select: "c-release", thread: "c-release-m2" },
    },
    switcher: {
      note: "Cmd-K opens the switcher; the best match is highlighted.",
      props: { select: "c-release" },
      checks: { longFrameFailMs: openFrame },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".hc-rail"));
        await ctx.press("Meta+k");
        await ctx.waitFor(() => switcherOpen(ctx));
      },
    },
    "switcher-filtered": {
      note: "The switcher ranks conversations with the palette ranker as you type.",
      props: { select: "c-release" },
      checks: {
        longFrameFailMs: openFrame,
        layoutShiftMax: {
          value: 0.02,
          reason:
            "Filtering removes the rows above a match, so the kept rows move up (the same before the primitives).",
        },
      },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".hc-rail"));
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
        await ctx.waitFor(() => ctx.document.querySelector(".hc-rail"));
        await ctx.press("Meta+k");
        await ctx.waitFor(() => switcherOpen(ctx));
        await ctx.type("zzzz", { selector: switcherField });
        await ctx.waitFor(() => ctx.document.querySelector(".hc-switcher-none"));
      },
    },
    offline: { note: "No host answers: the page is offline and empty.", props: { offline: true } },
  },
});
