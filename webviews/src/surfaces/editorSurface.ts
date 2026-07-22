/**
 * CodeMirror 6 code editor surface, hosted by `CodeEditorWebRenderer` on the
 * Swift side (FilePreview panels with `fileEditor.engine = "code"`).
 *
 * The webview owns the live buffer; Swift owns file IO. Swift pushes disk
 * changes and theme/option updates through `window.cmuxEditorBridge.receive`,
 * pulls the buffer via `window.cmuxEditorHost.getContent()`, and receives
 * debounced dirty-state changes plus Cmd+S saves over the `cmuxEditor` bridge.
 */
import { closeBrackets, closeBracketsKeymap } from "@codemirror/autocomplete";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import {
  LanguageDescription,
  bracketMatching,
  defaultHighlightStyle,
  foldGutter,
  foldKeymap,
  indentOnInput,
  syntaxHighlighting,
} from "@codemirror/language";
import { languages } from "@codemirror/language-data";
import { highlightSelectionMatches, search, searchKeymap } from "@codemirror/search";
import { Compartment, EditorState } from "@codemirror/state";
import {
  EditorView,
  drawSelection,
  dropCursor,
  highlightActiveLine,
  highlightActiveLineGutter,
  highlightSpecialChars,
  keymap,
  lineNumbers,
} from "@codemirror/view";
import { oneDarkHighlightStyle } from "@codemirror/theme-one-dark";
import { installWebviewStyles } from "./installWebviewStyles";
import {
  callNative,
  subscribeToHostEvents,
  type EditorCopy,
  type EditorReadyReply,
  type EditorTheme,
} from "./editor/bridge";
import { DocumentSession } from "./editor/documentSession";

const DIRTY_NOTIFY_DEBOUNCE_MS = 100;

const surfaceStyles = `
  html, body {
    margin: 0;
    height: 100%;
    background: transparent;
    overscroll-behavior: none;
  }
  #root {
    display: flex;
    flex-direction: column;
    height: 100%;
  }
  .cmux-editor-banner {
    display: none;
    align-items: center;
    gap: 8px;
    padding: 6px 10px;
    font: 12px -apple-system, system-ui, sans-serif;
    color: var(--cmux-editor-fg, #000);
    background: var(--cmux-editor-surface, rgba(127, 127, 127, 0.15));
    border-bottom: 1px solid var(--cmux-editor-border, rgba(127, 127, 127, 0.4));
  }
  .cmux-editor-banner.cmux-editor-banner-visible {
    display: flex;
  }
  .cmux-editor-banner-message {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .cmux-editor-banner-error .cmux-editor-banner-message {
    color: var(--cmux-editor-danger, #b3261e);
  }
  .cmux-editor-banner button {
    font: inherit;
    padding: 2px 10px;
    border-radius: 5px;
    border: 1px solid var(--cmux-editor-border, rgba(127, 127, 127, 0.4));
    background: transparent;
    color: var(--cmux-editor-fg, #000);
    cursor: pointer;
  }
  .cmux-editor-banner button.cmux-editor-banner-primary {
    background: var(--cmux-editor-accent-soft, rgba(0, 122, 255, 0.18));
    border-color: var(--cmux-editor-accent, #007aff);
  }
  .cmux-editor-container {
    flex: 1;
    min-height: 0;
  }
  .cmux-editor-container .cm-editor {
    height: 100%;
  }
`;

const editorChrome = EditorView.theme({
  "&": {
    backgroundColor: "var(--cmux-editor-bg, transparent)",
    color: "var(--cmux-editor-fg, inherit)",
    fontSize: "12px",
  },
  ".cm-scroller": {
    fontFamily: "ui-monospace, 'SF Mono', Menlo, monospace",
    lineHeight: "1.5",
  },
  ".cm-content": {
    caretColor: "var(--cmux-editor-fg, auto)",
  },
  ".cm-gutters": {
    backgroundColor: "transparent",
    color: "var(--cmux-editor-muted, inherit)",
    border: "none",
  },
  ".cm-activeLineGutter": {
    backgroundColor: "transparent",
    color: "var(--cmux-editor-fg, inherit)",
  },
  ".cm-activeLine": {
    backgroundColor: "color-mix(in srgb, var(--cmux-editor-fg, currentColor) 5%, transparent)",
  },
  "&.cm-focused .cm-cursor": {
    borderLeftColor: "var(--cmux-editor-fg, auto)",
  },
  "&.cm-focused > .cm-scroller .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground, & ::selection": {
    backgroundColor: "var(--cmux-editor-accent-soft, rgba(0, 122, 255, 0.2)) !important",
  },
  ".cm-panels": {
    backgroundColor: "var(--cmux-editor-panel, Canvas)",
    color: "var(--cmux-editor-fg, inherit)",
    border: "none",
  },
  ".cm-panels.cm-panels-top": {
    borderBottom: "1px solid var(--cmux-editor-border, rgba(127, 127, 127, 0.4))",
  },
  ".cm-panels.cm-panels-bottom": {
    borderTop: "1px solid var(--cmux-editor-border, rgba(127, 127, 127, 0.4))",
  },
});

function applyThemeVariables(theme: EditorTheme): void {
  const style = document.documentElement.style;
  style.setProperty("--cmux-editor-bg", theme.pageBackground);
  style.setProperty("--cmux-editor-fg", theme.text);
  style.setProperty("--cmux-editor-muted", theme.mutedText);
  style.setProperty("--cmux-editor-accent", theme.accent);
  style.setProperty("--cmux-editor-accent-soft", theme.accentSoft);
  style.setProperty("--cmux-editor-border", theme.border);
  style.setProperty("--cmux-editor-surface", theme.surfaceBackground);
  style.setProperty("--cmux-editor-panel", theme.surfaceElevatedBackground);
  style.setProperty("--cmux-editor-danger", theme.danger);
  style.setProperty("color-scheme", theme.isDark ? "dark" : "light");
}

function themedExtensions(isDark: boolean) {
  return [editorChrome, syntaxHighlighting(isDark ? oneDarkHighlightStyle : defaultHighlightStyle, { fallback: true })];
}

// CodeMirror's built-in UI phrases (search panel, go-to-line, fold
// placeholders) for non-English app locales, applied via EditorState.phrases.
const japanesePhrases: Record<string, string> = {
  // @codemirror/search
  "Find": "検索",
  "Replace": "置換",
  "next": "次へ",
  "previous": "前へ",
  "all": "すべて",
  "match case": "大文字と小文字を区別",
  "by word": "単語単位",
  "regexp": "正規表現",
  "replace": "置換",
  "replace all": "すべて置換",
  "close": "閉じる",
  "current match": "現在の一致",
  "replaced $ matches": "$ 件置換しました",
  "replaced match on line $": "$ 行目の一致を置換しました",
  "on line": "行",
  "Go to line": "行へ移動",
  "go": "移動",
  // @codemirror/language + @codemirror/view
  "Folded lines": "折りたたまれた行",
  "unfold": "展開",
  "Fold line": "行を折りたたむ",
  "Unfold line": "行を展開",
  "Control character": "制御文字",
  "Selection deleted": "選択範囲を削除しました"
};

function localePhrases(locale: string) {
  return locale.toLowerCase().startsWith("ja") ? [EditorState.phrases.of(japanesePhrases)] : [];
}

function wrapExtensions(wordWrap: boolean) {
  return wordWrap ? [EditorView.lineWrapping] : [];
}

interface Banner {
  show(kind: "conflict" | "error"): void;
  hide(): void;
  element: HTMLElement;
}

function makeBanner(copy: EditorCopy, onReload: () => void, onKeepMine: () => void): Banner {
  const element = document.createElement("div");
  element.className = "cmux-editor-banner";
  const message = document.createElement("span");
  message.className = "cmux-editor-banner-message";
  const reload = document.createElement("button");
  reload.className = "cmux-editor-banner-primary";
  reload.textContent = copy.reloadFromDisk;
  reload.addEventListener("click", onReload);
  const keep = document.createElement("button");
  keep.textContent = copy.keepMyChanges;
  keep.addEventListener("click", onKeepMine);
  element.append(message, reload, keep);
  return {
    element,
    show(kind) {
      const isConflict = kind === "conflict";
      message.textContent = isConflict ? copy.fileChangedOnDisk : copy.saveFailed;
      element.classList.toggle("cmux-editor-banner-error", !isConflict);
      reload.style.display = isConflict ? "" : "none";
      keep.style.display = isConflict ? "" : "none";
      element.classList.add("cmux-editor-banner-visible");
    },
    hide() {
      element.classList.remove("cmux-editor-banner-visible");
    },
  };
}

async function start(rootElement: HTMLElement): Promise<void> {
  const ready = await callNative<EditorReadyReply>("editor.ready");
  applyThemeVariables(ready.theme);
  installWebviewStyles("editor", surfaceStyles);

  const session = new DocumentSession(ready.diskContent);
  const languageCompartment = new Compartment();
  const themeCompartment = new Compartment();
  const wrapCompartment = new Compartment();

  let lastNotifiedDirty = session.isDirty(ready.content);
  let dirtyNotifyTimer: ReturnType<typeof setTimeout> | null = null;
  let saveInFlight = false;

  const notifyDirtyIfChanged = () => {
    const isDirty = session.isDirty(view.state.doc.toString());
    if (isDirty === lastNotifiedDirty) {
      return;
    }
    lastNotifiedDirty = isDirty;
    void callNative("editor.dirtyChanged", { isDirty }).catch(() => {});
  };

  const scheduleDirtyNotify = () => {
    if (dirtyNotifyTimer !== null) {
      clearTimeout(dirtyNotifyTimer);
    }
    dirtyNotifyTimer = setTimeout(() => {
      dirtyNotifyTimer = null;
      notifyDirtyIfChanged();
    }, DIRTY_NOTIFY_DEBOUNCE_MS);
  };

  const replaceBuffer = (content: string) => {
    const previousSelection = view.state.selection.main.head;
    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: content },
      selection: { anchor: Math.min(previousSelection, content.length) },
    });
  };

  const performSave = async (): Promise<void> => {
    if (saveInFlight) {
      return;
    }
    saveInFlight = true;
    const content = view.state.doc.toString();
    try {
      const reply = await callNative<{ saved: boolean }>("editor.save", { content });
      if (reply.saved) {
        session.noteSaved(content);
        banner.hide();
      } else {
        banner.show("error");
      }
    } catch {
      banner.show("error");
    } finally {
      saveInFlight = false;
      notifyDirtyIfChanged();
    }
  };

  const banner = makeBanner(
    ready.copy,
    () => {
      replaceBuffer(session.resolveConflictReload());
      banner.hide();
      notifyDirtyIfChanged();
      view.focus();
    },
    () => {
      session.resolveConflictKeepMine();
      banner.hide();
      notifyDirtyIfChanged();
      view.focus();
    },
  );

  const view = new EditorView({
    state: EditorState.create({
      doc: ready.content,
      extensions: [
        lineNumbers(),
        highlightActiveLineGutter(),
        highlightSpecialChars(),
        history(),
        foldGutter(),
        drawSelection(),
        dropCursor(),
        indentOnInput(),
        bracketMatching(),
        closeBrackets(),
        highlightActiveLine(),
        highlightSelectionMatches(),
        search({ top: true }),
        keymap.of([
          {
            key: "Mod-s",
            run: () => {
              void performSave();
              return true;
            },
          },
          ...closeBracketsKeymap,
          ...defaultKeymap,
          ...searchKeymap,
          ...historyKeymap,
          ...foldKeymap,
          indentWithTab,
        ]),
        languageCompartment.of([]),
        themeCompartment.of(themedExtensions(ready.theme.isDark)),
        wrapCompartment.of(wrapExtensions(ready.wordWrap)),
        localePhrases(ready.locale ?? "en"),
        EditorView.updateListener.of((update) => {
          if (update.docChanged) {
            scheduleDirtyNotify();
          }
        }),
      ],
    }),
  });

  const container = document.createElement("div");
  container.className = "cmux-editor-container";
  container.append(view.dom);
  rootElement.append(banner.element, container);

  window.cmuxEditorHost = {
    getContent: () => view.state.doc.toString(),
  };

  subscribeToHostEvents((event) => {
    switch (event.type) {
      case "document.external": {
        const action = session.applyExternal(view.state.doc.toString(), event.content);
        if (action.kind === "replaceBuffer") {
          replaceBuffer(action.content);
          banner.hide();
        } else if (action.kind === "showConflict") {
          banner.show("conflict");
        } else {
          banner.hide();
        }
        notifyDirtyIfChanged();
        break;
      }
      case "document.saved": {
        session.noteSaved(event.content);
        banner.hide();
        notifyDirtyIfChanged();
        break;
      }
      case "app.theme": {
        applyThemeVariables(event.theme);
        view.dispatch({ effects: themeCompartment.reconfigure(themedExtensions(event.theme.isDark)) });
        break;
      }
      case "app.options": {
        view.dispatch({ effects: wrapCompartment.reconfigure(wrapExtensions(event.wordWrap)) });
        break;
      }
    }
  });

  const fileName = ready.path.split("/").pop() ?? ready.path;
  const description = LanguageDescription.matchFilename(languages, fileName);
  if (description) {
    void description.load().then((support) => {
      view.dispatch({ effects: languageCompartment.reconfigure(support) });
    });
  }

  window.addEventListener("focus", () => {
    view.focus();
  });
  if (document.hasFocus()) {
    view.focus();
  }
}

export function mountEditorSurface(rootElement: HTMLElement): void {
  void start(rootElement);
}
