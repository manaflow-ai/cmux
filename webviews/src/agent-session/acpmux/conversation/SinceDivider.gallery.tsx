// l10n-allow-file: gallery fixtures (sample recaps and replies), not shipped UI.
// The unread marker's looks (SinceDivider.tsx, sinceLook.experiment.ts; design/transcript-overlays.md),
// each between the reply the person had seen and the next turn's "Worked for" line, which came while
// they were away. None takes height: the rows sit where they sit with no line at all (the
// `no-line` variant). In three themes: light,
// dark, and a dark theme over a background image (the pane's glass over a wallpaper). The palettes
// stand in for what the app's applyTheme sets (--cmux-app-* from cmux-theme-tokens app_theme.rs):
// the component reads only those tokens. References: chat apps' unread line (a rule with a NEW
// tag at its end), their "N new messages since" bar, and the accent "New" line with a "New messages"
// pill; the terminal chat's "157 new messages" rule, a hairline broken by a centered muted count
// (Leo, 2026-11-15: "we needto properly do somthing like this in the gui somehow"); the glass of Jump to latest (cmux-design-references cmux-next/live/
// transcript-jump-to-latest-glass-too-transparent). The whole pane with the jump pair is
// agent-pane.unread-marker.
import type React from "react";
import { componentEntry } from "../../../gallery/format";
import wallpaper from "../../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { SinceDivider, UnreadBanner, type SinceLook } from "./SinceDivider";
import type { UnreadBannerMode } from "./unreadState";

type Theme = "light" | "dark" | "image";
type Part = "line" | "banner";

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
// 3:42 PM today, so the banner says "since 3:42 PM" in every capture.
const FIRST_NEW = new Date(new Date().setHours(15, 42, 0, 0)).getTime();

function Reply({ text }: { text: string }) {
  return <p style={{ margin: 0, color: "var(--agent-text)", lineHeight: "20px" }}>{text}</p>;
}

/// The new turn's "Worked for" line, drawn with the transcript's own classes (conversation.css), the
/// toggle's included: its divider sits a foot gap under its words, and the mark must light that
/// divider, not draw its own over the words' bottom (manaflow-ai/cmux#51002).
function Worked() {
  return (
    <div className="cv-worked has-divider is-toggle" style={{ color: "var(--agent-muted)" }}>
      Worked for 31s
    </div>
  );
}

type Props = {
  part: Part;
  theme: Theme;
  look?: SinceLook;
  read?: boolean;
  recap?: boolean;
  mode?: UnreadBannerMode;
  /// No line at all: the rows' places every look must keep.
  none?: boolean;
  /// The next row is the running turn's "Working for" line (row kind `working`), not a finished one.
  working?: boolean;
  /// The messages under the line ("157 new messages"); 0 for a line not counted yet ("New").
  count?: number;
};

/// The gap between the seen turn and the next (the transcript's turn gap), which the line lies over.
const TURN_GAP = 32;

function UnreadLooks({
  part,
  theme,
  look,
  read = false,
  recap = false,
  mode = "expanded",
  none = false,
  working = false,
  count = 157,
}: Props) {
  return (
    <div
      className="acpmux-shell"
      // `alignContent: start`: the rows keep their own heights; a stretched grid gave the 0 px line
      // row the stage's spare height, which moved the mark off the Worked for line (#51002).
      style={{
        ...THEMES[theme],
        position: "relative",
        padding: 16,
        display: "grid",
        gap: 8,
        alignContent: "start",
        minHeight: "100%",
      }}
    >
      {part === "banner" && (
        <div className="acpmux-over-top" data-zone="top-start" style={{ top: 0 }}>
          <UnreadBanner
            mark={`gallery-${theme}`}
            turns={3}
            firstNewAt={FIRST_NEW}
            onJump={() => {}}
            mode={mode}
            forceShown
            {...(count > 0 && { count })}
          />
        </div>
      )}
      <div style={{ height: part === "banner" ? 32 : 0 }} />
      <Reply text="I'll start by reading foo.rs to see how absent fields fail." />
      {/* The line's row takes no height; the turn gap under it is the transcript's, which it reads.
          Then the new turn's Worked for line, which look B lies on. The rows carry the transcript's
          row classes so the look's selectors (unread.css) read the same. The transcript places rows
          from the model (the line's row is 0 px, model.ts), so the row's own min-height and bottom
          padding (.acpmux-row) never move the next one; here they would, so they are off. */}
      <div
        className="acpmux-row"
        style={
          {
            position: "relative",
            left: 0,
            right: 0,
            minHeight: 0,
            paddingBottom: 0,
            "--cv-since-gap": `${TURN_GAP}px`,
          } as React.CSSProperties
        }
      >
        {!none && (
          <SinceDivider
            since={{
              key: `gallery-${theme}-${look ?? "default"}:41`,
              seq: 41,
              turns: 3,
              ...(recap && { recap: { key: `gallery-${theme}-${look}`, text: RECAP, awayMs: 38 * 60_000 } }),
            }}
            onDismissRecap={() => {}}
            look={look}
            read={read}
            dwellMs={60 * 60_000}
            {...(count > 0 && { count })}
          />
        )}
      </div>
      <div
        className={`acpmux-row ${working ? "acpmux-working" : "acpmux-worked"}`}
        style={{ position: "relative", left: 0, right: 0, marginTop: TURN_GAP - 8 }}
      >
        <Worked />
      </div>
      <Reply text="Missing fields now default instead of failing; I added a test for each one." />
      <Reply text="The fuzz corpus ran clean for 10 minutes. The PR is ready for review." />
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.since-divider",
  title: "Unread marker: the New line and the unread banner",
  area: "Agent pane",
  pane: true,
  height: 340,
  widths: { narrow: 420, normal: 640, wide: 820 },
  covers: ["agent-session/acpmux/conversation/SinceDivider.tsx"],
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css"), import("./unread.css")]),
  load: async () => UnreadLooks,
  variants: {
    "line-worked": {
      note: 'B (shipped): folded into the next turn\'s Worked for line: "157 new messages" at its end and its rule lit in the accent; no height, it fades back to the plain rule.',
      props: { part: "line", theme: "dark", look: "worked" },
    },
    "line-worked-uncounted": {
      note: 'B before the rows are counted (or past the count\'s reach): "New" at its end, as before.',
      props: { part: "line", theme: "dark", look: "worked", count: 0 },
    },
    "line-thin": {
      note: 'A: a thin accent hairline across the middle of the turn gap, "157 new messages" muted at its center, as the terminal chat draws it; no height, it fades and narrows away toward the words.',
      props: { part: "line", theme: "dark", look: "line" },
    },
    "line-thin-few": {
      note: 'A after a short absence: "3 new messages". The count grows in place as rows arrive; only the words widen, never the row.',
      props: { part: "line", theme: "dark", look: "line", count: 3 },
    },
    "line-thin-one": {
      note: 'A with one message: "1 new message", the singular.',
      props: { part: "line", theme: "dark", look: "line", count: 1 },
    },
    "line-thin-capped": {
      note: 'A past the cap: "999+ new messages", so counting stays bounded however long the chat ran.',
      props: { part: "line", theme: "dark", look: "line", count: 4_210 },
    },
    "line-thin-uncounted": {
      note: "A before the rows are counted: the plain hairline, no words.",
      props: { part: "line", theme: "dark", look: "line", count: 0 },
    },
    "line-thin-light": {
      note: "A with its count in the light theme.",
      props: { part: "line", theme: "light", look: "line" },
    },
    "line-pill": {
      note: "C: a small New pill alone at the end of the turn gap, no rule; no height, it fades out.",
      props: { part: "line", theme: "dark", look: "pill" },
    },
    "no-line": {
      note: "No line: every look keeps the rows exactly here (the line takes no height).",
      props: { part: "line", theme: "dark", none: true },
    },
    "line-working": {
      note: "B over the running turn's Working for line: the same divider lit, New at its end.",
      props: { part: "line", theme: "dark", look: "worked", working: true },
    },
    "no-line-working": {
      note: "No line over the running turn's Working for line: where its divider sits.",
      props: { part: "line", theme: "dark", none: true, working: true },
    },
    "line-read": {
      note: "Read (dissipated after a moment on screen at a focused pane, or Mark read): nothing drawn, and nothing moved.",
      props: { part: "line", theme: "dark", look: "worked", read: true },
    },
    "line-recap": {
      note: "With the recap made for the same return: the recap is content and takes its room; the line lies over the gap above it.",
      props: { part: "line", theme: "dark", look: "worked", recap: true },
    },
    "line-light": {
      note: "Shipped look in the light theme: the theme's accent.",
      props: { part: "line", theme: "light", look: "worked" },
    },
    "line-image": {
      note: "Shipped look over a background image: the same tokens over the pane's glass.",
      props: { part: "line", theme: "image", look: "worked" },
    },
    "banner-expanded": {
      note: "Chosen: the glass bar at the top start, the line's count: 157 new messages since 3:42 PM | Mark read | collapse chevron.",
      props: { part: "banner", theme: "dark", mode: "expanded" },
    },
    "banner-collapsed": {
      note: "Collapsed: a small pill with the arrow and the count; the chevron expands it again.",
      props: { part: "banner", theme: "dark", mode: "collapsed" },
    },
    "banner-turns": {
      note: "Before the line's rows are counted: the turns acpmux counted, 3 new turns since 3:42 PM.",
      props: { part: "banner", theme: "dark", mode: "expanded", count: 0 },
    },
    "banner-light": {
      note: "Expanded in the light theme.",
      props: { part: "banner", theme: "light", mode: "expanded" },
    },
    "banner-image": {
      note: "Expanded over a background image: the glass keeps the words legible.",
      props: { part: "banner", theme: "image", mode: "expanded" },
    },
    "banner-collapsed-light": {
      note: "Collapsed in the light theme.",
      props: { part: "banner", theme: "light", mode: "collapsed" },
    },
  },
});
