import type * as monaco from "monaco-editor";

export const CMUX_THEME_DARK = "cmux-dark";
export const CMUX_THEME_LIGHT = "cmux-light";

export function registerCmuxThemes(monacoNs: typeof monaco): void {
  monacoNs.editor.defineTheme(CMUX_THEME_DARK, {
    base: "vs-dark",
    inherit: true,
    rules: [],
    colors: {},
  });
  monacoNs.editor.defineTheme(CMUX_THEME_LIGHT, {
    base: "vs",
    inherit: true,
    rules: [],
    colors: {},
  });
}

export interface CmuxPalette {
  isDark: boolean;
  backgroundHex: string;
  foregroundHex: string;
  cursorHex?: string;
  selectionBackgroundHex?: string;
  /** ANSI 0..15, lowercase `#rrggbb`. Optional. */
  ansi?: string[];
}

/** Apply a Ghostty-derived palette to our Monaco theme and activate it. */
export function applyCmuxPalette(
  monacoNs: typeof monaco,
  palette: CmuxPalette,
): void {
  const base = palette.isDark ? "vs-dark" : "vs";
  const name = palette.isDark ? CMUX_THEME_DARK : CMUX_THEME_LIGHT;
  const ansi = palette.ansi ?? [];

  const rules = ansiTokenRules(ansi);
  const colors = editorColors(palette);

  try {
    monacoNs.editor.defineTheme(name, {
      base,
      inherit: true,
      rules,
      colors,
    });
    monacoNs.editor.setTheme(name);
    // eslint-disable-next-line no-console
    console.log(
      `cmux.monaco.theme applied name=${name} bg=${palette.backgroundHex} fg=${palette.foregroundHex} rules=${rules.length} ansi=${ansi.length}`,
    );
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error("cmux.monaco.theme defineTheme failed", err, {
      rules,
      colors,
    });
    // Re-apply base theme as fallback so the editor is at least readable.
    monacoNs.editor.setTheme(base);
  }

  // Mirror into CSS so the host never flashes white-on-white when Monaco
  // remounts or during style recomputation.
  document.documentElement.style.setProperty(
    "--cmux-editor-bg",
    palette.backgroundHex,
  );
  document.documentElement.style.setProperty(
    "--cmux-editor-fg",
    palette.foregroundHex,
  );
  document.body.style.background = palette.backgroundHex;
  document.body.style.color = palette.foregroundHex;
  document.documentElement.style.colorScheme = palette.isDark
    ? "dark"
    : "light";
}

function editorColors(
  palette: CmuxPalette,
): { [key: string]: string } {
  const cursor = palette.cursorHex ?? palette.foregroundHex;
  // Monaco's selection color is painted on top of text. Solid #RRGGBB values
  // obscure the selected characters, so always fall back to a ~40% alpha.
  const rawSelection = palette.selectionBackgroundHex
    ?? (palette.isDark ? "#264f78" : "#add6ff");
  const selection = rawSelection.length === 7 ? `${rawSelection}66` : rawSelection;
  const ansi = palette.ansi ?? [];

  return {
    "editor.background": palette.backgroundHex,
    "editor.foreground": palette.foregroundHex,
    "editorCursor.foreground": cursor,
    "editor.lineHighlightBackground": palette.isDark ? "#ffffff0a" : "#0000000a",
    "editor.selectionBackground": selection,
    "editor.inactiveSelectionBackground": palette.isDark
      ? "#3a3d4166"
      : "#e5ebf1",
    "editorGutter.background": palette.backgroundHex,
    "editorLineNumber.foreground": palette.isDark ? "#6e7681" : "#b1b1b3",
    "editorLineNumber.activeForeground": palette.foregroundHex,
    "editorWidget.background": palette.backgroundHex,
    "editorSuggestWidget.background": palette.backgroundHex,
    "editor.findMatchBackground": ansi[3] ? withAlpha(ansi[3], 0x66) : "#665500",
    "editor.findMatchHighlightBackground": ansi[3]
      ? withAlpha(ansi[3], 0x33)
      : "#ea5c0055",
    "terminal.background": palette.backgroundHex,
    "terminal.foreground": palette.foregroundHex,
    "terminalCursor.foreground": cursor,
    ...ansiEditorColors(ansi),
  };
}

function ansiEditorColors(ansi: string[]): { [key: string]: string } {
  const out: { [key: string]: string } = {};
  const keys: Array<[number, string]> = [
    [0, "terminal.ansiBlack"],
    [1, "terminal.ansiRed"],
    [2, "terminal.ansiGreen"],
    [3, "terminal.ansiYellow"],
    [4, "terminal.ansiBlue"],
    [5, "terminal.ansiMagenta"],
    [6, "terminal.ansiCyan"],
    [7, "terminal.ansiWhite"],
    [8, "terminal.ansiBrightBlack"],
    [9, "terminal.ansiBrightRed"],
    [10, "terminal.ansiBrightGreen"],
    [11, "terminal.ansiBrightYellow"],
    [12, "terminal.ansiBrightBlue"],
    [13, "terminal.ansiBrightMagenta"],
    [14, "terminal.ansiBrightCyan"],
    [15, "terminal.ansiBrightWhite"],
  ];
  for (const [idx, key] of keys) {
    const value = ansi[idx];
    if (value) out[key] = value;
  }
  return out;
}

/** Map Monaco token categories to Ghostty ANSI colors. */
function ansiTokenRules(
  ansi: string[],
): Array<{ token: string; foreground?: string; fontStyle?: string }> {
  if (ansi.length < 16) return [];

  const stripHash = (hex: string) => hex.replace(/^#/, "").toLowerCase();
  const red = stripHash(ansi[1]!);
  const green = stripHash(ansi[2]!);
  const yellow = stripHash(ansi[3]!);
  const magenta = stripHash(ansi[5]!);
  const cyan = stripHash(ansi[6]!);
  const brightBlack = stripHash(ansi[8]!);

  // Monaco rejects rules with empty `foreground` strings and silently falls
  // back to the base theme for the *entire* custom theme when validation
  // fails. Every entry here must carry a real 6-digit hex. Don't include
  // "default" (token="") rules — let Monaco inherit from the base theme.
  return [
    { token: "comment", foreground: brightBlack, fontStyle: "italic" },
    { token: "comment.doc", foreground: brightBlack, fontStyle: "italic" },

    { token: "string", foreground: green },
    { token: "string.escape", foreground: cyan },
    { token: "string.regexp", foreground: magenta },

    { token: "number", foreground: magenta },
    { token: "number.hex", foreground: magenta },
    { token: "number.octal", foreground: magenta },
    { token: "number.float", foreground: magenta },

    // Monokai renders keywords in red/pink, not blue, and operators in
    // pink too. This matches the canonical Monokai tokenization.
    { token: "keyword", foreground: red, fontStyle: "bold" },
    { token: "keyword.control", foreground: red, fontStyle: "bold" },
    { token: "keyword.operator", foreground: red },
    { token: "keyword.other", foreground: red },

    { token: "type", foreground: cyan, fontStyle: "italic" },
    { token: "type.identifier", foreground: cyan, fontStyle: "italic" },

    { token: "variable.parameter", foreground: yellow, fontStyle: "italic" },

    { token: "function", foreground: yellow },
    { token: "function.name", foreground: yellow },
    { token: "support.function", foreground: yellow },

    { token: "constant", foreground: magenta },
    { token: "constant.language", foreground: magenta },
    { token: "constant.numeric", foreground: magenta },

    { token: "tag", foreground: red },
    { token: "tag.id", foreground: red },
    { token: "attribute.name", foreground: green },
    { token: "attribute.value", foreground: magenta },

    { token: "delimiter", foreground: stripHash(ansi[7]!) },
    { token: "operator", foreground: red },

    { token: "invalid", foreground: red, fontStyle: "bold" },
  ];
}

/** Apply a hex alpha byte to a `#rrggbb` color. Returns `#rrggbbaa`. */
function withAlpha(hexColor: string, alphaByte: number): string {
  const clean = hexColor.replace(/^#/, "");
  if (clean.length !== 6) return hexColor;
  const a = Math.max(0, Math.min(255, alphaByte))
    .toString(16)
    .padStart(2, "0");
  return `#${clean}${a}`;
}
