export type AgentSessionTheme = {
  isDark: boolean;
  pageBackground: string;
  surfaceBackground: string;
  surfaceElevatedBackground: string;
  inputBackground: string;
  border: string;
  borderStrong: string;
  text: string;
  mutedText: string;
  softText: string;
  accent: string;
  accentSoft: string;
  /// A lit (pressed, on) control's glyph or label: the accent lifted to at least the muted text's
  /// contrast (`ThemeTokens.litGlyph`); without it, `accent`.
  litGlyph?: string;
  /// Labels on the accent; the cmux-next pane sends it, others fall back to white.
  accentText?: string;
  /// Glyphs on `accent` where it fills a control (Send); without it, `accentText`.
  onAccent?: string;
  danger: string;
  /// Caution, softer than `danger` (ANSI yellow): the full-access mode chip.
  warning?: string;
  /// Done and passing marks (ANSI green): open PRs, passing checks, a finished Chief task.
  success?: string;
  /// The primary action (the composer's Send): the theme's ANSI blue.
  highlight?: string;
  /// Glyphs on `highlight`.
  highlightText?: string;
  shadow: string;
  /// The terminal's 16 ANSI colors, for syntax colors that follow the theme; the cmux-next
  /// pane sends it. Without it, code keeps the built-in dark hues on the theme's text colors.
  palette?: string[];
  /// appearance.borders; `none` sets `data-borders="none"` on the root, which clears the
  /// pane's own edges and rings (the composer, menus, code and tool cards). `border` and
  /// `borderStrong` are already transparent then. Absent means default.
  borders?: "default" | "none";
  /// Whether keyboard focus outlines, including transcript response rows, are shown.
  focusRingEnabled?: boolean;
  /// The chat column's width on a wide pane (Debug Settings `agent.chatWidth`, acpmux chatWidth.ts):
  /// `standard`, `wide` or `wideBlocks`. Absent means standard.
  chatWidth?: string;
  /// Codex-style tool runs in a running turn (Debug Settings `agentPane.debug.codexToolRuns`,
  /// acpmux codexToolRuns.ts). Native hosts send their default (true) explicitly; absent keeps it
  /// on, and false opts out.
  codexToolRuns?: boolean;
  /// A running turn's status line as its last row (Debug Settings `agentPane.debug.liveLineBelow`,
  /// acpmux liveLineBelow.ts). Absent or true draws it there; false keeps it over the turn's work.
  liveLineBelow?: boolean;
  /// A collapsed tool run's look (acpmux toolRunLook.ts): `kind` (absent), `pencil`, `quiet` or
  /// `quiet-pencil`. Only the gallery sends it, for the versions it keeps beside the default.
  toolRunLook?: string;
  /// The answer footer's copy/retry/fork controls: right by default, or left when selected by the host.
  turnActionsPlacement?: "left" | "right";
  /// The host's motion durations in seconds (MotionFade after ui.animationSpeed and Reduce
  /// Motion; 0 means apply at once), as `--agent-motion-*`. Absent keeps the stylesheet defaults.
  /// `hoverOut` is how fast a hover fill clears (0 by default, as in Edge). `move` is the native
  /// `move` spring's timed equivalent (MotionSpring), 0 when movement is instant.
  motion?: { hover: number; hoverOut?: number; focus: number; fadeIn: number; fadeOut: number; move?: number };
  /// appearance.statusIndicator.animation, `static` also under Reduce Motion (cx-sya4n): sets
  /// `data-status-indicators` on the root; under `static` no status loop runs and color-only
  /// marks draw a shape each. Absent means the stylesheet defaults (animated).
  statusIndicators?: "animated" | "static";
  /// How agent work shows (Debug Settings `status.working`, CmuxNextDesign StatusWorkingLook): sets
  /// `data-working-look` on the root. Absent means the stylesheet default, the spinner.
  workingLook?: "breathe" | "shimmer" | "spinner";
  /// Running subagents in one tray above the composer, a line where each ended (Debug Settings
  /// `agentPane.debug.subagentTray`, acpmux subagents/runningTray.ts). Absent or true is the tray;
  /// false keeps the transcript's group cards and the agents pill.
  subagentTray?: boolean;
  /// Running tray placement; absent keeps the tray above the composer. The alternate is
  /// fixture/Labs-driven until a native setting owns it.
  subagentTrayPlacement?: "tray" | "after-latest-message";
  /// The transcript's scrollbar fades out at rest (Debug Settings `agentPane.debug.scrollerFade`):
  /// sets `data-cmux-scroller-fade` on the root (scrollers.ts). Absent or false keeps it shown while
  /// the chat overflows.
  scrollerFade?: boolean;
};
