// l10n-allow-file: gallery fixtures (public-safe release notes from release-notes/next/highlights), not shipped UI.
// The Updated card and the update-ready highlights (cx-urd.61) on the app theme, at sidebar width.
// The card is liquid glass (.ui-glass), so each card state shows on a plain page and
// on a wallpaper (Leo 2026-10-13): the page is transparent over the wallpaper in the app.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import nightlySpan from "./fixtures/nightly-3913596493801-span.json";
import table from "./generated/strings.json";
import type { ReleaseNotes } from "./types";
import type { UpdateHighlights } from "./updateHighlights";
import {
  UpdatedCard,
  UpdateReadyHighlights,
  type BriefLayout,
  type PreviewLayout,
  type ReadyLayout,
  type WhatsNewPlacement,
} from "./UpdateSurfaces";
import { UpdatedNotes, type NotesLook } from "./UpdatedNotes";

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
  surface: "card" | "popover" | "notes";
  data: UpdateHighlights;
  /** The notes of every build the update spans, as the card loads them from the host. */
  span?: ReleaseNotes[];
  wallpaper?: boolean;
  maxHeight?: number;
  /** The card in one theme's tokens over that theme's sidebar (Leo 2026-11-02: "why is the update
   *  thing unthemed"): a light, a dark and a custom (purple) theme. */
  theme?: keyof typeof themes;
  /** Where the popover with no change list puts See release notes. */
  briefLayout?: BriefLayout;
  /** How the popover with a change list lays out a change. */
  layout?: ReadyLayout;
  /** The decoration in the card's slot (ThemeDecorations `updated-card`): "doodle", else none. */
  decoration?: string | null;
  /** The doodle draws on (false: drawn from the start). */
  animate?: boolean;
  /** The stage's width (the sidebar's), default 260. */
  width?: number;
  /** Where the card puts What's New (Leo 2026-11-07); `title` ships. */
  placement?: WhatsNewPlacement;
  /** The card's hover preview held open (the still of a pointer resting on the card). */
  previewOpen?: boolean;
  /** How the open preview is laid out (Lawrence 2026-11-07); `header` ships. */
  previewLayout?: PreviewLayout;
  /** A one-line composer box beside the card, its edges lined up, as in the window. */
  besideComposer?: boolean;
  /** Sidebar rows under the card, as its open preview stands over them in the sidebar: frosted by the
   *  card's glass (`glass`, what the host's native glass draws), seen through the page's tint alone
   *  (`tint`, no frost), or hidden under the solid surface the card painted before (`solid`). */
  overRows?: "glass" | "tint" | "solid";
  /** How the Updated card's changes beside the sidebar stand (UpdatedNotes); `sections` ships. */
  notesLook?: NotesLook;
};

// Three themes as WebTheme sends them (the page's --page-* and the glass's surface), each over its
// own sidebar color, so the card's surface shows it takes the theme and not a neutral gray.
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

// Ten real nightly-next builds (2026-10-18), newest first, and what the host sent for the newest
// one alone: its one summary line, which the card used to show as its whole headline.
const span = nightlySpan as ReleaseNotes[];
const lawrenceShot: UpdateHighlights = {
  version: "1.0.0-nightly.4241815985601",
  build: "4241815985601",
  fromVersion: "1.0.0-nightly.4230000000001",
  fromBuild: "4230000000001",
  source: "whatsNew",
  language: "en",
  items: [
    { id: "dictation", title: "Show when another app is dictating into a chat", summary: null, category: "new" },
    {
      id: "new-tab",
      title: "New Browser Tab always opens a blank page beside the current one",
      summary: null,
      category: "improved",
    },
    { id: "tool-calls", title: "Show grouped tool calls as an iOS-style stack", summary: null, category: "improved" },
    { id: "pins", title: "Pinned rows line up under Home's icon", summary: null, category: "fixed" },
  ],
  moreCount: 0,
  changelog: { from: "1.0.0-nightly.4230000000001", to: "1.0.0-nightly.4241815985601" },
};
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

/** The doodle's face has loaded (doodleFont.ts): a still shows the handwriting, not its fallback. */
function doodleFontLoaded(doc: Document): boolean {
  let loaded = false;
  doc.fonts.forEach((face) => {
    if (face.family.replaceAll('"', "") === "cmux-doodle" && face.status === "loaded") loaded = true;
  });
  return loaded;
}

// A stand-in wallpaper: a busy photo-like gradient, so the card's translucency shows.
const wallpaper = "linear-gradient(160deg, #3b5b7a 0%, #c98b5a 45%, #e7c9a0 60%, #2f4a3a 100%)";

/** A one-line composer box in the composer's material and size (the agent pane's own box needs the
    whole agent session around it): its placeholder and +, so the two surfaces compare edge to edge. */
function ComposerStandIn() {
  return (
    <div
      data-composer-material=""
      style={{
        flex: 1,
        display: "flex",
        alignItems: "center",
        gap: 8,
        boxSizing: "border-box",
        height: "var(--composer-material-height)",
        padding: "0 8px",
        borderRadius: "var(--composer-material-radius)",
        background: "var(--composer-material-tint)",
        boxShadow: "var(--composer-material-ring), var(--composer-material-rim)",
        color: "var(--page-text-3)",
        fontSize: "var(--text-content)",
      }}
    >
      <span style={{ width: 28, textAlign: "center", fontSize: "var(--text-title)" }}>+</span>
      <span>Type / for commands</span>
    </div>
  );
}

/** The sidebar's workspace rows the open preview stands over, in the stage behind the card. */
function RowsStandIn() {
  const rows = [
    "cmux-next",
    "web: what's new",
    "fleet build",
    "release notes",
    "sidebar polish",
    "agent chat",
    "docs",
    "nightly",
  ];
  return (
    <div
      aria-hidden="true"
      style={{
        position: "absolute",
        inset: "calc(var(--grid-base, 4px) * 3) calc(var(--grid-base, 4px) * 3) calc(var(--grid-base, 4px) * 18)",
        display: "grid",
        alignContent: "end",
        gap: "var(--grid-base, 4px)",
      }}
    >
      {rows.map((name, index) => (
        <div
          key={name}
          style={{
            display: "flex",
            alignItems: "center",
            gap: 8,
            height: 30,
            padding: "0 8px",
            borderRadius: 6,
            background: index === 5 ? "var(--page-hover)" : undefined,
            color: "var(--page-text)",
            fontSize: "var(--text-content)",
          }}
        >
          <span
            style={{
              width: 8,
              height: 8,
              borderRadius: 4,
              background: ["#e5534b", "#57ab5a", "#539bf5", "#c69026"][index % 4],
            }}
          />
          {name}
        </div>
      ))}
    </div>
  );
}

function UpdateSurfacesGallery({
  surface,
  data,
  span: notes,
  wallpaper: onWallpaper = false,
  maxHeight,
  theme,
  briefLayout,
  layout,
  decoration = null,
  animate = false,
  width,
  placement,
  previewOpen,
  previewLayout,
  besideComposer = false,
  overRows,
  notesLook,
}: Props) {
  const [strings] = useState(() => createStrings(table));
  const noop = () => undefined;
  return (
    <div
      className="wn-gallery-stage"
      style={{
        width: width ?? (surface === "card" ? 260 : surface === "notes" ? 360 : 360),
        padding: 10,
        ...(onWallpaper ? { backgroundImage: wallpaper } : {}),
        ...(theme ? themeStyle(theme) : {}),
        ...(overRows ? { position: "relative" as const, height: 420, display: "flex", alignItems: "flex-end" } : {}),
      }}
    >
      {overRows && <RowsStandIn />}
      {surface === "notes" ? (
        <div
          style={{
            // The hover card window beside the sidebar: 340 wide, at most 60% of a short window here
            // so the list scrolls (SidebarUpdatedNotesPopover.maxHeightFraction).
            width: 340,
            display: "flex",
            flexDirection: "column",
            maxHeight: maxHeight ?? 420,
            borderRadius: 8,
            background: "var(--page-elevated)",
            boxShadow: "0 0 0 1px var(--page-separator)",
            overflow: "hidden",
          }}
        >
          <UpdatedNotes
            data={data}
            span={notes}
            strings={strings}
            actions={{ openChangelog: noop, dismiss: noop }}
            look={notesLook}
          />
        </div>
      ) : surface === "card" ? (
        <div
          className="wn-gallery-card-row"
          style={
            besideComposer
              ? { display: "flex", alignItems: "flex-end", gap: 12 }
              : overRows
                ? {
                    position: "relative",
                    width: "100%",
                    // The card painted the solid surface over the rows before (a72c0fd5c542, f1d36c5f77e3).
                    ...(overRows === "solid" ? { "--composer-material-tint": "var(--composer-material-solid)" } : {}),
                  }
                : undefined
          }
        >
          <div style={besideComposer ? { flex: "0 0 236px" } : undefined}>
            <UpdatedCard
              data={data}
              span={notes}
              strings={strings}
              actions={{ openChangelog: noop, dismiss: noop }}
              decoration={decoration}
              animate={animate}
              placement={placement}
              previewOpen={previewOpen}
              glass={overRows ? overRows === "glass" : undefined}
              previewLayout={previewLayout}
              // The held-open preview stills show the in-card list (the look before the popover).
              previewMode={previewOpen === undefined ? undefined : "above"}
            />
          </div>
          {besideComposer && <ComposerStandIn />}
        </div>
      ) : (
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
    "pages/changelog/UpdatedCardPreview.tsx#UpdatedCardPreview",
    "pages/changelog/UpdatedNotes.tsx#UpdatedNotes",
  ],
  load: async () => UpdateSurfacesGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
    await import("../../ui/glass/composerMaterial.css");
    await import("./updateSurfaces.css");
  },
  variants: {
    "notes-sections": {
      note: "Picked and shipped (Leo 2026-11-08: \"the sections should be more obvious what's what ... distinguishing which row does what is unclear ... unclear whether you can even scroll down and why\"): the Updated card's changes beside the sidebar under What's New's own area headers (glyph, name, count, in its order), each change one pill with a gap between, and a count of the changes still below while some are. A click opens What's New at that change. Chosen over hairlines because the gap separates pills without adding lines inside the glass.",
      props: { surface: "notes", data: spanData, span, theme: "dark" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".wn-notes-area").length > 1);
        await ctx.waitFor(() => ctx.document.querySelector(".wn-notes-more") !== null);
      },
    },
    "notes-sections-light": {
      note: "The shipped look in the light theme.",
      props: { surface: "notes", data: spanData, span, theme: "light" },
    },
    "notes-divided": {
      note: "Variant: the same headers, rows divided by hairlines instead of gaps between pills.",
      props: { surface: "notes", data: spanData, span, theme: "dark", notesLook: "divided" },
    },
    "notes-flat": {
      note: "Before: one flat list with no areas; the rows run together and nothing says the list goes on.",
      props: { surface: "notes", data: spanData, span, theme: "dark", notesLook: "flat" },
    },
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
        surface: "popover",
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
    card: {
      note: "Picked and shipped (Leo 2026-11-07: \"just update it to Nightly, and then What's New with the up and to the right arrow that you can click as a thing\"): \"Updated to Nightly · What's New ↗\" on one line over the top change, in the composer's material at the composer's one-line height (48) and corner. Chosen over What's New at the line's far end because it reads as one sentence, keeps the link beside the words it belongs to, and leaves the line's end free for the x that shows on hover, so nothing shifts when it does. The freed button row is the height the card gives back. The x on hover only; a click on Nightly copies the full build.",
      props: { surface: "card", data: base, theme: "dark" },
    },
    "card-whats-new-top-right": {
      note: "Variant: What's New ↗ at the far end of the title line, beside the x's room. It lines up with the x, but in a narrow sidebar the title and the link meet in the middle, and the x that shows on hover crowds the link.",
      props: { surface: "card", data: base, theme: "dark", placement: "top-right" },
    },
    "card-whats-new-button": {
      note: "Before (the look Leo flagged on 2026-11-07, in the new material): the What's New button on its own row under the note. The card is taller than the composer beside it and the button row is mostly empty.",
      props: { surface: "card", data: base, theme: "dark", placement: "button" },
    },
    "card-beside-composer": {
      note: 'The shipped card beside a one-line composer box in the same material: one height (48), one corner, one edge and one fill (Leo 2026-11-07: "it becomes the exact same height as the composer").',
      props: { surface: "card", data: base, theme: "dark", besideComposer: true, width: 640 },
    },
    "card-beside-composer-light": {
      note: "The same in a light theme.",
      props: { surface: "card", data: base, theme: "light", besideComposer: true, width: 640 },
    },
    "card-hover-preview": {
      note: "Shipped (header): resting on the card for the hover dwell (400 ms) opens the update's changes in the card's own glass (Leo 2026-11-07: \"a quick access scroll through of what's new\"). Lawrence 2026-11-07, \"this ui is very bad\": the header leads, whole (Updated to Nightly with the x, the full version, What's New), then the changes, each title on up to two lines with its detail; more rows show the scrollbar, not a faded row. A click on a row or on What's New opens the full page; Escape or leaving the card closes it.",
      props: { surface: "card", data: spanData, span, theme: "dark", previewOpen: true },
    },
    "card-hover-preview-lawrence": {
      note: "Lawrence's shot (2026-11-07) in the shipped header layout: the three changes whose titles were cut, at the sidebar's width.",
      props: { surface: "card", data: lawrenceShot, theme: "dark", previewOpen: true },
    },
    "card-hover-preview-lawrence-light": {
      note: "The same in a light theme.",
      props: { surface: "card", data: lawrenceShot, theme: "light", previewOpen: true },
    },
    "card-hover-preview-header-bottom": {
      note: "Variant: the same parts with the header kept at the card's resting edge, under the pointer, and the changes above it (the order before).",
      props: { surface: "card", data: lawrenceShot, theme: "dark", previewOpen: true, previewLayout: "header-bottom" },
    },
    "card-hover-preview-titles": {
      note: "Variant: the header leads and the changes are their titles alone, on up to three lines.",
      props: { surface: "card", data: lawrenceShot, theme: "dark", previewOpen: true, previewLayout: "titles" },
    },
    "card-hover-preview-light": {
      note: "The open preview in a light theme, from the host's own items (before the span's notes load).",
      props: { surface: "card", data: base, theme: "light", previewOpen: true },
    },
    "card-hover-preview-top-right": {
      note: "The open preview with the top-right What's New variant.",
      props: { surface: "card", data: spanData, span, theme: "dark", placement: "top-right", previewOpen: true },
    },
    "card-preview-over-rows": {
      note: "Shipped (Leo 2026-11-08: \"I feel like we should be able to keep it as glass though, right?\"): the open preview over the sidebar's rows stays the card's glass. The host draws a native glass behind the page that frosts the rows, so the rows read as moving shapes, not words, and the card has the same fill open and at rest (the fill swap was the flicker). The glass follows the preview on the card's curve, cubic-bezier(0.16, 1, 0.3, 1) over 180 ms.",
      props: { surface: "card", data: spanData, span, theme: "dark", previewOpen: true, overRows: "glass" },
    },
    "card-preview-over-rows-light": {
      note: "Shipped, in a light theme.",
      props: { surface: "card", data: spanData, span, theme: "light", previewOpen: true, overRows: "glass" },
    },
    "card-preview-scrolled": {
      note: "Shipped: the open list scrolls in place, and the glass frosts the rows under it while it does.",
      play: async (ctx) => {
        const list = () => ctx.document.querySelector<HTMLElement>(".wn-preview-list");
        await ctx.waitFor(() => (list()?.scrollHeight ?? 0) > (list()?.clientHeight ?? 0));
        const scroller = list()!;
        scroller.scrollTop = Math.round((scroller.scrollHeight - scroller.clientHeight) / 2);
        if (scroller.scrollTop <= 0) throw new Error("The open preview's list must scroll");
      },
      props: { surface: "card", data: spanData, span, theme: "dark", previewOpen: true, overRows: "glass" },
    },
    "card-preview-over-rows-tint": {
      note: 'Rejected: the tint alone, with no frost under it (what the page paints over native rows when the host draws no glass). Every row stays legible through the list (Lawrence 2026-11-07: "this ui transparency looks bad now").',
      props: { surface: "card", data: spanData, span, theme: "dark", previewOpen: true, overRows: "tint" },
    },
    "card-preview-over-rows-solid": {
      note: 'Before (a72c0fd5c542, f1d36c5f77e3): the open preview turned solid over the rows, so the card swapped from glass to opaque as it opened (Leo 2026-11-08: "it turns from glass when it\'s unhovered into opaque when it does get hovered").',
      props: { surface: "card", data: spanData, span, theme: "dark", previewOpen: true, overRows: "solid" },
    },
    "card-doodle": {
      note: 'Leo 2026-11-05, on the Yab browser\'s after-update note: "They have that little line thing, which is kind of cutesy quirky." The doodle in the card\'s decoration slot (Debug Settings "Doodle on the Updated card", off by default): "you\'re on nightly 3845050!" with a check, a curved arrow from "have a look" to What\'s New with a loop around it, and "got it" (hides the card for this version, as its x does). Drawn, on a light theme.',
      play: async (ctx) => {
        await ctx.waitFor(() => doodleFontLoaded(ctx.document));
      },
      props: { surface: "card", data: base, decoration: "doodle", theme: "light" },
    },
    "card-doodle-dark": {
      note: "The doodle on a dark theme: the marker ink lightens, as a felt pen reads on a slate.",
      play: async (ctx) => {
        await ctx.waitFor(() => doodleFontLoaded(ctx.document));
      },
      props: { surface: "card", data: base, decoration: "doodle", theme: "dark" },
    },
    "card-doodle-narrow": {
      note: "The doodle in the narrowest sidebar (160 pt: the card is 136 wide): the arrow and its words wrap under the circled What's New, so nothing runs past the card.",
      play: async (ctx) => {
        await ctx.waitFor(() => doodleFontLoaded(ctx.document));
        const card = ctx.document.querySelector(".wn-card")!.getBoundingClientRect();
        for (const part of ctx.document.querySelectorAll(".wn-doodle-circled, .wn-doodle-pointer, .wn-doodle-words")) {
          const box = part.getBoundingClientRect();
          if (box.right > card.right + 0.5)
            throw new Error(`${part.className} runs past the card (${box.right} > ${card.right})`);
        }
      },
      props: { surface: "card", data: base, decoration: "doodle", theme: "light", width: 160 },
    },
    "card-doodle-draw": {
      note: "The doodle drawing on, as it does when the card first shows (about a second and a quarter; under Reduce Motion it is simply there).",
      play: async (ctx) => {
        // The still is the drawn end state: every stroke and word has finished drawing on.
        await ctx.waitFor(() => ctx.document.querySelector('.wn-doodle[data-phase="drawing"]'));
        await ctx.waitFor(() => ctx.document.getAnimations().length === 0, { capMs: 4000 });
      },
      props: { surface: "card", data: base, decoration: "doodle", theme: "light", animate: true },
    },
    "card-background": {
      note: 'An automatic install that relaunched cmux behind another app (nobody clicked Restart to Update): "Updated to Nightly in the background", so the card does not seem to come without a restart (2026-11-03).',
      props: { surface: "card", data: { ...base, delivery: "background" } },
    },
    "card-theme-light": {
      note: "Leo 2026-11-02, \"why is the update thing unthemed\": the card's surface is the theme's (since 2026-11-07 the composer's material, which derives from the theme's surface), here a light theme over its sidebar.",
      props: { surface: "card", data: base, theme: "light" },
    },
    "card-theme-dark": {
      note: "The same in a dark theme.",
      props: { surface: "card", data: base, theme: "dark" },
    },
    "card-theme-custom": {
      note: "The same in a custom purple theme: the card takes the theme's purple, never a neutral gray over it.",
      props: { surface: "card", data: base, theme: "purple" },
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
      note: "The same card on a wallpaper: the composer's material, frosting what is behind it as the composer does over art.",
      props: { surface: "card", data: base, wallpaper: true },
    },
    "card-one-change": {
      note: "An update with one listed change and nothing more: no count.",
      props: { surface: "card", data: { ...base, items: base.items.slice(0, 1), moreCount: 0 } },
    },
    "card-no-highlights": {
      note: "An update whose notes list nothing (source none): \"What's new in this build\"; What's New stays on the title line.",
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
    "popover-compact": {
      note: "Leo 2026-11-05, on this hover card: \"this is too big / it's just oddly spaced and oddly rendered / and i can't even scroll through the changes from that preview!\" Picked: one heading line, version to version; every change of the update, the skipped nightlies too, each its title on one line and its line under it, cut to one line, the rest under New / Improved / Fixed; the list scrolls under the heading and above See all changes, both pinned; at most 360 px tall.",
      props: { surface: "popover", data: leoData, span: leoSpan },
    },
    "popover-compact-one-line": {
      note: 'Variant: each change\'s line after its title on the same line. The most changes fit, but most lines are cut to a stub ("The or…", "Closing t…"), and a long title loses its line entirely.',
      props: { surface: "popover", data: leoData, span: leoSpan, layout: "line" },
    },
    "popover-compact-flat": {
      note: "Variant: one line per change and no New / Improved / Fixed headings. The densest, but the kinds of change blur together and lines are still cut to stubs.",
      props: { surface: "popover", data: leoData, span: leoSpan, layout: "flat" },
    },
    "popover-compact-dark": {
      note: "The picked layout in a dark theme.",
      props: { surface: "popover", data: leoData, span: leoSpan, theme: "dark" },
    },
    "popover-compact-short-window": {
      note: "A window whose 60% is shorter than the cap (here 200 px): the list scrolls in less room; the heading and See all changes stay.",
      props: { surface: "popover", data: leoData, span: leoSpan, maxHeight: 200 },
    },
    "popover-compact-one-change": {
      note: "Leo's update before the skipped nightlies' notes load: its one change on one line, the card as short as its content.",
      props: { surface: "popover", data: leoData },
    },
    popover: {
      note: "The host's three highlights with their lines, +N more and See all changes; 340 pt wide.",
      props: { surface: "popover", data: base },
    },
    "popover-wallpaper": {
      note: "The popup on a wallpaper: the popup surface stays solid (every cmux popup is).",
      props: { surface: "popover", data: base, wallpaper: true },
    },
    "popover-media": {
      note: "A change with a screenshot: a thumbnail at the row's end; a click opens the notes, where it shows larger.",
      props: { surface: "popover", data: withMedia },
    },
    "popover-scroll": {
      note: "Notes taller than the cap (60% of the window, here 260 px): the list scrolls in place with the wheel, the trackpad or the keys, and the popup stays open.",
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
      note: 'No highlights (source none), shipped (Leo 2026-11-03: "MAN this looks ugly... stretched out wasted space"): as wide as its lines, See release notes directly under the from line, no rule.',
      props: { surface: "popover", data: { ...base, source: "none", items: [], moreCount: 0 } },
    },
    "popover-empty-inline": {
      note: "Variant: See release notes at the end of the from line, two lines in all.",
      props: { surface: "popover", data: { ...base, source: "none", items: [], moreCount: 0 }, briefLayout: "inline" },
    },
    "popover-empty-title-row": {
      note: "Variant: See release notes at the end of the title line, the from line under both.",
      props: {
        surface: "popover",
        data: { ...base, source: "none", items: [], moreCount: 0 },
        briefLayout: "title-row",
      },
    },
    "popover-empty-same-version": {
      note: "No highlights and no from line: the title and the link under it.",
      props: { surface: "popover", data: { ...base, source: "none", items: [], moreCount: 0, fromVersion: "" } },
    },
  },
});
