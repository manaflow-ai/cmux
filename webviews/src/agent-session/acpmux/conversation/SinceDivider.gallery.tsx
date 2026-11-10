// l10n-allow-file: gallery fixtures (sample recaps and replies), not shipped UI.
// The unread marker's looks (SinceDivider.tsx; design/transcript-overlays.md), each between the
// reply the person had seen and the turns that ended while they were away, in three themes: light,
// dark, and a dark theme over a background image (the pane's glass over a wallpaper). The palettes
// stand in for what the app's applyTheme sets (--cmux-app-* from cmux-theme-tokens app_theme.rs):
// the component reads only those tokens. References: chat apps' unread line (a rule with a NEW
// tag at its end) and the accent "New" line. The way to it is the transcript's one jump control,
// in the whole pane: agent-pane.unread-marker and agent-pane.jump-control.
import type React from "react";
import { componentEntry } from "../../../gallery/format";
import wallpaper from "../../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { SinceDivider, type SinceLook } from "./SinceDivider";

type Theme = "light" | "dark" | "image";

// Apple System Colors, the app's default theme pair (gallery/theme/ghostty DEFAULT_*_THEME).
const THEMES: Record<Theme, React.CSSProperties> = {
  light: {
    "--agent-text": "#1d1d1f",
    "--agent-muted": "rgba(29, 29, 31, 0.6)",
    "--agent-page-bg": "#ffffff",
    "--cmux-app-accent": "#007aff",
    "--cmux-app-on-accent": "#ffffff",
    "--cmux-app-accent-text": "#0068d9",
    colorScheme: "light",
    background: "#ffffff",
  } as React.CSSProperties,
  dark: {
    "--agent-text": "#f2f2f7",
    "--agent-muted": "rgba(242, 242, 247, 0.62)",
    "--agent-page-bg": "#1c1c1e",
    "--cmux-app-accent": "#0a84ff",
    "--cmux-app-on-accent": "#ffffff",
    "--cmux-app-accent-text": "#4ea1ff",
    colorScheme: "dark",
    background: "#1c1c1e",
  } as React.CSSProperties,
  image: {
    "--agent-text": "#f2f2f7",
    "--agent-muted": "rgba(242, 242, 247, 0.7)",
    "--agent-page-bg": "rgba(28, 28, 30, 0.35)",
    "--cmux-app-accent": "#0a84ff",
    "--cmux-app-on-accent": "#ffffff",
    "--cmux-app-accent-text": "#6cb2ff",
    colorScheme: "dark",
    background: `url("${wallpaper}") center / cover`,
  } as React.CSSProperties,
};

const RECAP =
  "The parser in foo.rs now tolerates missing fields and its tests pass. Next: run the fuzz corpus and open the PR.";

function Reply({ text }: { text: string }) {
  return <p style={{ margin: 0, color: "var(--agent-text)", lineHeight: "20px" }}>{text}</p>;
}

type Props = {
  theme: Theme;
  look?: SinceLook;
  read?: boolean;
  recap?: boolean;
};

function UnreadLooks({ theme, look = "tag", read = false, recap = true }: Props) {
  return (
    <div
      className="acpmux-shell"
      style={{ ...THEMES[theme], position: "relative", padding: 16, display: "grid", gap: 16, minHeight: "100%" }}
    >
      <Reply text="I'll start by reading foo.rs to see how absent fields fail." />
      <SinceDivider
        since={{
          key: `gallery-${theme}-${look}:41`,
          seq: 41,
          turns: 3,
          ...(recap && { recap: { key: `gallery-${theme}-${look}`, text: RECAP, awayMs: 38 * 60_000 } }),
        }}
        onDismissRecap={() => {}}
        look={look}
        read={read}
      />
      <Reply text="Missing fields now default instead of failing; I added a test for each one." />
      <Reply text="The fuzz corpus ran clean for 10 minutes. The PR is ready for review." />
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.since-divider",
  title: "Unread marker: the New line",
  area: "Agent pane",
  pane: true,
  height: 340,
  widths: { narrow: 420, normal: 640, wide: 820 },
  covers: ["agent-session/acpmux/conversation/SinceDivider.tsx"],
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css"), import("./unread.css")]),
  load: async () => UnreadLooks,
  variants: {
    "line-tag": {
      note: "Chosen: an accent hairline across the column with a filled New tag at its end; the recap under it.",
      props: { theme: "dark", look: "tag" },
    },
    "line-text": {
      note: "The hairline with New in accent text at its end, no fill; quieter, but the tag's fill is what the eye finds.",
      props: { theme: "dark", look: "text" },
    },
    "line-labelled": {
      note: "The first look on theme tokens: New since you looked · 3 turns leading the hairline; the most words in the rhythm.",
      props: { theme: "dark", look: "labelled" },
    },
    "line-no-recap": {
      note: "A chat with no recap (not Claude, or the recap is off): the line alone, one control row tall.",
      props: { theme: "dark", recap: false },
    },
    "line-read": {
      note: "Read (Mark read, or seen and then the latest reached): the rule and the tag have faded in place; the row and the recap stay.",
      props: { theme: "dark", read: true },
    },
    "line-light": {
      note: "Chosen look in the light theme: the theme's accent, on-accent text in the tag.",
      props: { theme: "light" },
    },
    "line-image": {
      note: "Chosen look over a background image: the same tokens over the pane's glass.",
      props: { theme: "image" },
    },
  },
});
