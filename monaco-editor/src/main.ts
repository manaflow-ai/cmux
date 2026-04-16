import * as monaco from "monaco-editor";

import editorWorker from "monaco-editor/esm/vs/editor/editor.worker?worker";
import cssWorker from "monaco-editor/esm/vs/language/css/css.worker?worker";
import htmlWorker from "monaco-editor/esm/vs/language/html/html.worker?worker";
import jsonWorker from "monaco-editor/esm/vs/language/json/json.worker?worker";
import tsWorker from "monaco-editor/esm/vs/language/typescript/ts.worker?worker";

import {
  postToSwift,
  type InboundMessage,
  type OutboundCommand,
} from "./bridge";
import { applyCmuxPalette, registerCmuxThemes } from "./theme";

// Intentionally do NOT forward every console.log to Swift: running
// postMessage on every log during typing adds cross-process work to the
// hot path. If you need JS timings, attach the webview inspector.

// Route Monaco worker requests to the bundled workers.
self.MonacoEnvironment = {
  getWorker(_moduleId: unknown, label: string) {
    switch (label) {
      case "json":
        return new jsonWorker();
      case "css":
      case "scss":
      case "less":
        return new cssWorker();
      case "html":
      case "handlebars":
      case "razor":
        return new htmlWorker();
      case "typescript":
      case "javascript":
        return new tsWorker();
      default:
        return new editorWorker();
    }
  },
};

registerCmuxThemes(monaco);

const container = document.getElementById("root");
if (!container) {
  throw new Error("cmux monaco: missing #root");
}

const editor = monaco.editor.create(container, {
  value: "",
  language: "plaintext",
  theme: "cmux-dark",
  // automaticLayout polls the container every 100ms and forces synchronous
  // layout, which fights with SwiftUI + WKWebView compositing. A ResizeObserver
  // on the host element is the low-overhead path.
  automaticLayout: false,
  fontFamily:
    "ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Monaco, Consolas, 'Liberation Mono', 'Courier New', monospace",
  fontSize: 13,
  lineNumbers: "on",
  minimap: { enabled: false },
  scrollBeyondLastLine: true,
  // Smooth-scroll/caret animations read as input lag during rapid typing.
  smoothScrolling: false,
  cursorSmoothCaretAnimation: "off",
  cursorBlinking: "solid",
  renderLineHighlight: "line",
  wordWrap: "off",
  tabSize: 2,
  insertSpaces: true,
  renderWhitespace: "selection",
  bracketPairColorization: { enabled: true },
});

// Replace Monaco's polling `automaticLayout` with a ResizeObserver. Fires at
// most once per actual size change, avoids the 100ms timer, and doesn't
// re-enter WebKit layout during typing.
const resizeObserver = new ResizeObserver(() => {
  editor.layout();
});
resizeObserver.observe(container);

// --- Outbound events ---------------------------------------------------------

let ignoreNextChange = false;
let changedDebounceHandle: number | null = null;

function flushChanged(): void {
  if (changedDebounceHandle !== null) {
    window.clearTimeout(changedDebounceHandle);
    changedDebounceHandle = null;
  }
  const model = editor.getModel();
  if (!model) return;
  const sel = editor.getSelection();
  const offset = sel ? model.getOffsetAt(sel.getStartPosition()) : 0;
  const end = sel ? model.getOffsetAt(sel.getEndPosition()) : offset;
  postToSwift({
    type: "changed",
    value: model.getValue(),
    cursor: { offset, length: Math.max(0, end - offset) },
    versionId: model.getVersionId(),
  });
}

function scheduleChangedFlush(): void {
  if (changedDebounceHandle !== null) return;
  // 120ms is tight enough to feel live in the tab title's dirty indicator while
  // still coalescing bursts of fast typing into one cross-bridge JSON roundtrip.
  changedDebounceHandle = window.setTimeout(() => {
    changedDebounceHandle = null;
    flushChanged();
  }, 120);
}

// Track whether the buffer is currently dirty (differs from the version at
// last save or last host-initiated setText) so we can send a sync `dirty`
// ping on every keystroke without doing the full buffer roundtrip.
let lastNotifiedDirty: boolean | null = null;
let savedVersionId = editor.getModel()?.getVersionId() ?? 1;

editor.onDidChangeModelContent(() => {
  if (ignoreNextChange) {
    ignoreNextChange = false;
    return;
  }
  scheduleChangedFlush();
  const model = editor.getModel();
  if (!model) return;
  const isDirty = model.getVersionId() !== savedVersionId;
  if (isDirty !== lastNotifiedDirty) {
    lastNotifiedDirty = isDirty;
    postToSwift({ type: "dirty", isDirty, versionId: model.getVersionId() });
  }
});

// Any time the editor or window loses focus, immediately flush any pending
// debounced content so Swift's close / save-on-close logic sees the latest
// buffer. Without this, Cmd+W right after a keystroke can beat the 120ms
// debounce and drop the user's edits without prompting.
editor.onDidBlurEditorWidget(flushChanged);
editor.onDidBlurEditorText(flushChanged);
window.addEventListener("blur", flushChanged);
window.addEventListener("pagehide", flushChanged);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "hidden") flushChanged();
});

// Debounced snapshot of cursor + scroll + Monaco view state.
let snapshotHandle: number | null = null;
function scheduleViewStateSnapshot(): void {
  if (snapshotHandle !== null) return;
  snapshotHandle = window.setTimeout(() => {
    snapshotHandle = null;
    publishViewState();
  }, 250);
}

function scrollTopFraction(): number {
  const scrollTop = editor.getScrollTop();
  const scrollHeight = editor.getScrollHeight();
  const containerHeight = editor.getLayoutInfo().height;
  const denom = Math.max(1, scrollHeight - containerHeight);
  return Math.min(1, Math.max(0, scrollTop / denom));
}

function publishViewState(): void {
  const model = editor.getModel();
  if (!model) return;
  const sel = editor.getSelection();
  const start = sel ? model.getOffsetAt(sel.getStartPosition()) : 0;
  const end = sel ? model.getOffsetAt(sel.getEndPosition()) : start;
  const monacoViewState = editor.saveViewState();
  // Intentionally omit the buffer: `changed` already owns content sync. This
  // message is pure view-state (cursor, selections, folds, scroll). Sending
  // the full value on every 250ms snapshot during typing was wasted JSON work.
  postToSwift({
    type: "viewState",
    cursor: { offset: start, length: Math.max(0, end - start) },
    scrollTopFraction: scrollTopFraction(),
    monacoViewState: monacoViewState ? JSON.stringify(monacoViewState) : "",
  });
}

editor.onDidChangeCursorPosition(scheduleViewStateSnapshot);
editor.onDidChangeCursorSelection(scheduleViewStateSnapshot);
editor.onDidScrollChange(scheduleViewStateSnapshot);

// Save shortcut is owned by the Swift host (`KeyboardShortcutSettings.saveEditorFile`)
// so users can rebind or disable it. `MonacoHostingWebView.performKeyEquivalent`
// intercepts the keystroke and tells Swift to do the save. We deliberately do
// NOT register a Monaco command here — that would hardcode Cmd+S and compete
// with the configured binding.

// --- Inbound command router --------------------------------------------------

function setModelText(value: string, languageId: string, preserveViewState: boolean): void {
  const model = editor.getModel();
  const state = preserveViewState ? editor.saveViewState() : null;
  const desiredLang = languageId || "plaintext";
  if (model && model.getLanguageId() === desiredLang) {
    if (model.getValue() !== value) {
      ignoreNextChange = true;
      model.setValue(value);
    }
  } else {
    const uri = monaco.Uri.parse(`inmemory://cmux/${Date.now()}`);
    const next = monaco.editor.createModel(value, desiredLang, uri);
    editor.setModel(next);
    if (model) model.dispose();
  }
  if (state) editor.restoreViewState(state);
  // Host just pushed the canonical value: mark this versionId as the
  // saved/clean baseline so the next keystroke transitions to dirty.
  savedVersionId = editor.getModel()?.getVersionId() ?? 1;
  if (lastNotifiedDirty !== false) {
    lastNotifiedDirty = false;
    postToSwift({ type: "dirty", isDirty: false, versionId: savedVersionId });
  }
}

function setCursorFromOffset(offset: number, length: number): void {
  const model = editor.getModel();
  if (!model) return;
  const total = model.getValueLength();
  const start = Math.max(0, Math.min(offset, total));
  const end = Math.max(start, Math.min(start + Math.max(0, length), total));
  const startPos = model.getPositionAt(start);
  const endPos = model.getPositionAt(end);
  editor.setSelection(monaco.Range.fromPositions(startPos, endPos));
  editor.revealPositionInCenterIfOutsideViewport(startPos);
}

function apply(cmd: OutboundCommand): void {
  switch (cmd.kind) {
    case "setText":
      setModelText(cmd.value, cmd.languageId, cmd.preserveViewState);
      return;
    case "setCursor":
      setCursorFromOffset(cmd.offset, cmd.length);
      return;
    case "restoreViewState": {
      let restored = false;
      if (cmd.monacoViewState) {
        try {
          const parsed = JSON.parse(cmd.monacoViewState);
          restored = editor.restoreViewState(parsed) !== undefined;
        } catch {
          restored = false;
        }
      }
      if (!restored && cmd.cursorOffset !== null) {
        setCursorFromOffset(cmd.cursorOffset, cmd.cursorLength ?? 0);
      }
      if (!restored && cmd.scrollTopFraction !== null) {
        const denom = Math.max(
          1,
          editor.getScrollHeight() - editor.getLayoutInfo().height,
        );
        editor.setScrollTop(cmd.scrollTopFraction * denom);
      }
      return;
    }
    case "setTheme": {
      applyCmuxPalette(monaco, {
        isDark: cmd.isDark,
        backgroundHex: cmd.backgroundHex,
        foregroundHex: cmd.foregroundHex,
        cursorHex: cmd.cursorHex,
        selectionBackgroundHex: cmd.selectionBackgroundHex,
        ansi: cmd.ansi,
      });
      const updates: monaco.editor.IEditorOptions = {};
      if (cmd.fontFamily) {
        // Append ui-monospace as a fallback so Monaco still renders nicely when
        // Ghostty's configured family is missing locally (remote workspaces).
        updates.fontFamily = `${quoteFontFamily(cmd.fontFamily)}, ui-monospace, SFMono-Regular, Menlo, monospace`;
      }
      if (typeof cmd.fontSize === "number" && cmd.fontSize > 0) {
        updates.fontSize = cmd.fontSize;
      }
      if (Object.keys(updates).length > 0) {
        editor.updateOptions(updates);
      }
      return;
    }
    case "setLanguage": {
      const model = editor.getModel();
      if (model) monaco.editor.setModelLanguage(model, cmd.languageId || "plaintext");
      return;
    }
    case "focus":
      editor.focus();
      return;
  }
}

window.cmuxMonaco = {
  apply,
  // Force-flush any debounced changed message. Invoked from Swift via
  // evaluateJavaScript right before a close decision so the host always
  // sees the latest buffer before running the dirty check.
  flushPendingEdits: flushChanged,
  // Synchronous current buffer read. Used by the save path: Swift pulls the
  // live contents, writes them to panel.content, then performs disk save.
  // Returns "" when model is somehow gone.
  getValue(): string {
    return editor.getModel()?.getValue() ?? "";
  },
  // Called from Swift AFTER a successful disk save so Monaco's dirty
  // detection treats the current model version as the new clean baseline.
  // Without this, the buffer stays "dirty" from Monaco's perspective even
  // though disk matches, and subsequent edits don't emit a fresh dirty=true
  // transition.
  markSaved(): void {
    const model = editor.getModel();
    if (!model) return;
    savedVersionId = model.getVersionId();
    if (lastNotifiedDirty !== false) {
      lastNotifiedDirty = false;
      postToSwift({ type: "dirty", isDirty: false, versionId: savedVersionId });
    }
  },
};

function quoteFontFamily(name: string): string {
  if (/^[A-Za-z0-9_-]+$/.test(name)) return name;
  return `"${name.replace(/"/g, '\\"')}"`;
}

// Signal readiness: Swift will respond with setText / restoreViewState / setTheme.
const readyMessage: InboundMessage = { type: "ready" };
postToSwift(readyMessage);
