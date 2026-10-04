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
import { CodeHighlighter, markdownThemes } from "./highlight";
import { MARKDOWN_OPEN_LINK_OP, resolveImageURL } from "./host";
import { htmlPreview } from "./htmlPreview";
import { MarkdownPage } from "./MarkdownPage";
import { MarkdownStore } from "./store";
import { L } from "./strings";
import "../shared/pageBase.css";
import "./styles.css";

const LABELS: Record<EditorLabel, string> = {
  frontmatter: L.frontmatter,
  html: L.html,
  definition: L.definition,
  source: L.rawSource,
  plainText: L.plainText,
};

/** The editor's host: links, images, code colors and diagrams, from the page config. */
function editorHost(store: MarkdownStore, client: PageClient | null, strings: Strings): MarkdownEditorHost {
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
      highlighter ??= new CodeHighlighter(markdownThemes(config()?.appearance));
      return highlighter.tokens(code, language, refresh);
    },
    renderDiagram(language, source, target) {
      renderDiagram(libraries, language, source, target, strings.t(L.diagramFailed));
    },
    label: (key) => strings.t(LABELS[key]),
    htmlPreview: (html) => htmlPreview(html, imageURL),
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
  // The code font and palette follow the host's terminal appearance, as in the diff viewer.
  let appliedConfig: unknown = null;
  store.subscribe(() => {
    const config = store.getState().config;
    if (!config || config === appliedConfig) return;
    appliedConfig = config;
    if (config.appearance) applyDiffViewerAppearance(resolveDiffViewerAppearance(config.appearance));
  });
  createRoot(root).render(<MarkdownPage store={store} strings={strings} editorRef={editorRef} />);
  void store.start();
  return store;
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "markdown") mountMarkdownPage(root);
