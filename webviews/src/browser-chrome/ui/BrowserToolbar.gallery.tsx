// l10n-allow-file: gallery fixtures (sample pages), not shipped UI.
// The browser toolbar strip over sample pages, at the gallery's pane widths: narrow it to watch the
// native collapse order (trailing buttons into More, pinned extensions into the menu, then Forward).
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { BrowserToolbar, type BrowserToolbarProps, type OmnibarLook } from "./BrowserToolbar";
import { everyButton, secureOmnibar, toolbarProps } from "./fixtures";
import { resolveChip } from "./toolbarModel";

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
  covers: ["browser-chrome/ui/BrowserToolbar.tsx"],
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
