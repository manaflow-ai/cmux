// Dev server only: the app key dispatcher's part the editor depends on, for the plain-browser loop
// (devBridge.ts). App chords that the app resolves globally never reach Monaco in the app, so they are
// swallowed here too; the app's find and save actions arrive as page commands. The tables follow
// README.md "Keys" (generated from the action catalog's defaults and Monaco's keybindings).
import type { PageCommand } from "../shared/pageStreams";

type Chord = string;

/** `cmd+shift+k` style key of a keydown (modifiers in a fixed order, the key lowercased). */
export function chordOf(
  event: Pick<KeyboardEvent, "metaKey" | "ctrlKey" | "altKey" | "shiftKey" | "key" | "code">,
): Chord {
  const parts: string[] = [];
  if (event.ctrlKey) parts.push("ctrl");
  if (event.altKey) parts.push("alt");
  if (event.shiftKey) parts.push("shift");
  if (event.metaKey) parts.push("cmd");
  // Option and Shift change `key` on macOS (Opt-G is "©"); the physical key decides.
  const code = event.code;
  const key = /^Key[A-Z]$/.test(code)
    ? code.slice(3).toLowerCase()
    : /^Digit\d$/.test(code)
      ? code.slice(5)
      : ((
          {
            BracketLeft: "[",
            BracketRight: "]",
            Equal: "=",
            Minus: "-",
            Slash: "/",
            Backslash: "\\",
            Enter: "enter",
            ArrowUp: "up",
            ArrowDown: "down",
            ArrowLeft: "left",
            ArrowRight: "right",
          } as Record<string, string>
        )[code] ?? event.key.toLowerCase());
  parts.push(key);
  return parts.join("+");
}

/** App actions that reach the editor as page commands. */
export const DEV_PAGE_COMMANDS: Record<Chord, PageCommand> = {
  "cmd+s": { command: "save" },
  "cmd+f": { command: "find" },
  "cmd+g": { command: "findNext" },
  "alt+cmd+g": { command: "findPrevious" },
  "cmd+e": { command: "useSelectionForFind" },
  "alt+shift+cmd+f": { command: "hideFind" },
  "cmd+=": { command: "zoomIn" },
  "cmd+-": { command: "zoomOut" },
  "cmd+0": { command: "zoomReset" },
};

/**
 * App chords bound globally (no context) that Monaco also binds and the app keeps in the editor
 * (README.md "Keys"). The ones whose app action yields to the editor (Cmd-D, Shift-Cmd-L, Cmd-L,
 * Opt-Cmd-arrows...) reach Monaco, as in the app.
 */
export const DEV_APP_CHORDS: ReadonlySet<Chord> = new Set([
  "shift+cmd+o", // reopenPreviousSession; Monaco: go to symbol
  "shift+cmd+,", // reloadConfiguration; Monaco: replace with previous value
]);

/** What the dispatcher does with a keydown: a page command, swallow (`command` null), or nothing. */
export function DEV_DISPATCHER(event: KeyboardEvent): PageCommand | { command: null } | null {
  if (!event.metaKey && !event.ctrlKey) return null;
  const chord = chordOf(event);
  const command = DEV_PAGE_COMMANDS[chord];
  if (command) return command;
  return DEV_APP_CHORDS.has(chord) ? { command: null } : null;
}
