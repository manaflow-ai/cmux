// Boots the markdown editor page: cmux-page://cmux.markdown/ serves webviews/markdown-page.html
// from the webviews-app build, which loads this module. The host installs the cmuxPage bridge
// (host.ts lists the ops); the dev server installs a stand-in (devBridge.ts) before this runs.
import { createRoot } from "react-dom/client";
import { applyDiffViewerAppearance, resolveDiffViewerAppearance } from "../../appearance";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings, type Strings } from "../shared/i18n";
import { subscribePageStreams } from "../shared/pageStreams";
import { DiagramLibraries, renderDiagram } from "./diagrams";
import { MarkdownEditor, type EditorLabel, type MarkdownEditorHost } from "./editor";
import table from "./generated/strings.json";
import type { ThemeRegistrationAny } from "shiki/core";
import { CodeHighlighter, codeThemes } from "./highlight";
import { MARKDOWN_OPEN_LINK_OP, resolveImageURL } from "./host";
import { htmlPreview } from "./htmlPreview";
import { MarkdownPage } from "./MarkdownPage";
import { MarkdownStore } from "./store";
import { bindMarkdownLook, markdownCodeTheme } from "./settings";
import { L } from "./strings";
import { MarkdownEmptyState } from "../../viewer-empty/MarkdownEmptyState";
import { viewerEmptyStrings } from "../../viewer-empty/strings";
import "../shared/pageBase.css";
import "./styles.css";
import "../../viewer-empty/styles.css";

const LABELS: Record<EditorLabel, string> = {
  frontmatter: L.frontmatter,
  html: L.html,
  definition: L.definition,
  source: L.rawSource,
  plainText: L.plainText,
};

/** The editor's host: links, images, code colors and diagrams, from the page config. */
function editorHost(
  store: MarkdownStore,
  client: PageClient | null,
  strings: Strings,
): MarkdownEditorHost & { setCodeThemes(themes: Promise<ThemeRegistrationAny[]>): Promise<void> | undefined } {
  // One highlighter; its themes follow `markdown.code.theme` and the terminal appearance.
  let highlighter: CodeHighlighter | null = null;
  const config = () => store.getState().config;
  const libraries = new DiagramLibraries((name) => {
    const base = config()?.libBase;
    return base ? `${base}${name}.js` : null;
  });
  const imageURL = (src: string) => resolveImageURL(src, config()?.assetBase);
  return {
    openLink(href) {
      if (href.startsWith("#")) {
        const id = decodeURIComponent(href.slice(1));
        document.getElementById(id)?.scrollIntoView({ block: "start" });
        return;
      }
      const path = config()?.path;
      if (client && path) void client.call(MARKDOWN_OPEN_LINK_OP, { path, href }).catch(() => undefined);
    },
    imageURL,
    highlight(code, language, refresh) {
      const look = store.getState().look;
      highlighter ??= new CodeHighlighter(codeThemes(markdownCodeTheme(look.settings), look.appearance));
      return highlighter.tokens(code, language, refresh);
    },
    renderDiagram(language, source, target) {
      renderDiagram(libraries, language, source, target, strings.t(L.diagramFailed));
    },
    label: (key) => strings.t(LABELS[key]),
    htmlPreview: (html) => htmlPreview(html, imageURL),
    setCodeThemes(themes) {
      return highlighter?.setThemes(themes);
    },
  };
}

export function mountMarkdownPage(root: HTMLElement, client: PageClient | null = createPageClient()): MarkdownStore {
  const store = new MarkdownStore(client);
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t(L.title);
  const host = editorHost(store, client, strings);
  let editor: MarkdownEditor | null = null;
  // A callback ref: React calls it with the element on mount and null on unmount.
  const editorRef = (element: HTMLDivElement | null) => {
    if (!element) {
      store.attachEditor(null);
      void editor?.destroy();
      editor = null;
      return;
    }
    if (editor) return;
    const next = new MarkdownEditor({
      root: element,
      host,
      readOnly: store.getState().readOnly,
      onUserEdit: () => store.edited(),
    });
    editor = next;
    void next.create().then(() => {
      if (editor === next) store.attachEditor(next);
    });
  };
  if (client) {
    // Cmd-S is the app key dispatcher's `save` page command; the page never reads the chord.
    void subscribePageStreams(client, {
      onCommand: ({ command }) => {
        if (command === "save") void store.save();
      },
    });
  }
  // Leaving the page (tab closed, app quit) writes pending edits.
  addEventListener("pagehide", () => void store.save());
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") void store.save();
  });
  // The look (settings, theme.css, terminal appearance) applies in place whenever the host sends
  // one: CSS variables, the user stylesheet, the code font and the code theme. Never a reload.
  bindMarkdownLook(store, {
    appearance: (appearance) => applyDiffViewerAppearance(resolveDiffViewerAppearance(appearance)),
    codeTheme: (names, appearance) =>
      void host.setCodeThemes(codeThemes(names, appearance))?.then(() => editor?.refreshHighlight()),
  });
  const emptyStrings = viewerEmptyStrings();
  const emptyState = client
    ? () => <MarkdownEmptyState client={client} strings={emptyStrings} open={(path) => store.openFile(path)} />
    : undefined;
  createRoot(root).render(
    <MarkdownPage store={store} strings={strings} editorRef={editorRef} emptyState={emptyState} />,
  );
  void store.start();
  return store;
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "markdown") mountMarkdownPage(root);
