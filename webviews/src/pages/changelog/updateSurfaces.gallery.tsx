// l10n-allow-file: gallery fixtures (public-safe release notes from release-notes/next/highlights), not shipped UI.
// The Updated card and the update-ready highlights (cx-urd.61) on the app theme, at sidebar width.
// The card is liquid glass (.ui-glass), so each card state shows on a plain page and
// on a wallpaper (Leo 2026-10-13): the page is transparent over the wallpaper in the app.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import nightlySpan from "./fixtures/nightly-3913596493801-span.json";
import table from "./generated/strings.json";
import type { IndexEntry, ReleaseNotes } from "./types";
import type { UpdateHighlights } from "./updateHighlights";
import { UpdatedCard, UpdateReadyHighlights } from "./UpdateSurfaces";

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
  surface: "card" | "popover";
  data: UpdateHighlights;
  /** The notes of every build the update spans, as the card loads them from the host. */
  span?: ReleaseNotes[];
  /** The channel's published builds (the notes index), newest first. */
  builds?: IndexEntry[];
  wallpaper?: boolean;
  maxHeight?: number;
};

// Ten real nightly-next builds (2026-10-18), newest first, and what the host sent for the newest
// one alone: its one summary line, which the card used to show as its whole headline.
const span = nightlySpan as ReleaseNotes[];
const spanData: UpdateHighlights = {
  ...base,
  version: span[0]!.shortVersion,
  build: span[0]!.build,
  fromVersion: "1.0.0-nightly.3912500000000",
  fromBuild: "3912500000000",
  date: span[0]!.date,
  source: "summary",
  items: [{ id: "summary-0", title: "A static status look, on under Reduce Motion", summary: null, category: "new" }],
  moreCount: 0,
  changelog: { from: "1.0.0-nightly.3912500000000", to: span[0]!.shortVersion },
};
// Nightly 4037632091801 (2026-10-26) as published: its card read "Fixed: validate release headings
// within their day", a change to the release-notes checker (#25533).
const toolingLine = "Validate release headings within their day";
const releaseTooling: ReleaseNotes[] = [
  {
    build: "4037632091801",
    shortVersion: "1.0.0-nightly.4037632091801",
    date: "2026-10-26",
    highlights: [],
    changes: [],
    items: [
      {
        title: "cmux NEXT daemon update: restart a stale daemon without agent hosts that keeps its chats on disk",
        pr: 25527,
      },
      {
        title:
          "acpmux: a restart reattaches live agents first, then reads the other chats' logs in the background (1/2)",
        pr: 25531,
      },
      { title: "fix(changelog): validate release headings within their day", pr: 25533 },
    ],
    summary: [{ group: "fixed", title: toolingLine }],
  },
];
const releaseToolingData: UpdateHighlights = {
  ...base,
  version: "1.0.0-nightly.4037632091801",
  build: "4037632091801",
  fromVersion: "1.0.0-nightly.4037226096601",
  fromBuild: "4037226096601",
  date: "2026-10-26",
  source: "summary",
  items: [{ id: "summary-0", title: toolingLine, summary: null, category: "fixed" }],
  moreCount: 0,
  changelog: { from: "1.0.0-nightly.4037226096601", to: "1.0.0-nightly.4037632091801" },
};
// The notes index: two builds published after the base card's.
const behind: IndexEntry[] = ["3845900000001", "3845500000001", "3845050428001", "3844000000001"].map((build) => ({
  build,
  shortVersion: `1.0.0-nightly.${build}`,
  date: "2026-10-12",
  highlights: 0,
}));
const internalOnly: ReleaseNotes[] = [
  {
    ...span[0]!,
    highlights: [],
    whatsNew: undefined,
    summary: [],
    items: [{ title: "ci: shard the gallery capture" }, { title: "chore(next): base autofix at 659726b04ea9" }],
  },
];

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

// A stand-in wallpaper: a busy photo-like gradient, so the card's translucency shows.
const wallpaper = "linear-gradient(160deg, #3b5b7a 0%, #c98b5a 45%, #e7c9a0 60%, #2f4a3a 100%)";

function UpdateSurfacesGallery({
  surface,
  data,
  span: notes,
  builds,
  wallpaper: onWallpaper = false,
  maxHeight,
}: Props) {
  const [strings] = useState(() => createStrings(table));
  const noop = () => undefined;
  return (
    <div
      className="wn-gallery-stage"
      style={{
        width: surface === "card" ? 260 : 360,
        padding: 10,
        ...(onWallpaper ? { backgroundImage: wallpaper } : {}),
      }}
    >
      {surface === "card" ? (
        <UpdatedCard
          data={data}
          span={notes}
          builds={builds}
          strings={strings}
          actions={{ openChangelog: noop, dismiss: noop }}
        />
      ) : (
        <div
          style={{
            borderRadius: 8,
            background: "var(--page-elevated)",
            boxShadow: "0 0 0 1px var(--page-separator)",
            // The host's height cap (60% of the window): the popup scrolls in place.
            ...(maxHeight ? { maxHeight, overflowY: "auto" as const, overscrollBehavior: "contain" as const } : {}),
          }}
        >
          <UpdateReadyHighlights data={data} strings={strings} actions={{ openChangelog: noop }} />
        </div>
      )}
    </div>
  );
}

export default componentEntry<Props>({
  id: "pages.changelog.update-surfaces",
  title: "Updated card and update-ready highlights",
  area: "Pages",
  covers: [
    "pages/changelog/UpdateSurfaces.tsx#UpdatedCard",
    "pages/changelog/UpdateSurfaces.tsx#UpdateReadyHighlights",
  ],
  load: async () => UpdateSurfacesGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
    await import("./updateSurfaces.css");
  },
  variants: {
    card: {
      note: "Card #01 Compact list (u2441): \"Updated to Nightly · Oct 12\", what changed one line per area (updateSummary.ts), the count of the rest beside See What's New, the x on hover only. The composer's surface on a plain page. Without the span's notes the card groups the host's items.",
      props: { surface: "card", data: base },
    },
    "card-behind": {
      note: 'Leo 2026-10-26: "it just says updated to nightly, but that doesn\'t mean anything." The build by when it was made (local time) and its commit, and how far it is from the newest once the notes index loads.',
      props: { surface: "card", data: base, builds: behind },
    },
    "card-newest": {
      note: "The newest build of its channel.",
      props: { surface: "card", data: base, builds: behind.slice(2) },
    },
    "card-span": {
      note: "An update across ten skipped nightlies (real nightly-next notes, 2026-10-18): every build counts, one line per area, internal work left out, +N more. It used to show the newest build's one line as the whole card.",
      props: { surface: "card", data: spanData, span },
    },
    "card-span-wallpaper": {
      note: "The same on a wallpaper.",
      props: { surface: "card", data: spanData, span, wallpaper: true },
    },
    "card-release-tooling": {
      note: 'Nightly 4037632091801 as published (2026-10-26): its card read "Fixed: validate release headings within their day", a release-notes checker change. Release and changelog tooling is internal work.',
      props: { surface: "card", data: releaseToolingData, span: releaseTooling },
    },
    "card-release-tooling-host": {
      note: "The same update before its notes load: the host's one summary line.",
      props: { surface: "card", data: releaseToolingData },
    },
    "card-maintenance": {
      note: "An update whose builds hold only internal work (CI, autofixes): Maintenance and fixes, no count.",
      props: { surface: "card", data: { ...spanData, items: [], source: "none" }, span: internalOnly },
    },
    "card-wallpaper": {
      note: "The same card on a wallpaper: the liquid glass (.ui-glass); under plain glass the composer's surface, the text at 13% over it (Leo 2026-10-13).",
      props: { surface: "card", data: base, wallpaper: true },
    },
    "card-one-change": {
      note: "An update with one listed change and nothing more: no count.",
      props: { surface: "card", data: { ...base, items: base.items.slice(0, 1), moreCount: 0 } },
    },
    "card-no-highlights": {
      note: 'An update whose notes list nothing (source none): "What\'s new in this build", the button stays.',
      props: { surface: "card", data: { ...base, source: "none", items: [], moreCount: 0 } },
    },
    "card-no-highlights-wallpaper": {
      note: "The same on a wallpaper.",
      props: { surface: "card", data: { ...base, source: "none", items: [], moreCount: 0 }, wallpaper: true },
    },
    "card-long-title": {
      note: "A long localized change title ends in an ellipsis on its one line.",
      props: {
        surface: "card",
        data: {
          ...base,
          items: [
            {
              ...base.items[0]!,
              title: "Agents can use the cmux browser and computer use, with matching skills for Claude Code",
            },
          ],
        },
      },
    },
    popover: {
      note: 'Popover A, only what the Update Ready card lacks: a quiet "What\'s new in nightly 3845050" (the full build in its tooltip), the top three changes numbered in small tertiary type, +N more, See all changes once. Menu type, 340 pt wide (Leo 2026-10-19).',
      props: { surface: "popover", data: base },
    },
    "popover-wallpaper": {
      note: "The popup on a wallpaper: the popup surface stays solid (every cmux popup is).",
      props: { surface: "popover", data: base, wallpaper: true },
    },
    "popover-media": {
      note: "A change with a screenshot: the picture at the popover's width, inline with the text; a click opens the notes, where it shows larger.",
      props: { surface: "popover", data: withMedia },
    },
    "popover-scroll": {
      note: "Notes taller than the cap (60% of the window, here 260 px): the popup scrolls in place with the wheel or the trackpad and stays open.",
      props: { surface: "popover", data: longNotes, maxHeight: 260 },
    },
    "popover-titles-only": {
      note: "Summary-line source: titles without a second line.",
      props: {
        surface: "popover",
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
      note: "No highlights (source none): the full build and See all changes only.",
      props: { surface: "popover", data: { ...base, source: "none", items: [], moreCount: 0 } },
    },
  },
});
