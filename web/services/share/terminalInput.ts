export const MAX_TERMINAL_INPUT_BYTES = 4_096;

export type TerminalInputCommand = {
  readonly kind: "text" | "key";
  readonly data: string;
};

export type TerminalKeyboardEvent = {
  readonly key: string;
  readonly ctrlKey: boolean;
  readonly shiftKey: boolean;
  readonly altKey: boolean;
  readonly metaKey: boolean;
  readonly isComposing?: boolean;
};

const NAMED_KEYS: Readonly<Record<string, string>> = {
  Enter: "enter",
  Backspace: "backspace",
  Tab: "tab",
  Escape: "escape",
  ArrowUp: "up",
  ArrowDown: "down",
  ArrowLeft: "left",
  ArrowRight: "right",
  Home: "home",
  End: "end",
  Delete: "delete",
};

export function terminalCommandForKeyboardEvent(event: TerminalKeyboardEvent): TerminalInputCommand | null {
  if (event.isComposing || event.metaKey || event.altKey) return null;
  if (event.ctrlKey) {
    const key = event.key.toLowerCase();
    if (event.shiftKey && key === "v") return null;
    return /^[a-z\\]$/u.test(key) ? { kind: "key", data: `ctrl-${key}` } : null;
  }
  const key = NAMED_KEYS[event.key];
  if (!key) return null;
  return { kind: "key", data: event.key === "Tab" && event.shiftKey ? "shift-tab" : key };
}

export function terminalCommandsFromText(value: string): readonly TerminalInputCommand[] {
  const commands: TerminalInputCommand[] = [];
  const encoder = new TextEncoder();
  let text = "";
  let textBytes = 0;
  let previousWasReturn = false;

  const flush = () => {
    if (text) commands.push({ kind: "text", data: text });
    text = "";
    textBytes = 0;
  };
  const key = (data: string) => {
    flush();
    commands.push({ kind: "key", data });
  };

  for (const character of value) {
    if (character === "\n" && previousWasReturn) {
      previousWasReturn = false;
      continue;
    }
    previousWasReturn = character === "\r";
    if (character === "\r" || character === "\n") {
      key("enter");
      continue;
    }
    if (character === "\t") {
      key("tab");
      continue;
    }
    if (character === "\u001b") {
      key("escape");
      continue;
    }
    if (character === "\b" || character === "\u007f") {
      key("backspace");
      continue;
    }
    const codePoint = character.codePointAt(0) ?? 0;
    if (codePoint <= 0x1F || (codePoint >= 0x7F && codePoint <= 0x9F)) continue;
    const bytes = encoder.encode(character).byteLength;
    if (textBytes + bytes > MAX_TERMINAL_INPUT_BYTES) flush();
    text += character;
    textBytes += bytes;
  }
  flush();
  return commands;
}

export function terminalInputPayload(
  surfaceId: string,
  layoutRevision: number,
  command: TerminalInputCommand,
): Record<string, unknown> | null {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu.test(surfaceId) ||
      !Number.isSafeInteger(layoutRevision) || layoutRevision < 0 ||
      !validTerminalInputCommand(command)) return null;
  return { surfaceId, layoutRevision, kind: command.kind, data: command.data };
}

export function validTerminalInputCommand(command: TerminalInputCommand): boolean {
  if (command.kind === "key") {
    return Object.values(NAMED_KEYS).includes(command.data) || command.data === "shift-tab" ||
      /^ctrl-[a-z\\]$/u.test(command.data);
  }
  if (command.kind !== "text" || !command.data ||
      new TextEncoder().encode(command.data).byteLength > MAX_TERMINAL_INPUT_BYTES) return false;
  return [...command.data].every((character) => {
    const codePoint = character.codePointAt(0) ?? 0;
    return codePoint > 0x1F && !(codePoint >= 0x7F && codePoint <= 0x9F);
  });
}
