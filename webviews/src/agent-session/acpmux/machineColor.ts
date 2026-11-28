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

const keyOf = (name: string) => name.trim().toLowerCase();

/// Each machine's hue, no two alike while a free hue is left (Leo, 2026-11-28: "we can have them be
/// delineated"): its name's hash hue unless a machine before it (in key order) already draws it, then
/// the next free hue in pick order. The app's MachineColorOverrides.automaticAccents, which the
/// sidebar draws; pages in the app take the app's result (`setHostMachineMarks`), others this one.
export function assignMachineHues(names: readonly string[]): Record<string, MachineHue> {
  const taken = new Set<MachineHue>();
  const assigned: Record<string, MachineHue> = {};
  for (const key of [...new Set(names.map(keyOf))].filter(Boolean).sort()) {
    const start = MACHINE_HUES.indexOf(machineHue(key));
    let hue = MACHINE_HUES[start] ?? "blue";
    for (let step = 0; step < MACHINE_HUES.length; step += 1) {
      const next = MACHINE_HUES[(start + step) % MACHINE_HUES.length] ?? "blue";
      if (!taken.has(next)) {
        hue = next;
        break;
      }
    }
    assigned[key] = hue;
    taken.add(hue);
  }
  return assigned;
}

/// What the host said of the person's machines (`AgentSessionTheme.machineColors` and `.machineIcons`,
/// by trimmed, lowercased name): each one's color (their pick, else a hue no other machine draws) and
/// emoji icon (`machine.setIcon`), as the sidebar's headers draw them.
let hostColors: Readonly<Record<string, string>> = {};
let hostIcons: Readonly<Record<string, string>> = {};

/// Records the host's machine colors and icons (theme.ts applyAgentTheme; the gallery's fixtures).
export function setHostMachineMarks(
  colors?: Readonly<Record<string, string>>,
  icons?: Readonly<Record<string, string>>,
): void {
  hostColors = Object.fromEntries(Object.entries(colors ?? {}).map(([name, color]) => [keyOf(name), color]));
  hostIcons = Object.fromEntries(Object.entries(icons ?? {}).map(([name, icon]) => [keyOf(name), icon]));
}

/// The person's own icon for a machine (an emoji), when the host sent one.
export function machineEmoji(name: string): string | undefined {
  return hostIcons[keyOf(name)];
}

/// The CSS color for a machine's name, in the active theme: the host's color for it when it sent one,
/// else its hash hue.
export function machineColor(name: string): string {
  return hostColors[keyOf(name)] ?? HUE_COLORS[machineHue(name)];
}

/// The CSS color of a hue in the active theme.
export function hueColor(hue: MachineHue): string {
  return HUE_COLORS[hue];
}
