export type TerminalInput =
  | { kind: "key"; key: string }
  | { kind: "text"; text: string }
  | { kind: "ignore" };

const escape = "\u001b";

const basicEscapeKeys = new Map<string, string>([
  ["\r", "enter"],
  ["\u0003", "ctrl-c"],
  [escape, "escape"],
  ["\t", "tab"],
  ["\u007f", "backspace"],
  [`${escape}[A`, "up"],
  [`${escape}[B`, "down"],
  [`${escape}[D`, "left"],
  [`${escape}[C`, "right"],
  [`${escape}[H`, "home"],
  [`${escape}[F`, "end"],
  [`${escape}OH`, "home"],
  [`${escape}OF`, "end"],
  [`${escape}[1~`, "home"],
  [`${escape}[4~`, "end"],
  [`${escape}[7~`, "home"],
  [`${escape}[8~`, "end"],
  [`${escape}[3~`, "delete"],
  [`${escape}[5~`, "pageup"],
  [`${escape}[6~`, "pagedown"],
  [`${escape}[Z`, "shift+tab"],
]);

const csiFinalKeyNames = new Map<string, string>([
  ["A", "up"],
  ["B", "down"],
  ["C", "right"],
  ["D", "left"],
  ["H", "home"],
  ["F", "end"],
]);

const csiTildeKeyNames = new Map<string, string>([
  ["1", "home"],
  ["3", "delete"],
  ["4", "end"],
  ["7", "home"],
  ["8", "end"],
]);

export function classifyTerminalData(data: string): TerminalInput {
  const basicKey = basicEscapeKeys.get(data);
  if (basicKey) {
    return { kind: "key", key: basicKey };
  }

  if (!data.startsWith(escape)) {
    return { kind: "text", text: data };
  }

  const modifiedCSI = keyFromModifiedCSI(data);
  if (modifiedCSI) {
    return { kind: "key", key: modifiedCSI };
  }

  const altPrintable = keyFromAltPrintable(data);
  if (altPrintable) {
    return { kind: "key", key: altPrintable };
  }

  return { kind: "ignore" };
}

function keyFromModifiedCSI(data: string) {
  const finalMatch = /^\u001b\[1;([2-8])([ABCDFH])$/.exec(data);
  if (finalMatch) {
    return modifiedKeyName(finalMatch[1], csiFinalKeyNames.get(finalMatch[2]));
  }

  const tildeMatch = /^\u001b\[(\d+);([2-8])~$/.exec(data);
  if (tildeMatch) {
    return modifiedKeyName(tildeMatch[2], csiTildeKeyNames.get(tildeMatch[1]));
  }

  return null;
}

function modifiedKeyName(modifierCode: string, baseKey: string | undefined) {
  if (!baseKey) return null;
  const modifiers = modifiersForCSI(modifierCode);
  if (!modifiers.length) return null;
  return `${modifiers.join("+")}+${baseKey}`;
}

function modifiersForCSI(modifierCode: string) {
  switch (modifierCode) {
    case "2":
      return ["shift"];
    case "3":
      return ["alt"];
    case "4":
      return ["shift", "alt"];
    case "5":
      return ["ctrl"];
    case "6":
      return ["shift", "ctrl"];
    case "7":
      return ["alt", "ctrl"];
    case "8":
      return ["shift", "alt", "ctrl"];
    default:
      return [];
  }
}

function keyFromAltPrintable(data: string) {
  if (data.length !== 2) return null;
  const char = data[1];
  if (char < " " || char === "\u007f") return null;
  return `alt+${char}`;
}
