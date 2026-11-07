// l10n-allow-file: gallery fixtures (sample pages), not shipped UI.
// The browser toolbar strip over sample pages, at the gallery's pane widths: narrow it to watch the
// native collapse order (trailing buttons into More, pinned extensions into the menu, then Forward).
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { TEXT } from "../../ui/designTokens.generated";
import { BrowserToolbar, type BrowserToolbarProps, type OmnibarLook } from "./BrowserToolbar";
import { everyButton, secureOmnibar, toolbarProps } from "./fixtures";
import { resolveChip, TOOLBAR_METRICS, type ToolbarRowMetrics } from "./toolbarModel";

type Props = Omit<BrowserToolbarProps, "onCommand"> & { look?: OmnibarLook };

function ToolbarFixture(props: Props) {
  const [open, setOpen] = useState(!!props.omnibar.pageInfoOpen);
  const [bookmark, setBookmark] = useState(props.omnibar.bookmark);
  return (
    <div style={{ paddingBlock: 8 }}>
      <BrowserToolbar
        {...props}
        omnibar={{ ...props.omnibar, pageInfoOpen: open, bookmark }}
        onCommand={(command) => {
          if (command.type === "pageInfo") setOpen((now) => !now);
          if (command.type === "bookmark") setBookmark((now) => (now === "on" ? "off" : "on"));
        }}
      />
    </div>
  );
}

// The row Leo flagged (2026-11-07): nothing to go back to, a secure page, the profile monogram, the
// star, the Extensions puzzle and More. The glyph variants draw it under each rule.
const flaggedRow = toolbarProps({
  navigation: { canGoBack: false, canGoForward: false, loading: false },
  omnibar: {
    text: "github.com/manaflow-ai/cmux/pull/37353",
    host: [0, "github.com".length],
    chip: resolveChip({ kind: "web", connection: "secure", displayName: "github.com" }),
    bookmark: "off",
  },
  badges: { profile: { monogram: "D", name: "Default" } },
  extensions: { shows: true, pinned: [] },
  buttons: [],
});

/** The Comfortable density as the host sends it (OmnibarMetrics at level 1: the title text step). */
const comfortable: ToolbarRowMetrics = {
  ...TOOLBAR_METRICS,
  bar: 34,
  button: 34,
  fontSize: TEXT.find((step) => step.name === "title")!.px,
  toolbarIcon: 22,
  trailingIcon: 20,
  chipIcon: 15,
  cornerRadius: 8,
};

const insecure = {
  kind: "web",
  connection: "insecure",
  displayName: "intranet.example.test:8080",
} as const;
const broken = {
  kind: "web",
  connection: "certificateError",
  displayName: "expired.example.org",
} as const;

export default componentEntry<Props>({
  id: "browser-chrome.toolbar",
  title: "Browser toolbar",
  area: "Browser chrome",
  experimental: true,
  height: 120,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  covers: ["browser-chrome/ui/BrowserToolbar.tsx", "browser-chrome/ui/toolbarGlyph.tsx"],
  keywords: ["omnibar", "address bar", "back", "reload", "bookmark star", "extensions"],
  load: async () => ToolbarFixture,
  options: [
    {
      id: "look",
      label: "Look",
      kind: "choice",
      choices: [
        { value: "flat", label: "Flat" },
        { value: "outlined", label: "Outlined" },
        { value: "capsule", label: "Capsule" },
      ],
      defaultValue: "flat",
    },
    {
      id: "glyphs",
      label: "Glyphs",
      kind: "choice",
      choices: [
        { value: "family", label: "One family (12.5)" },
        { value: "text", label: "Smaller omnibar (11.5)" },
        { value: "bold", label: "Bold (14)" },
      ],
      defaultValue: "family",
    },
  ],
  variants: {
    idle: {
      props: toolbarProps(),
      note: "Recommended look: today's flat bar. A download is running.",
    },
    "idle-outlined": {
      props: { ...toolbarProps(), look: "outlined" },
      note: "No fill at rest, a hairline edge.",
    },
    "idle-capsule": {
      props: { ...toolbarProps(), look: "capsule" },
      note: "Fully rounded bar and chip.",
    },
    "glyphs-family": {
      props: flaggedRow,
      note: "Recommended glyph rule: every glyph, the buttons and the omnibar's chip and star, at 12.5 px of ink with 1.5625 px lines (the app's icons at 20 px), centered on its box; the puzzle trimmed 6% for its filled body, the star grown 6% for its thin points; the monogram a 15 px disc. Before it the arrows drew 12 px, the chip 13, the star 14.4 and the puzzle 16, a pixel above the line.",
    },
    "glyphs-text": {
      props: { ...flaggedRow, glyphs: "text" },
      note: "The buttons as recommended; the chip and star a step smaller (11.5 px, 1.5 px lines), near the URL's cap height.",
    },
    "glyphs-bold": {
      props: { ...flaggedRow, glyphs: "bold" },
      note: "Every glyph at 14 px with 1.75 px lines and a 17 px monogram: Chrome's own heft in a 28 pt row.",
    },
    "glyphs-comfortable": {
      props: { ...flaggedRow, metrics: comfortable },
      note: "The recommended rule at the Comfortable density: 22 pt glyph boxes give 13.75 px of ink and 1.72 px lines.",
    },
    loading: {
      props: toolbarProps({
        navigation: { canGoBack: true, canGoForward: true, loading: true, progress: 0.35 },
      }),
      note: "Stop in place of Reload, the progress line under the row.",
    },
    editing: {
      props: toolbarProps({
        omnibar: {
          text: "https://docs.example.com/guide/getting-started",
          chip: resolveChip(null, true, "browser.omnibox.search"),
          bookmark: "off",
          editing: true,
        },
      }),
      note: "Focused: the full address, the neutral ring, the chip describes the input.",
    },
    insecure: {
      props: toolbarProps({
        omnibar: {
          text: "http://intranet.example.test:8080/status",
          host: [7, 7 + "intranet.example.test:8080".length],
          chip: resolveChip(insecure),
          bookmark: "off",
        },
      }),
    },
    "certificate-error": {
      props: toolbarProps({
        omnibar: {
          text: "expired.example.org",
          host: [0, "expired.example.org".length],
          chip: resolveChip(broken),
          bookmark: "hidden",
        },
      }),
      note: "The danger ink on the chip; no star on an error page.",
    },
    "page-info-open": {
      props: toolbarProps({ omnibar: { ...secureOmnibar, pageInfoOpen: true, bookmark: "on" } }),
      note: "The chip keeps its pressed fill while the bubble is open; a bookmarked page.",
    },
    "every-button": {
      props: toolbarProps({ buttons: everyButton }),
      note: "Every pinned button. Narrow the pane: design mode and DevTools go first.",
    },
    "narrow-collapsed": {
      props: toolbarProps({ buttons: everyButton, width: 300 }),
      note: "300 pt: buttons in More, extensions in the menu, Forward hidden.",
    },
    "internal-page": {
      props: toolbarProps({
        omnibar: {
          text: "cmux://settings",
          chip: resolveChip({ kind: "internalPage", displayName: "cmux://settings" }),
          bookmark: "hidden",
        },
        extensions: { shows: false, pinned: [] },
        buttons: [],
      }),
    },
    empty: {
      props: toolbarProps({
        navigation: { canGoBack: false, canGoForward: false, loading: false },
        omnibar: { text: "", chip: resolveChip(null), bookmark: "hidden" },
        buttons: [],
      }),
      note: "A new tab: the placeholder, nothing to go back to.",
    },
  },
});
