import { describe, expect, test } from "bun:test";
import { editorAction, isEditorCommand } from "./keys";
import {
  EDITOR_DEFAULTS,
  editorFont,
  isLargeFile,
  monacoOptions,
  resolveEditorSettings,
  settingsForLanguage,
  syntaxThemeNames,
} from "./settings";
import { computedColorToHex } from "./colors";

describe("resolveEditorSettings", () => {
  test("no section gives the defaults", () => {
    expect(resolveEditorSettings(undefined)).toEqual(EDITOR_DEFAULTS);
  });

  test("reads Monaco's and VS Code's key names, including the {enabled} forms", () => {
    // The shape of a real cmux.json `editor` section.
    const settings = resolveEditorSettings({
      bracketPairColorization: { enabled: false },
      cursorStyle: "block",
      lineNumbers: "relative",
      minimap: { enabled: true },
      renderWhitespace: "all",
      rulers: [80, 100],
      stickyScroll: { enabled: false },
      wordWrap: "on",
      fontFamily: "JetBrains Mono",
      fontSize: 14,
      tabSize: 2,
      insertSpaces: false,
      guides: { indentation: false },
      autoSave: "off",
    });
    expect(settings).toMatchObject({
      bracketPairColorization: false,
      cursorStyle: "block",
      lineNumbers: "relative",
      minimap: true,
      renderWhitespace: "all",
      rulers: [80, 100],
      stickyScroll: false,
      wordWrap: "on",
      fontFamily: "JetBrains Mono",
      fontSize: 14,
      tabSize: 2,
      insertSpaces: false,
      indentGuides: false,
      autoSave: "off",
    });
  });

  test("an invalid value keeps its default", () => {
    const settings = resolveEditorSettings({
      wordWrap: "sometimes",
      fontSize: 400,
      tabSize: 0,
      rulers: [80, "x"],
      fontFamily: "a; } body { color: red",
      cursorStyle: 3,
    });
    expect(settings.wordWrap).toBe("off");
    expect(settings.fontSize).toBeNull();
    expect(settings.tabSize).toBe(4);
    expect(settings.rulers).toEqual([]);
    expect(settings.fontFamily).toBeNull();
    expect(settings.cursorStyle).toBe("line");
  });

  test("language defaults apply unless the user set the key; user overrides win", () => {
    const section = { languages: { python: { tabSize: 2 }, make: { tabSize: 8 } } };
    const settings = resolveEditorSettings(section);
    expect(settingsForLanguage(settings, "make", section)).toMatchObject({ insertSpaces: false, tabSize: 8 });
    expect(settingsForLanguage(settings, "python", section).tabSize).toBe(2);
    expect(settingsForLanguage(settings, "go", section).insertSpaces).toBe(false);
    const spaces = { insertSpaces: true };
    expect(settingsForLanguage(resolveEditorSettings(spaces), "go", spaces).insertSpaces).toBe(true);
  });
});

describe("fonts follow the terminal", () => {
  test("no font settings: the terminal font and size from the appearance", () => {
    expect(editorFont(EDITOR_DEFAULTS, { fontFamily: "Iosevka", fontSize: 13 })).toEqual({
      family: '"Iosevka", ui-monospace, SFMono-Regular, Menlo, Monaco, monospace',
      size: 13,
    });
  });

  test("the editor's own font settings win", () => {
    const settings = resolveEditorSettings({ fontFamily: "Menlo", fontSize: 15 });
    expect(editorFont(settings, { fontFamily: "Iosevka", fontSize: 13 })).toEqual({ family: "Menlo", size: 15 });
  });
});

describe("large files", () => {
  test("the threshold turns the whole-document features off", () => {
    const settings = resolveEditorSettings({ minimap: true, largeFileThreshold: 1000 });
    expect(isLargeFile(999, settings)).toBe(false);
    expect(isLargeFile(1000, settings)).toBe(true);
    const options = monacoOptions(settings, undefined, { readOnly: false, large: true, ariaLabel: "Editor" });
    expect(options).toMatchObject({
      minimap: { enabled: false },
      folding: false,
      bracketPairColorization: { enabled: false },
      stickyScroll: { enabled: false },
      occurrencesHighlight: "off",
      links: false,
      wordBasedSuggestions: "off",
    });
    expect(isLargeFile(10 ** 9, resolveEditorSettings({ largeFileThreshold: 0 }))).toBe(false);
  });

  test("Monaco options never carry undefined values (Monaco reads into them)", () => {
    const options = monacoOptions(EDITOR_DEFAULTS, undefined, { readOnly: true, large: false, ariaLabel: "E" });
    expect(Object.entries(options).filter(([, value]) => value === undefined)).toEqual([]);
    expect(options.unusualLineTerminators).toBe("off");
  });
});

describe("syntax theme and keys", () => {
  test("the shared syntax theme is terminal unless named", () => {
    expect(syntaxThemeNames(undefined)).toEqual({ light: "terminal", dark: "terminal" });
    expect(syntaxThemeNames({ light: "github-light", dark: "github-dark" })).toEqual({
      light: "github-light",
      dark: "github-dark",
    });
    expect(syntaxThemeNames("nord; x")).toEqual({ light: "terminal", dark: "terminal" });
  });

  test("page commands map to Monaco actions; editorAction only from the allowlist", () => {
    expect(editorAction("find")).toBe("actions.find");
    expect(editorAction("editorAction", "editor.action.addSelectionToNextFindMatch")).toBe(
      "editor.action.addSelectionToNextFindMatch",
    );
    expect(editorAction("editorAction", "editor.action.webvieweditor.showFind")).toBeNull();
    expect(editorAction("save")).toBeNull();
    expect(isEditorCommand("findNext")).toBe(true);
    expect(isEditorCommand("link")).toBe(false);
  });

  test("computed colors become Monaco hex", () => {
    expect(computedColorToHex("rgb(10, 20, 30)")).toBe("#0a141eff");
    expect(computedColorToHex("rgba(0, 0, 0, 0)")).toBe("#00000000");
    expect(computedColorToHex("color(srgb 1 0.5 0 / 0.5)")).toBe("#ff800080");
    expect(computedColorToHex("oklch(0.5 0.1 200)")).toBeNull();
  });
});

describe("styles.css", () => {
  test("declares every --cmux-editor-* default the settings module lists", async () => {
    const { EDITOR_STYLE_DEFAULTS } = await import("./settings");
    const css = await Bun.file(new URL("./styles.css", import.meta.url)).text();
    const block = css.slice(css.indexOf(":where(:root)"), css.indexOf("}", css.indexOf(":where(:root)")));
    for (const [name, value] of Object.entries(EDITOR_STYLE_DEFAULTS)) {
      expect(block).toContain(`${name}: ${value};`);
    }
  });
});
