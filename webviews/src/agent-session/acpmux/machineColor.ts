/// A machine's identity color: one of the terminal theme's accents, picked by a stable hash of the
/// machine's name, so another machine keeps one color in the composer's computer chip, the
/// environment list and the chat's Environment line, and two machines rarely look alike. This Mac
/// draws no color (Leo 2026-10-20: another machine is the news). The hash and the
/// order are the app's (AgentPresenceColor: FNV-1a over the name's Unicode scalars, then
/// red, green, yellow, purple, cyan, orange, pink, blue), so the sidebar can draw the same color.
export const MACHINE_HUES = ["red", "green", "yellow", "purple", "cyan", "orange", "pink", "blue"] as const;

export type MachineHue = (typeof MACHINE_HUES)[number];

/// The hue for a machine's name. Case and surrounding space don't change it: "Big-Red" and
/// "big-red" are one machine.
export function machineHue(name: string): MachineHue {
  let hash = 2_166_136_261;
  for (const char of name.trim().toLowerCase()) {
    hash ^= char.codePointAt(0) ?? 0;
    hash = Math.imul(hash, 16_777_619) >>> 0;
  }
  return MACHINE_HUES[hash % MACHINE_HUES.length] ?? "blue";
}

const ansi = (slot: number) => `var(--agent-ansi-${slot}, currentColor)`;
const RED = ansi(1);
const YELLOW = ansi(3);
const PURPLE = ansi(5);

/// Each hue in the pane's terminal palette (`--agent-ansi-N`, which applyAgentTheme lifts to read
/// on the pane), else the text color; orange and pink mix two slots, as the app's do.
const HUE_COLORS: Record<MachineHue, string> = {
  red: RED,
  green: ansi(2),
  yellow: YELLOW,
  purple: PURPLE,
  cyan: ansi(6),
  orange: `color-mix(in oklab, ${RED} 50%, ${YELLOW})`,
  pink: `color-mix(in oklab, ${PURPLE} 50%, ${RED})`,
  blue: ansi(4),
};

/// The CSS color for a machine's name, in the active theme.
export function machineColor(name: string): string {
  return HUE_COLORS[machineHue(name)];
}
