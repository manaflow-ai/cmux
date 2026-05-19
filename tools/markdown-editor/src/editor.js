import { autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap } from "@codemirror/autocomplete";
import {
  defaultKeymap,
  deleteCharBackward,
  history,
  historyKeymap,
  indentWithTab
} from "@codemirror/commands";
import { markdown, deleteMarkupBackward, insertNewlineContinueMarkup } from "@codemirror/lang-markdown";
import {
  bracketMatching,
  foldGutter,
  foldKeymap,
  HighlightStyle,
  indentOnInput,
  syntaxHighlighting
} from "@codemirror/language";
import { lintKeymap } from "@codemirror/lint";
import {
  highlightSelectionMatches,
  openSearchPanel,
  search,
  searchKeymap
} from "@codemirror/search";
import {
  Compartment,
  EditorSelection,
  EditorState,
  RangeSetBuilder,
  Transaction
} from "@codemirror/state";
import {
  crosshairCursor,
  Decoration,
  drawSelection,
  dropCursor,
  EditorView,
  highlightActiveLine,
  highlightActiveLineGutter,
  keymap,
  lineNumbers,
  rectangularSelection,
  ViewPlugin,
  WidgetType
} from "@codemirror/view";
import { tags as t } from "@lezer/highlight";

const bridgeName = "cmuxMarkdownEditor";
const themeCompartment = new Compartment();
const highlightCompartment = new Compartment();

let view = null;
let knownDocument = "";
let suppressChange = false;
let localizedStrings = defaultStrings();

function defaultStrings() {
  return {
    taskComplete: "Completed task",
    taskIncomplete: "Incomplete task"
  };
}

function post(message) {
  try {
    const handler = window.webkit?.messageHandlers?.[bridgeName];
    if (handler) {
      handler.postMessage(message);
    }
  } catch (_) {
    /* Bridge failures should not break editing. */
  }
}

function normalizeTheme(theme = {}) {
  return {
    isDark: Boolean(theme.isDark),
    background: theme.background || "transparent",
    foreground: theme.foreground || (theme.isDark ? "#d6d6d6" : "#24292f"),
    mutedForeground: theme.mutedForeground || (theme.isDark ? "#8b949e" : "#57606a"),
    border: theme.border || (theme.isDark ? "#30363d" : "#d0d7de"),
    mutedBackground: theme.mutedBackground || (theme.isDark ? "rgba(255,255,255,0.06)" : "rgba(0,0,0,0.035)"),
    activeLine: theme.activeLine || (theme.isDark ? "rgba(255,255,255,0.045)" : "rgba(0,0,0,0.035)"),
    selection: theme.selection || (theme.isDark ? "rgba(83,155,245,0.35)" : "rgba(9,105,218,0.20)"),
    caret: theme.caret || theme.foreground || (theme.isDark ? "#ffffff" : "#24292f"),
    accent: theme.accent || (theme.isDark ? "#7aa2f7" : "#0969da"),
    codeBackground: theme.codeBackground || (theme.isDark ? "rgba(255,255,255,0.07)" : "rgba(175,184,193,0.20)"),
    calloutBackground: theme.calloutBackground || (theme.isDark ? "rgba(56,139,253,0.12)" : "rgba(9,105,218,0.08)")
  };
}

function editorTheme(themeConfig) {
  const theme = normalizeTheme(themeConfig);
  return EditorView.theme({
    "&": {
      height: "100%",
      color: theme.foreground,
      backgroundColor: theme.background,
      fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    },
    ".cm-scroller": {
      height: "100%",
      overflow: "auto",
      fontFamily: 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace',
      fontSize: "13px",
      lineHeight: "1.55"
    },
    ".cm-content": {
      minHeight: "100%",
      padding: "16px 0 32px",
      caretColor: theme.caret
    },
    ".cm-line": {
      padding: "0 30px 0 18px"
    },
    ".cm-gutters": {
      backgroundColor: theme.background,
      color: theme.mutedForeground,
      borderRight: `1px solid ${theme.border}`
    },
    ".cm-lineNumbers .cm-gutterElement": {
      padding: "0 10px 0 14px"
    },
    ".cm-activeLine": {
      backgroundColor: theme.activeLine
    },
    ".cm-activeLineGutter": {
      backgroundColor: theme.activeLine,
      color: theme.foreground
    },
    ".cm-selectionBackground, &.cm-focused .cm-selectionBackground, ::selection": {
      backgroundColor: `${theme.selection} !important`
    },
    "&.cm-focused": {
      outline: "none"
    },
    ".cm-cursor": {
      borderLeftColor: theme.caret
    },
    ".cm-matchingBracket, .cm-nonmatchingBracket": {
      backgroundColor: theme.mutedBackground,
      outline: `1px solid ${theme.border}`
    },
    ".cm-foldGutter .cm-gutterElement": {
      color: theme.mutedForeground,
      cursor: "default"
    },
    ".cm-search": {
      backgroundColor: theme.mutedBackground,
      color: theme.foreground,
      borderTop: `1px solid ${theme.border}`
    },
    ".cm-tooltip": {
      backgroundColor: theme.mutedBackground,
      color: theme.foreground,
      border: `1px solid ${theme.border}`
    },
    ".cm-tooltip-autocomplete ul li[aria-selected]": {
      backgroundColor: theme.selection,
      color: theme.foreground
    },
    ".cm-wikilink": {
      color: theme.accent,
      textDecoration: "none",
      cursor: "default"
    },
    ".cm-tag": {
      color: theme.accent,
      backgroundColor: theme.mutedBackground,
      borderRadius: "4px",
      padding: "0 2px"
    },
    ".cm-formatting-callout": {
      backgroundColor: theme.calloutBackground
    },
    ".cm-callout-line": {
      borderLeft: `3px solid ${theme.accent}`,
      backgroundColor: theme.calloutBackground
    },
    ".cm-task-checkbox": {
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center",
      width: "3ch"
    },
    ".cm-task-checkbox input": {
      width: "13px",
      height: "13px",
      margin: "0",
      accentColor: theme.accent,
      verticalAlign: "middle"
    },
    ".cm-inline-code": {
      backgroundColor: theme.codeBackground,
      borderRadius: "4px",
      padding: "0 2px"
    }
  }, { dark: theme.isDark });
}

function markdownHighlight(themeConfig) {
  const theme = normalizeTheme(themeConfig);
  return HighlightStyle.define([
    { tag: t.heading1, color: theme.foreground, fontWeight: "700", fontSize: "1.45em" },
    { tag: t.heading2, color: theme.foreground, fontWeight: "700", fontSize: "1.25em" },
    { tag: t.heading3, color: theme.foreground, fontWeight: "700", fontSize: "1.12em" },
    { tag: [t.heading4, t.heading5, t.heading6], color: theme.foreground, fontWeight: "650" },
    { tag: [t.processingInstruction, t.meta], color: theme.mutedForeground },
    { tag: [t.strong], fontWeight: "700" },
    { tag: [t.emphasis], fontStyle: "italic" },
    { tag: [t.link, t.url], color: theme.accent, textDecoration: "none" },
    { tag: [t.quote], color: theme.mutedForeground },
    { tag: [t.monospace, t.special(t.string)], class: "cm-inline-code" },
    { tag: [t.atom, t.bool, t.number], color: theme.accent },
    { tag: [t.comment], color: theme.mutedForeground },
    { tag: [t.keyword], color: theme.accent },
    { tag: [t.string], color: theme.foreground },
    { tag: [t.variableName, t.definition(t.variableName)], color: theme.foreground }
  ]);
}

class TaskCheckboxWidget extends WidgetType {
  constructor(from, checked) {
    super();
    this.from = from;
    this.checked = checked;
  }

  eq(other) {
    return other.from === this.from && other.checked === this.checked;
  }

  toDOM(editorView) {
    const wrapper = document.createElement("span");
    wrapper.className = "cm-task-checkbox";

    const checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.checked = this.checked;
    checkbox.setAttribute(
      "aria-label",
      this.checked ? localizedStrings.taskComplete : localizedStrings.taskIncomplete
    );
    checkbox.addEventListener("mousedown", event => {
      event.preventDefault();
    });
    checkbox.addEventListener("click", event => {
      event.preventDefault();
      editorView.dispatch({
        changes: {
          from: this.from,
          to: this.from + 3,
          insert: this.checked ? "[ ]" : "[x]"
        }
      });
      editorView.focus();
    });

    wrapper.appendChild(checkbox);
    return wrapper;
  }

  ignoreEvent() {
    return false;
  }
}

function taskCheckboxDecorations(editorView) {
  const builder = new RangeSetBuilder();
  for (const { from, to } of editorView.visibleRanges) {
    let line = editorView.state.doc.lineAt(from);
    while (line.from <= to) {
      const text = line.text;
      const match = /^(\s*(?:[-*+]|\d+[.)])\s+)(\[[ xX]\])/.exec(text);
      if (match) {
        const checkboxFrom = line.from + match[1].length;
        const checkboxTo = checkboxFrom + 3;
        const checked = /[xX]/.test(match[2]);
        builder.add(
          checkboxFrom,
          checkboxTo,
          Decoration.replace({
            widget: new TaskCheckboxWidget(checkboxFrom, checked)
          })
        );
      }
      if (line.number >= editorView.state.doc.lines) {
        break;
      }
      line = editorView.state.doc.line(line.number + 1);
    }
  }
  return builder.finish();
}

const taskCheckboxPlugin = ViewPlugin.fromClass(class {
  constructor(editorView) {
    this.decorations = taskCheckboxDecorations(editorView);
  }

  update(update) {
    if (update.docChanged || update.viewportChanged) {
      this.decorations = taskCheckboxDecorations(update.view);
    }
  }
}, {
  decorations: plugin => plugin.decorations
});

function obsidianDecorationsFor(editorView) {
  const builder = new RangeSetBuilder();
  const wikiPattern = /!?\[\[[^\]\n]+\]\]/g;
  const tagPattern = /(^|[\s([{])#([A-Za-z0-9_/-]+)(?![A-Za-z0-9_/-])/g;

  for (const { from, to } of editorView.visibleRanges) {
    let line = editorView.state.doc.lineAt(from);
    while (line.from <= to) {
      const text = line.text;
      if (/^\s*>\s*\[![^\]]+\]/i.test(text)) {
        builder.add(line.from, line.from, Decoration.line({ class: "cm-callout-line" }));
        const calloutStart = text.indexOf("[!");
        const calloutEnd = text.indexOf("]", calloutStart);
        if (calloutStart >= 0 && calloutEnd > calloutStart) {
          builder.add(
            line.from + calloutStart,
            line.from + calloutEnd + 1,
            Decoration.mark({ class: "cm-formatting-callout" })
          );
        }
      }

      wikiPattern.lastIndex = 0;
      let wikiMatch;
      while ((wikiMatch = wikiPattern.exec(text)) !== null) {
        builder.add(
          line.from + wikiMatch.index,
          line.from + wikiMatch.index + wikiMatch[0].length,
          Decoration.mark({ class: "cm-wikilink" })
        );
      }

      tagPattern.lastIndex = 0;
      let tagMatch;
      while ((tagMatch = tagPattern.exec(text)) !== null) {
        const start = line.from + tagMatch.index + tagMatch[1].length;
        const end = start + tagMatch[2].length + 1;
        builder.add(start, end, Decoration.mark({ class: "cm-tag" }));
      }

      if (line.number >= editorView.state.doc.lines) {
        break;
      }
      line = editorView.state.doc.line(line.number + 1);
    }
  }

  return builder.finish();
}

const obsidianDecorationPlugin = ViewPlugin.fromClass(class {
  constructor(editorView) {
    this.decorations = obsidianDecorationsFor(editorView);
  }

  update(update) {
    if (update.docChanged || update.viewportChanged) {
      this.decorations = obsidianDecorationsFor(update.view);
    }
  }
}, {
  decorations: plugin => plugin.decorations
});

function normalizeWikiTarget(rawTarget) {
  let target = rawTarget
    .replace(/^!?\[\[/, "")
    .replace(/\]\]$/, "")
    .split("|")[0]
    .trim();
  if (!target) {
    return "";
  }

  let fragment = "";
  const fragmentIndex = target.indexOf("#");
  if (fragmentIndex >= 0) {
    fragment = target.slice(fragmentIndex);
    target = target.slice(0, fragmentIndex);
  }
  if (target && !/\.(md|markdown|mdx)$/i.test(target)) {
    target += ".md";
  }
  return target + fragment;
}

function wikiTargetAt(pos) {
  if (!view) {
    return "";
  }
  const line = view.state.doc.lineAt(pos);
  const text = line.text;
  const pattern = /!?\[\[[^\]\n]+\]\]/g;
  let match;
  while ((match = pattern.exec(text)) !== null) {
    const from = line.from + match.index;
    const to = from + match[0].length;
    if (pos >= from && pos <= to) {
      return normalizeWikiTarget(match[0]);
    }
  }
  return "";
}

const obsidianLinkClickPlugin = EditorView.domEventHandlers({
  mousedown(event, editorView) {
    const wantsOpen = event.metaKey || event.ctrlKey;
    if (!wantsOpen || event.button !== 0) {
      return false;
    }
    const pos = editorView.posAtCoords({ x: event.clientX, y: event.clientY });
    if (pos == null) {
      return false;
    }
    const target = wikiTargetAt(pos);
    if (!target) {
      return false;
    }
    event.preventDefault();
    post({ action: "openMarkdownFile", path: target });
    return true;
  }
});

function wrapSelection(editorView, before, after = before) {
  const transaction = editorView.state.changeByRange(range => {
    const selected = editorView.state.sliceDoc(range.from, range.to);
    const insert = before + selected + after;
    return {
      changes: { from: range.from, to: range.to, insert },
      range: EditorSelectionRange(range.from + before.length, range.from + before.length + selected.length)
    };
  });
  editorView.dispatch(transaction);
  return true;
}

function EditorSelectionRange(anchor, head) {
  return EditorSelection.range(anchor, head);
}

function insertMarkdownLink(editorView) {
  const transaction = editorView.state.changeByRange(range => {
    const selected = editorView.state.sliceDoc(range.from, range.to) || "link";
    const insert = `[${selected}](url)`;
    const urlStart = range.from + selected.length + 3;
    return {
      changes: { from: range.from, to: range.to, insert },
      range: EditorSelectionRange(urlStart, urlStart + 3)
    };
  });
  editorView.dispatch(transaction);
  return true;
}

function toggleTaskOnCurrentLines(editorView) {
  const changes = [];
  for (const range of editorView.state.selection.ranges) {
    const startLine = editorView.state.doc.lineAt(range.from);
    const endLine = editorView.state.doc.lineAt(range.to);
    for (let lineNo = startLine.number; lineNo <= endLine.number; lineNo += 1) {
      const line = editorView.state.doc.line(lineNo);
      const match = /^(\s*(?:[-*+]|\d+[.)])\s+)(\[[ xX]\])/.exec(line.text);
      if (match) {
        const from = line.from + match[1].length;
        changes.push({
          from,
          to: from + 3,
          insert: /[xX]/.test(match[2]) ? "[ ]" : "[x]"
        });
      } else if (line.text.trim().length > 0) {
        const indentLength = line.text.match(/^\s*/)?.[0].length ?? 0;
        changes.push({
          from: line.from + indentLength,
          to: line.from + indentLength,
          insert: "- [ ] "
        });
      }
    }
  }
  if (!changes.length) {
    return false;
  }
  editorView.dispatch({ changes });
  return true;
}

function markdownCompletions(context) {
  const callout = context.matchBefore(/\[![A-Za-z-]*$/);
  if (callout) {
    return {
      from: callout.from,
      options: ["[!note]", "[!tip]", "[!important]", "[!warning]", "[!danger]"].map(label => ({
        label,
        type: "keyword"
      }))
    };
  }

  const fence = context.matchBefore(/```[A-Za-z0-9_+-]*$/);
  if (fence) {
    return {
      from: fence.from + 3,
      options: ["swift", "typescript", "javascript", "json", "bash", "python", "markdown"].map(label => ({
        label,
        type: "keyword"
      }))
    };
  }

  return null;
}

function cmuxKeymap() {
  return [
    { key: "Mod-b", run: editorView => wrapSelection(editorView, "**") },
    { key: "Mod-i", run: editorView => wrapSelection(editorView, "*") },
    { key: "Mod-k", run: insertMarkdownLink },
    { key: "Mod-Enter", run: toggleTaskOnCurrentLines },
    { key: "Enter", run: insertNewlineContinueMarkup },
    { key: "Backspace", run: deleteMarkupBackward },
    { key: "Backspace", run: deleteCharBackward },
    { key: "Mod-f", run: openSearchPanel },
    indentWithTab
  ];
}

function buildExtensions(theme) {
  return [
    lineNumbers(),
    foldGutter(),
    highlightActiveLineGutter(),
    history(),
    drawSelection(),
    dropCursor(),
    EditorState.allowMultipleSelections.of(true),
    indentOnInput(),
    bracketMatching(),
    closeBrackets(),
    autocompletion({ override: [markdownCompletions] }),
    rectangularSelection(),
    crosshairCursor(),
    highlightActiveLine(),
    highlightSelectionMatches(),
    search(),
    markdown(),
    themeCompartment.of(editorTheme(theme)),
    highlightCompartment.of(syntaxHighlighting(markdownHighlight(theme))),
    obsidianDecorationPlugin,
    obsidianLinkClickPlugin,
    taskCheckboxPlugin,
    EditorView.lineWrapping,
    EditorView.updateListener.of(update => {
      if (!update.docChanged || suppressChange) {
        return;
      }
      knownDocument = update.state.doc.toString();
      post({ action: "change", markdown: knownDocument });
    }),
    keymap.of([
      ...cmuxKeymap(),
      ...closeBracketsKeymap,
      ...defaultKeymap,
      ...searchKeymap,
      ...historyKeymap,
      ...foldKeymap,
      ...completionKeymap,
      ...lintKeymap
    ])
  ];
}

function boot(config = {}) {
  localizedStrings = {
    ...defaultStrings(),
    ...(config.strings || {})
  };
  const parent = document.getElementById("editor");
  if (!parent) {
    post({ action: "error", message: "Missing editor root" });
    return;
  }
  if (view) {
    setDocument(config.document || "");
    setTheme(config.theme || {});
    post({ action: "ready" });
    return;
  }

  knownDocument = String(config.document || "");
  view = new EditorView({
    parent,
    state: EditorState.create({
      doc: knownDocument,
      extensions: buildExtensions(normalizeTheme(config.theme || {}))
    })
  });
  post({ action: "ready" });
}

function setDocument(markdown) {
  if (!view) {
    knownDocument = String(markdown || "");
    return;
  }
  const next = String(markdown || "");
  if (next === view.state.doc.toString()) {
    knownDocument = next;
    return;
  }

  const anchor = Math.min(view.state.selection.main.anchor, next.length);
  const head = Math.min(view.state.selection.main.head, next.length);
  suppressChange = true;
  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: next },
    selection: { anchor, head },
    annotations: Transaction.addToHistory.of(false)
  });
  suppressChange = false;
  knownDocument = next;
}

function setTheme(theme) {
  if (!view) {
    return;
  }
  const normalized = normalizeTheme(theme || {});
  view.dispatch({
    effects: [
      themeCompartment.reconfigure(editorTheme(normalized)),
      highlightCompartment.reconfigure(syntaxHighlighting(markdownHighlight(normalized)))
    ]
  });
}

function focusEditor() {
  if (view) {
    view.focus();
  }
}

function selectFirstMatch(rawNeedle) {
  if (!view) {
    return false;
  }
  const needle = String(rawNeedle || "").trim();
  if (!needle) {
    return false;
  }

  const haystack = view.state.doc.toString();
  const matchIndex = haystack.toLocaleLowerCase().indexOf(needle.toLocaleLowerCase());
  if (matchIndex < 0) {
    return false;
  }
  view.dispatch({
    selection: { anchor: matchIndex, head: matchIndex + needle.length },
    scrollIntoView: true
  });
  view.focus();
  return true;
}

function getDocument() {
  return view ? view.state.doc.toString() : knownDocument;
}

window.cmuxMarkdownEditor = {
  boot,
  setDocument,
  setTheme,
  focus: focusEditor,
  selectFirstMatch,
  getDocument
};
