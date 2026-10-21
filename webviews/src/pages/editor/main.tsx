// Boots the code editor page: cmux-page://cmux.editor/ serves webviews/editor-page.html from the
// webviews-app build, which loads this module. The host installs the cmuxPage bridge (host.ts lists
// the ops); the dev server installs a stand-in (devBridge.ts) before this runs. This entry is small:
// Monaco, Shiki and the grammars load lazily (view.ts) once a file is open, so the empty state and
// every other page never fetch them.
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { applyDiffViewerAppearance, resolveDiffViewerAppearance } from "../../appearance";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings, type Strings } from "../shared/i18n";
import { contentFocus, FOCUS_CONTENT_COMMAND } from "../shared/pageFocus";
import { subscribePageStreams } from "../shared/pageStreams";
import { EditorEmptyState } from "../../viewer-empty/EditorEmptyState";
import { viewerEmptyStrings } from "../../viewer-empty/strings";
import table from "./generated/strings.json";
import { EditorPage, StatusStore } from "./EditorPage";
import {
  APP_ACTION_RUN_OP,
  EDITOR_FLUSH_OP,
  EDITOR_SELECTION_OP,
  EDITOR_KEY_SEQUENCE_OP,
  EDITOR_OPEN_LINK_OP,
} from "./host";
import { isEditorCommand } from "./keys";
import { applyEditorLook, PREFERENCE_KEYS, resolveEditorSettings } from "./settings";
import { EditorStore } from "./store";
import { EditorFind } from "./editorFind";
import { EMPTY, L } from "./strings";
import type { MonacoView, ViewLook } from "./view";
// styles.css @imports the shared page base and the empty-state styles, so they are inlined into the
// editor's own stylesheet instead of becoming a stylesheet shared with the markdown page.
import "./styles.css";

declare global {
  interface Window {
    /** Tests and the debug socket (`browser eval` runs in the page world in dev only). */
    __cmuxEditor?: { store: EditorStore; view: () => MonacoView | null; find: EditorFind };
  }
}

// Monaco's own UI strings (find widget, menus) in the page's language, where Monaco ships them.
const MONACO_LANGUAGES: Record<string, string> = {
  de: "de",
  es: "es",
  fr: "fr",
  it: "it",
  ja: "ja",
  ko: "ko",
  pl: "pl",
  "pt-BR": "pt-br",
  ru: "ru",
  tr: "tr",
  "zh-Hans": "zh-cn",
  "zh-Hant": "zh-tw",
};
const monacoMessages = import.meta.glob(
  "../../../node_modules/monaco-editor/esm/vs/nls/lang/{de,es,fr,it,ja,ko,pl,pt-br,ru,tr,zh-cn,zh-tw}.js",
);

let monaco: Promise<typeof import("./view")> | null = null;
/** Monaco, after its messages for `language` (they must be set before Monaco's modules evaluate). */
function loadMonaco(language: string): Promise<typeof import("./view")> {
  monaco ??= (async () => {
    const code = MONACO_LANGUAGES[language];
    const messages = code
      ? monacoMessages[`../../../node_modules/monaco-editor/esm/vs/nls/lang/${code}.js`]
      : undefined;
    if (messages) await messages().catch(() => undefined);
    return import("./view");
  })();
  return monaco;
}

function viewLook(store: EditorStore, screenReader: boolean): ViewLook {
  const look = store.getState().look;
  return {
    settings: resolveEditorSettings(look.settings),
    section: look.settings,
    appearance: look.appearance,
    syntaxTheme: look.syntaxTheme,
    languages: look.languages,
    screenReader,
  };
}

function fileName(path: string): string {
  return path.split("/").filter(Boolean).pop() ?? path;
}

export function mountEditorPage(root: HTMLElement, client: PageClient | null = createPageClient()): EditorStore {
  const store = new EditorStore(client);
  const status = new StatusStore();
  // Cmd-F is the shared find pill (ui/FindPill.tsx), not Monaco's find widget.
  const find = new EditorFind();
  const strings: Strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t(L.title);
  let view: MonacoView | null = null;
  let mounting: HTMLElement | null = null;
  // The app gives the page the keyboard (pane click, Cmd-Opt-Arrow, tab switch, relaunch): Monaco
  // takes it, also when it mounts after the request (pane-focus-DESIGN.md P1, P2).
  const focus = contentFocus();
  const screenReader = () => store.getState().look.screenReader;
  const editorRef = (element: HTMLDivElement | null) => {
    if (!element) {
      mounting = null;
      store.attachView(null);
      find.attach(null);
      focus.mount(null);
      view?.dispose();
      view = null;
      status.set(null);
      return;
    }
    if (view || mounting === element) return;
    mounting = element;
    void loadMonaco(strings.language).then(({ MonacoView: View }) => {
      if (mounting !== element) return;
      const next = new View(element, viewLook(store, screenReader()), {
        onUserEdit: () => store.edited(),
        onStatus: (value) => {
          status.set(value);
          document.documentElement.dataset.cmuxEditorLanguage = value.language;
          document.documentElement.dataset.cmuxEditorHighlighted = String(value.highlighted);
        },
        openLink: (href) => {
          const path = store.getState().file?.path;
          if (client && path) void client.call(EDITOR_OPEN_LINK_OP, { path, href }).catch(() => undefined);
        },
        label: (key, path) =>
          key === "editor"
            ? strings.format(L.editorLabel, fileName(path))
            : key === "wordWrap"
              ? strings.t(L.wordWrap)
              : strings.t(L.readOnly),
        toggleWordWrap: () => {
          const current = resolveEditorSettings(store.getState().look.settings).wordWrap;
          void store.setPreference(PREFERENCE_KEYS.wordWrap, current === "off" ? "on" : "off");
        },
        onKeySequence: (pending) => {
          if (client) void client.call(EDITOR_KEY_SEQUENCE_OP, { pending }).catch(() => undefined);
        },
        // The one bridge from web code to the native palette: the app's action, run by the host.
        openCommandPalette: () => {
          if (client) void client.call(APP_ACTION_RUN_OP, { action: "commandPalette" }).catch(() => undefined);
        },
        find: (command, text) => {
          if (command === "find") find.show(text);
          else if (command === "findNext") find.next();
          else if (command === "findPrevious") find.previous();
          else if (command === "useSelectionForFind") find.useSelection();
          else if (command === "replace") find.showReplace(text);
          else find.hide();
          return true;
        },
        onContentChange: () => find.refresh(),
      });
      view = next;
      store.attachView(next);
      find.attach(next.findTarget());
      focus.mount(next);
      document.documentElement.dataset.cmuxEditorBoot = "ready";
    });
  };
  window.__cmuxEditor = { store, view: () => view, find };
  if (client) {
    // Cmd-S and the find chords are the app key dispatcher's page commands; the page never reads them.
    void subscribePageStreams(client, {
      onCommand: ({ command, text }) => {
        if (command === FOCUS_CONTENT_COMMAND) return focus.request();
        if (command === "save") return void store.save({ format: true });
        if (isEditorCommand(command)) view?.command(command, text);
      },
    });
    // The host asks before it closes the tab or quits: pending edits are written first.
    client.handle(EDITOR_FLUSH_OP, () => store.flush());
    // Comment… and Quote in Chat on selected text: the host asks for the selection and its lines.
    client.handle(EDITOR_SELECTION_OP, () => view?.selectionQuote() ?? null);
  }
  // Leaving the page (tab closed, app quit) writes pending edits, unless the user turned saving off.
  const saveOnLeave = () => {
    if (resolveEditorSettings(store.getState().look.settings).autoSave !== "off") void store.save();
  };
  addEventListener("pagehide", saveOnLeave);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") saveOnLeave();
  });
  // The look (settings, theme.css, terminal appearance, languages) applies in place.
  let applied: unknown = null;
  const applyLook = () => {
    const state = store.getState();
    document.documentElement.dataset.cmuxEditorPhase = state.phase;
    document.documentElement.dataset.cmuxEditorStatus = state.status;
    // The document is shown: a focus request kept while Monaco loaded it applies now (P2).
    if (state.phase === "ready") focus.retry();
    if (state.look === applied) return;
    applied = state.look;
    const settings = resolveEditorSettings(state.look.settings);
    if (state.look.appearance) applyDiffViewerAppearance(resolveDiffViewerAppearance(state.look.appearance));
    applyEditorLook(settings, state.look.appearance, state.look.themeCSS ?? "");
    view?.setLook(viewLook(store, screenReader()));
  };
  store.subscribe(applyLook);
  // Monaco's code colors are literal: a terminal theme change rebuilds them (view.ts `setLook`).
  window.addEventListener("cmux-theme", () => view?.setLook(viewLook(store, screenReader())));
  const emptyStrings = viewerEmptyStrings();
  const emptyState = client
    ? () => (
        <EditorEmptyState
          client={client}
          strings={emptyStrings}
          texts={{
            title: strings.t(EMPTY.title),
            subtitle: strings.t(EMPTY.subtitle),
            choose: strings.t(EMPTY.choose),
            drop: strings.t(EMPTY.drop),
            recentsEmpty: strings.t(EMPTY.recents),
          }}
          open={(path) => store.openFile(path)}
        />
      )
    : undefined;
  createRoot(root).render(
    <EditorPage
      store={store}
      status={status}
      find={find}
      strings={strings}
      editorRef={editorRef}
      emptyState={emptyState}
    />,
  );
  void store.start();
  return store;
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "editor") mountEditorPage(root);
