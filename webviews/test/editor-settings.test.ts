// The code editor's VS Code configurability (Lawrence 2026-10-19: "same level of configurability as
// vscode"): the `editor.*` keys resolve to Monaco options, and `editor.keybindings` (VS Code's and
// Zed's key strings, imported from their files) become Monaco keybinding rules. Pure: no Monaco.
import { expect, test } from "bun:test";
import { EDITOR_DEFAULTS, monacoOptions, resolveEditorSettings } from "../src/pages/editor/settings";
import {
  keybindingEntries,
  keybindingRules,
  parseKeySequence,
  type MonacoKeyApi,
} from "../src/pages/editor/vscodeKeys";

// Monaco's values (monaco-editor 0.57 `KeyMod`, `KeyCode`).
const api: MonacoKeyApi = {
  KeyMod: {
    CtrlCmd: 2048,
    Shift: 1024,
    Alt: 512,
    WinCtrl: 256,
    chord: (first, second) => (first | ((second & 0x0000ffff) << 16)) >>> 0,
  },
  KeyCode: {
    KeyL: 42,
    KeyK: 41,
    KeyZ: 56,
    Digit0: 21,
    UpArrow: 16,
    DownArrow: 18,
    Enter: 3,
    BracketLeft: 92,
    Minus: 88,
    Equal: 86,
    F1: 59,
    Slash: 90,
  },
};

test("VS Code and Zed key strings parse to Monaco keybindings", () => {
  expect(parseKeySequence("cmd+shift+l", api)).toBe(2048 | 1024 | 42);
  expect(parseKeySequence("cmd-shift-l", api)).toBe(2048 | 1024 | 42);
  expect(parseKeySequence("alt+z", api)).toBe(512 | 56);
  expect(parseKeySequence("option-up", api)).toBe(512 | 16);
  expect(parseKeySequence("ctrl+shift+down", api)).toBe(256 | 1024 | 18);
  expect(parseKeySequence("cmd+-", api)).toBe(2048 | 88);
  expect(parseKeySequence("cmd-=", api)).toBe(2048 | 86);
  expect(parseKeySequence("cmd+[", api)).toBe(2048 | 92);
  expect(parseKeySequence("f1", api)).toBe(59);
  expect(parseKeySequence("cmd+k cmd+0", api)).toBe(api.KeyMod.chord(2048 | 41, 2048 | 21));
  expect(parseKeySequence("hyper+l", api)).toBeNull();
  expect(parseKeySequence("cmd+numpad_add", api)).toBeNull();
  expect(parseKeySequence("a b c", api)).toBeNull();
});

test("editor.keybindings keeps VS Code's entries and drops what Monaco cannot run", () => {
  const entries = keybindingEntries([
    { key: "cmd+shift+l", command: "editor.action.selectHighlights", when: "editorTextFocus" },
    { key: "cmd+k cmd+0", command: "-editor.foldAll" },
    { key: "cmd+x", command: "rm -rf /" },
    { key: 5, command: "editor.action.commentLine" },
    "not an entry",
  ]);
  expect(entries).toEqual([
    { key: "cmd+shift+l", command: "editor.action.selectHighlights", when: "editorTextFocus" },
    { key: "cmd+k cmd+0", command: "-editor.foldAll" },
  ]);
  expect(keybindingRules([...entries, { key: "hyper+q", command: "editor.action.commentLine" }], api)).toEqual([
    { keybinding: 2048 | 1024 | 42, command: "editor.action.selectHighlights", when: "editorTextFocus" },
    { keybinding: api.KeyMod.chord(2048 | 41, 2048 | 21), command: "-editor.foldAll" },
  ]);
});

test("the new editor.* keys reach Monaco's options", () => {
  const settings = resolveEditorSettings({
    letterSpacing: 0.5,
    renderControlCharacters: false,
    matchBrackets: "near",
    mouseWheelZoom: true,
    cursorSmoothCaretAnimation: true,
    cursorSurroundingLines: 3,
    multiCursorModifier: "ctrlCmd",
    linkedEditing: true,
    quickSuggestions: { other: "on", comments: "off" },
    wordBasedSuggestions: "off",
    acceptSuggestionOnEnter: "smart",
    emptySelectionClipboard: false,
    find: { seedSearchStringFromSelection: "never" },
    guides: { bracketPairs: true },
    autoClosingBrackets: "never",
    trimTrailingWhitespace: true,
    insertFinalNewline: true,
  });
  const options = monacoOptions(settings, undefined, { readOnly: false, large: false, ariaLabel: "x" });
  expect(options.letterSpacing).toBe(0.5);
  expect(options.renderControlCharacters).toBe(false);
  expect(options.matchBrackets).toBe("near");
  expect(options.mouseWheelZoom).toBe(true);
  expect(options.cursorSmoothCaretAnimation).toBe("on");
  expect(options.cursorSurroundingLines).toBe(3);
  expect(options.multiCursorModifier).toBe("ctrlCmd");
  expect(options.linkedEditing).toBe(true);
  expect(options.quickSuggestions).toBe(true);
  expect(options.wordBasedSuggestions).toBe("off");
  expect(options.acceptSuggestionOnEnter).toBe("smart");
  expect(options.emptySelectionClipboard).toBe(false);
  expect(options.find).toEqual({ seedSearchStringFromSelection: "never" });
  expect((options.guides as { bracketPairs: boolean }).bracketPairs).toBe(true);
  // Close Quotes follows Close Brackets until it is set itself.
  expect(options.autoClosingQuotes).toBe("never");
  expect(resolveEditorSettings({ autoClosingBrackets: "never", autoClosingQuotes: true }).autoClosingQuotes).toBe(true);
  expect(settings.trimTrailingWhitespace).toBe(true);
  expect(settings.insertFinalNewline).toBe(true);
});

test("the cursor is a thin bar unless the user picks another style", () => {
  // User 2026-10-21: "monaco editor default thing cursor needs to be the default bar thing".
  const options = (section: Record<string, unknown>) =>
    monacoOptions(resolveEditorSettings(section), undefined, { readOnly: false, large: false, ariaLabel: "x" });
  expect(options({}).cursorStyle).toBe("line");
  expect(options({ cursorStyle: "beam" }).cursorStyle).toBe("line");
  expect(options({ cursorStyle: "block" }).cursorStyle).toBe("block");
});

test("an editor section without the new keys resolves as before", () => {
  const settings = resolveEditorSettings({});
  expect(settings).toEqual(EDITOR_DEFAULTS);
  const options = monacoOptions(settings, undefined, { readOnly: false, large: false, ariaLabel: "x" });
  expect(options.quickSuggestions).toBe(false);
  expect(options.wordBasedSuggestions).toBe("currentDocument");
  expect(options.autoClosingQuotes).toBe("languageDefined");
  // A large file keeps every costly feature off whatever the settings say.
  const large = monacoOptions(
    resolveEditorSettings({ quickSuggestions: true, guides: { bracketPairs: true } }),
    undefined,
    {
      readOnly: false,
      large: true,
      ariaLabel: "x",
    },
  );
  expect(large.quickSuggestions).toBe(false);
  expect((large.guides as { bracketPairs: boolean }).bracketPairs).toBe(false);
});

test("the editor types through its textarea, never Chromium's EditContext", () => {
  // The app's key router delivers typing only once a page reports an input, textarea or
  // contenteditable focused (PageInputReadiness); an EditContext element never qualifies.
  const options = monacoOptions(resolveEditorSettings(undefined), undefined, {
    readOnly: false,
    large: false,
    ariaLabel: "x",
  });
  expect(options.editContext).toBe(false);
});
