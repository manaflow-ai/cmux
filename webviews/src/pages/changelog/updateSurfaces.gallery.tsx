// l10n-allow-file: gallery fixtures (public-safe release notes from release-notes/next/highlights), not shipped UI.
// The update-ready highlights (cx-urd.61): the staged "Restart to Update" card's hover card, on the
// app theme. Each state shows on a plain page and on a wallpaper (Leo 2026-10-13).
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import type { ReleaseNotes } from "./types";
import type { UpdateHighlights } from "./updateHighlights";
import { UpdateReadyHighlights, type BriefLayout, type ReadyLayout } from "./UpdateSurfaces";

const base: UpdateHighlights = {
  version: "1.0.0-nightly.3845050428001",
  build: "3845050428001",
  fromVersion: "1.0.0-nightly.410",
  fromBuild: "3720357960410",
  date: "2026-10-12",
  builtAt: "2026-10-12T19:38:52Z",
  head: "a9d1434de781a18ebae84d93d2b5a803864f5839",
  source: "whatsNew",
  language: "en",
  items: [
    {
      id: "workspace-groups",
      title: "Workspace groups you can see at a glance",
      summary: "Colored labels, icons, and pins that keep a group.",
      category: "new",
    },
    {
      id: "undo-tab-close",
      title: "Undo a tab close from a toast",
      summary: "One click or ⌘Z brings the tabs back.",
      category: "new",
    },
    {
      id: "restart-instant",
      title: "Restart to Update reacts at once",
      summary: "Terminals and agents keep running.",
      category: "improved",
    },
  ],
  moreCount: 6,
  changelog: { from: "1.0.0-nightly.410", to: "1.0.0-nightly.414" },
};

type Props = {
  data: UpdateHighlights;
  /** The notes of every build the update spans, as the popover loads them from the host. */
  span?: ReleaseNotes[];
  wallpaper?: boolean;
  maxHeight?: number;
  /** The popover in one theme's tokens over that theme's sidebar: a light, a dark and a custom
   *  (purple) theme. */
  theme?: keyof typeof themes;
  /** Where the popover with no change list puts See release notes. */
  briefLayout?: BriefLayout;
  /** How the popover with a change list lays out a change. */
  layout?: ReadyLayout;
  /** The stage's width, default 360. */
  width?: number;
};

// Three themes as WebTheme sends them (the page's --page-* and the glass's surface), each over its
// own sidebar color, so the popover shows it takes the theme and not a neutral gray.
const themes = {
  light: { scheme: "light", surface: "#ffffff", sidebar: "#ecebe8", text: "#24292f" },
  dark: { scheme: "dark", surface: "#1e1e1e", sidebar: "#2a2a2a", text: "#d4d4d4" },
  purple: { scheme: "dark", surface: "#2b1650", sidebar: "#3a2468", text: "#f4e3ff" },
} as const;

function themeStyle(name: keyof typeof themes): Record<string, string> {
  const { scheme, surface, sidebar, text } = themes[name];
  return {
    colorScheme: scheme,
    background: sidebar,
    color: text,
    "--glass-surface": surface,
    // The host's theme tokens the composer's material reads (WebTheme).
    "--cmux-surface-solid": surface,
    "--cmux-text": text,
    "--page-text": text,
    "--page-text-2": `color-mix(in srgb, ${text} 70%, transparent)`,
    "--page-text-3": `color-mix(in srgb, ${text} 50%, transparent)`,
    "--page-separator": `color-mix(in srgb, ${text} 12%, transparent)`,
    "--page-hover": `color-mix(in srgb, ${text} 6%, transparent)`,
    "--page-selection": `color-mix(in srgb, ${text} 10%, transparent)`,
  };
}

// A stand-in screenshot (the host inlines real ones as data: URLs): a window with a sidebar.
function shot(background: string, sidebar: string, line: string): string {
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" width="640" height="360" viewBox="0 0 640 360">` +
    `<rect width="640" height="360" rx="14" fill="${background}"/>` +
    `<rect x="12" y="12" width="150" height="336" rx="10" fill="${sidebar}"/>` +
    `<rect x="28" y="40" width="110" height="12" rx="6" fill="${line}"/>` +
    `<rect x="28" y="64" width="90" height="12" rx="6" fill="${line}"/>` +
    `<rect x="28" y="88" width="100" height="12" rx="6" fill="${line}"/>` +
    `<rect x="182" y="40" width="420" height="18" rx="9" fill="${line}"/>` +
    `<rect x="182" y="76" width="300" height="12" rx="6" fill="${line}"/></svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

const withMedia: UpdateHighlights = {
  ...base,
  items: base.items.map((item, index) =>
    index === 0
      ? {
          ...item,
          media: {
            light: shot("#f3f1ed", "#e4e0d8", "#c9c3b8"),
            dark: shot("#1f2124", "#2b2e33", "#4a4f57"),
            alt: "The sidebar with colored workspace groups",
          },
        }
      : item,
  ),
};

const longNotes: UpdateHighlights = {
  ...withMedia,
  items: withMedia.items.map((item) => ({
    ...item,
    summary: `${item.summary} It works the same in every window, survives a relaunch, and follows the theme you picked in Settings.`,
  })),
};

// Leo's screenshot (2026-11-05, nightly 4210546 to 4212118: "this is too big ... i can't even
// scroll through the changes from that preview!"): the staged build's one change with its long
// paragraph, and the changes of the nightlies the update skips, which the popover now lists too.
const rollbackLine =
  "What's New lists the recent builds of your channel. Pick one and cmux downloads it, checks its signature the same way it checks an update, installs it and restarts, keeping your windows, tabs and running agents.";
const leoData: UpdateHighlights = {
  ...base,
  version: "1.0.0-nightly.4212118000001",
  build: "4212118000001",
  fromVersion: "1.0.0-nightly.4210546000001",
  fromBuild: "4210546000001",
  source: "whatsNew",
  items: [
    { id: "rollback", title: "Go back to any recent version from What's New", summary: rollbackLine, category: "new" },
  ],
  rest: [],
  moreCount: 0,
  changelog: { from: "1.0.0-nightly.4210546000001", to: "1.0.0-nightly.4212118000001" },
};
const skipped: [string, string, "new" | "improved" | "fixed"][] = [
  ["Session Info sections drag to a new order", "The order stays per window.", "new"],
  ["The model menu shows each model's effort", "", "improved"],
  ["Workspace rows keep their color while dragged", "", "improved"],
  ["Onboarding steps share one edge", "Text, icons and controls line up.", "improved"],
  ["The agent chat's live line names the tool it runs", "", "improved"],
  ["Terminal tabs reopen where they were", "Closing the last tab of a pane keeps the pane.", "fixed"],
  ["Find in the browser pane scrolls to the match", "", "fixed"],
  ["Restart to Update keeps a pinned hover card", "", "fixed"],
  ["Pasting a screenshot into the composer keeps its name", "", "fixed"],
  ["A paused cloud machine resumes on its first keystroke", "", "fixed"],
  ["The command palette lists recent settings first", "", "improved"],
  ["Notifications mark a session read when you open it", "", "fixed"],
];
const leoSpan: ReleaseNotes[] = [
  {
    build: "4212118000001",
    shortVersion: leoData.version,
    date: "2026-11-05",
    highlights: [{ id: "rollback", title: leoData.items[0]!.title, body: rollbackLine, category: "new" }],
    changes: [],
  },
  {
    build: "4211300000001",
    shortVersion: "1.0.0-nightly.4211300000001",
    date: "2026-11-05",
    highlights: skipped.map(([title, body, category], index) => ({ id: `skipped-${index}`, title, body, category })),
    changes: [],
  },
];

// A stand-in wallpaper: a busy photo-like gradient, so the card's translucency shows.
const wallpaper = "linear-gradient(160deg, #3b5b7a 0%, #c98b5a 45%, #e7c9a0 60%, #2f4a3a 100%)";

function UpdateSurfacesGallery({
  data,
  span: notes,
  wallpaper: onWallpaper = false,
  maxHeight,
  theme,
  briefLayout,
  layout,
  width,
}: Props) {
  const [strings] = useState(() => createStrings(table));
  const noop = () => undefined;
  return (
    <div
      className="wn-gallery-stage"
      style={{
        width: width ?? 360,
        padding: 10,
        ...(onWallpaper ? { backgroundImage: wallpaper } : {}),
        ...(theme ? themeStyle(theme) : {}),
      }}
    >
      <div
        style={{
          // As wide as the popover: the host sizes the window to the page's width.
          width: "fit-content",
          borderRadius: 8,
          background: "var(--page-elevated)",
          boxShadow: "0 0 0 1px var(--page-separator)",
          overflow: "hidden",
          // A window shorter than the hover card's cap (60% of it): the list scrolls in place.
          ...(maxHeight ? { "--wn-pop-max": `${maxHeight}px` } : {}),
        }}
      >
        <UpdateReadyHighlights
          data={data}
          span={notes}
          strings={strings}
          actions={{ openChangelog: noop }}
          briefLayout={briefLayout}
          layout={layout}
        />
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "pages.changelog.update-surfaces",
  title: "Update-ready highlights",
  area: "Pages",
  covers: ["pages/changelog/UpdateSurfaces.tsx#UpdateReadyHighlights"],
  load: async () => UpdateSurfacesGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
    await import("./updateSurfaces.css");
  },
  variants: {
    "popover-pr-links": {
      note: "Structured PR metadata on a leading change and a remaining change; both reuse the shared PR chip and card. Public PR titles, representative update data.",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll("a.cl-pr").length === 2);
        for (const chip of ctx.document.querySelectorAll<HTMLAnchorElement>("a.cl-pr")) {
          const box = chip.getBoundingClientRect();
          if (!chip.textContent?.match(/#\d+/) || box.width <= 0 || box.height <= 0) {
            throw new Error("The update-ready PR chip must have a visible number and nonzero size");
          }
          // A long title is cut before the chip, never the chip past the row's edge.
          const row = chip.closest(".wn-pop-text")?.getBoundingClientRect();
          if (row && (box.left < row.left - 0.5 || box.right > row.right + 0.5)) {
            throw new Error("The update-ready PR chip must show whole inside its row");
          }
        }
        await ctx.hover({ selector: ".wn-pop-list a.cl-pr" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-pr-card"));
      },
      props: {
        data: {
          ...base,
          items: [
            {
              id: "transcript-reading",
              category: "improved",
              title: "Let transcript reading surfaces follow chat text size",
              pr: "https://github.com/manaflow-ai/cmux/pull/26875",
            },
          ],
          rest: [
            {
              id: "inline-messages",
              category: "improved",
              title: "Other sessions' messages are one inline line each, then open when opened",
              pr: "https://github.com/manaflow-ai/cmux/pull/27312",
            },
          ],
          moreCount: 1,
        },
      },
    },
    "popover-compact": {
      note: "Leo 2026-11-05, on this hover card: \"this is too big / it's just oddly spaced and oddly rendered / and i can't even scroll through the changes from that preview!\" Picked: one heading line, version to version; every change of the update, the skipped nightlies too, each its title on one line and its line under it, cut to one line, the rest under New / Improved / Fixed; the list scrolls under the heading and above See all changes, both pinned; at most 360 px tall.",
      props: { data: leoData, span: leoSpan },
    },
    "popover-compact-one-line": {
      note: 'Variant: each change\'s line after its title on the same line. The most changes fit, but most lines are cut to a stub ("The or…", "Closing t…"), and a long title loses its line entirely.',
      props: { data: leoData, span: leoSpan, layout: "line" },
    },
    "popover-compact-flat": {
      note: "Variant: one line per change and no New / Improved / Fixed headings. The densest, but the kinds of change blur together and lines are still cut to stubs.",
      props: { data: leoData, span: leoSpan, layout: "flat" },
    },
    "popover-compact-dark": {
      note: "The picked layout in a dark theme.",
      props: { data: leoData, span: leoSpan, theme: "dark" },
    },
    "popover-compact-short-window": {
      note: "A window whose 60% is shorter than the cap (here 200 px): the list scrolls in less room; the heading and See all changes stay.",
      props: { data: leoData, span: leoSpan, maxHeight: 200 },
    },
    "popover-compact-one-change": {
      note: "Leo's update before the skipped nightlies' notes load: its one change on one line, the card as short as its content.",
      props: { data: leoData },
    },
    popover: {
      note: "The host's three highlights with their lines, +N more and See all changes; 340 pt wide.",
      props: { data: base },
    },
    "popover-wallpaper": {
      note: "The popup on a wallpaper: the popup surface stays solid (every cmux popup is).",
      props: { data: base, wallpaper: true },
    },
    "popover-media": {
      note: "A change with a screenshot: a thumbnail at the row's end; a click opens the notes, where it shows larger.",
      props: { data: withMedia },
    },
    "popover-scroll": {
      note: "Notes taller than the cap (60% of the window, here 260 px): the list scrolls in place with the wheel, the trackpad or the keys, and the popup stays open.",
      props: { data: longNotes, maxHeight: 260 },
    },
    "popover-titles-only": {
      note: "Summary-line source: titles without a second line.",
      props: {
        data: {
          ...base,
          source: "summary",
          date: null,
          moreCount: 0,
          items: base.items.map((i) => ({ ...i, summary: null })),
        },
      },
    },
    "popover-empty": {
      note: 'No highlights (source none), shipped (Leo 2026-11-03: "MAN this looks ugly... stretched out wasted space"): as wide as its lines, See release notes directly under the from line, no rule.',
      props: { data: { ...base, source: "none", items: [], moreCount: 0 } },
    },
    "popover-empty-inline": {
      note: "Variant: See release notes at the end of the from line, two lines in all.",
      props: { data: { ...base, source: "none", items: [], moreCount: 0 }, briefLayout: "inline" },
    },
    "popover-empty-title-row": {
      note: "Variant: See release notes at the end of the title line, the from line under both.",
      props: {
        data: { ...base, source: "none", items: [], moreCount: 0 },
        briefLayout: "title-row",
      },
    },
    "popover-empty-same-version": {
      note: "No highlights and no from line: the title and the link under it.",
      props: { data: { ...base, source: "none", items: [], moreCount: 0, fromVersion: "" } },
    },
  },
});
