// l10n-allow-file: gallery fixtures, not shipped UI.
// Shortcut keycaps in buttons (shortcut-keycaps experiment, off by default): the header New
// button's face and the New Tab page's All Chats, each drawing its shortcut inside itself. The
// header quick tools are left to the glass toolbar's capsule (#47172). The arms
// are pinned through ShortcutKeycapLookContext; the keycaps come from ShortcutsContext as the host
// pushes them (applyShortcuts), so the rebound variant shows a rebind with no other change.
import type React from "react";
import { componentEntry } from "../../gallery/format";
import { HEADER_ACTIONS } from "./header/headerActions";
import { HeaderNewButton } from "./header/HeaderNewButton";
import { ChatCards } from "./newtab/ChatCards";
import type { ChatCard } from "./newtab/screenModel";
import { ShortcutKeycapLookContext } from "./shortcutKeycaps";
import type { ShortcutKeycapLook } from "./shortcutKeycaps.experiment";
import { SHORTCUT_ACTIONS, ShortcutsContext, type ShortcutLabels } from "./shortcuts";

type Palette = "light" | "dark";
type Props = { look: ShortcutKeycapLook; palette: Palette; labels?: ShortcutLabels };

/// The default bindings as the host pushes them.
const DEFAULTS: ShortcutLabels = {
  [HEADER_ACTIONS.terminal]: "⌘D",
  [SHORTCUT_ACTIONS.searchChats]: "⌘K ⌘J",
};

/// The same actions after the person rebinds them in Settings: the buttons follow at once.
const REBOUND: ShortcutLabels = {
  ...DEFAULTS,
  [HEADER_ACTIONS.terminal]: "⌃⌥T",
  [SHORTCUT_ACTIONS.searchChats]: "⇧⌘O",
};

const PALETTES: Record<Palette, React.CSSProperties> = {
  light: {
    "--agent-text": "#1d1d1f",
    "--agent-muted": "rgba(29, 29, 31, 0.6)",
    "--agent-soft": "rgba(29, 29, 31, 0.35)",
    "--acpmux-composer-dim": "rgba(29, 29, 31, 0.6)",
    colorScheme: "light",
    background: "#ffffff",
    color: "#1d1d1f",
  } as React.CSSProperties,
  dark: {
    "--agent-text": "#f2f2f2",
    "--agent-muted": "rgba(242, 242, 242, 0.62)",
    "--agent-soft": "rgba(242, 242, 242, 0.35)",
    "--acpmux-composer-dim": "rgba(242, 242, 242, 0.62)",
    colorScheme: "dark",
    background: "#1e1e22",
    color: "#f2f2f2",
  } as React.CSSProperties,
};

const noop = () => undefined;

const CARDS: ChatCard[] = [
  { sessionId: "a", title: "Fix the flaky upload test", harness: "claude", age: "2m", state: "idle", message: "Done." },
];

function KeycapButtons({ look, palette, labels = DEFAULTS }: Props) {
  return (
    <ShortcutKeycapLookContext value={look}>
      <ShortcutsContext value={labels}>
        <div
          className="acpmux-shell"
          data-keycaps-fixture
          style={{ flexDirection: "column", gap: 16, padding: 16, ...PALETTES[palette] }}
        >
          <div className="acpmux-header" style={{ display: "flex", justifyContent: "flex-end", gap: 8 }}>
            <HeaderNewButton kinds={["terminal", "browser", "sideChat", "newTab"]} make={noop} initialLast="terminal" />
          </div>
          <ChatCards cards={CARDS} onOpen={noop} onShowAll={noop} />
        </div>
      </ShortcutsContext>
    </ShortcutKeycapLookContext>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.shortcut-keycaps",
  title: "Shortcut keycaps in buttons (experiment)",
  area: "Agent pane",
  experimental: true,
  height: 220,
  widths: { narrow: 320, normal: 560 },
  anchors: [{ selector: "[data-keycaps-fixture]" }],
  covers: [
    "agent-session/acpmux/ButtonKeycaps.tsx#ShortcutKeycaps",
    "agent-session/acpmux/header/HeaderNewButton.tsx#HeaderNewButton",
    "agent-session/acpmux/newtab/ChatCards.tsx#ChatCards",
  ],
  styles: () =>
    Promise.all([
      import("./styles.css"),
      import("./keys.css"),
      import("./header/header.css"),
      import("./newtab/screen.css"),
    ]),
  load: async () => KeycapButtons,
  variants: {
    off: {
      props: { look: "off", palette: "light" },
      note: "Off (the default, today): New and All Chats with no keycaps; the shortcut is in the tooltip only.",
    },
    light: {
      props: { look: "filled", palette: "light" },
      note: "Filled caps on a light theme: one tinted cap per key, joined into one shape per stroke; New grows to fit.",
    },
    dark: {
      props: { look: "filled", palette: "dark" },
      note: "Filled caps on a dark theme: tinted from the button's own ink, so the caps follow any theme.",
    },
    compact: {
      props: { look: "compact", palette: "light" },
      note: "Compact: the whole shortcut in one small cap, as menus write it (⇧⌘D).",
    },
    outlined: {
      props: { look: "outlined", palette: "dark" },
      note: "Outlined: a hairline cap per key with no fill; quieter on a dark theme.",
    },
    rebound: {
      props: { look: "filled", palette: "light", labels: REBOUND },
      note: "After a rebind (New terminal ⌃⌥T, All Chats ⇧⌘O): the host pushes the new keys and the caps follow.",
    },
  },
});
