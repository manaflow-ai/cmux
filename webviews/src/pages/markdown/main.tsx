// Boots the markdown editor page: cmux-page://cmux.markdown/ serves webviews/markdown-page.html
// from the webviews-app build, which loads this module. The host installs the cmuxPage bridge
// (host.ts lists the ops); the dev server installs a stand-in (devBridge.ts) before this runs.
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
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
import { MARKDOWN_FLUSH_OP, MARKDOWN_LIST_FILES_OP, MARKDOWN_RESOLVE_LINKS_OP, resolveImageURL } from "./host";
import type { LinkLabel } from "./linkEditing";
import { LinkRouter } from "./linkRouter";
import { LinkResolver, type ResolvedLink } from "./links";
import { htmlPreview } from "./htmlPreview";
import { MarkdownPage } from "./MarkdownPage";
import { LinkOverlays } from "./overlays";
import { MarkdownStore } from "./store";
import { bindMarkdownLook, markdownCodeTheme } from "./settings";
import { L } from "./strings";
import { MarkdownEmptyState } from "../../viewer-empty/MarkdownEmptyState";
import { viewerEmptyStrings } from "../../viewer-empty/strings";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import "../shared/pageBase.css";
import "../../ui/ui.css";
import "./styles.css";
import "../../viewer-empty/styles.css";

const LABELS: Record<EditorLabel, string> = {
  frontmatter: L.frontmatter,
  html: L.html,
  definition: L.definition,
  source: L.rawSource,
  plainText: L.plainText,
  document: L.title,
};

/** The editor's host: links, images, code colors and diagrams, from the page config. */
const LINK_LABELS: Record<LinkLabel, string> = {
  followHint: L.followHint,
  clickHint: L.clickHint,
  broken: L.broken,
  noHeading: L.noHeading,
  checking: L.checking,
  opensBrowser: L.opensBrowser,
  opensFile: L.opensFile,
  opensMail: L.opensMail,
  linkPlaceholder: L.linkPlaceholder,
  footnote: L.footnote,
};

function editorHost(
  store: MarkdownStore,
  client: PageClient | null,
  strings: Strings,
  resolver: LinkResolver,
  follow: (href: string) => void,
): MarkdownEditorHost & { setCodeThemes(themes: Promise<ThemeRegistrationAny[]>): Promise<void> | undefined } {
  // One highlighter; its themes follow `markdown.code.theme` and the terminal appearance.
  let highlighter: CodeHighlighter | null = null;
  const config = () => store.getState().config;
  const libraries = new DiagramLibraries((name) => {
    const base = config()?.libBase;
    return base ? `${base}${name}.js` : null;
  });
  const imageURL = (src: string) => resolveImageURL(src, config()?.assetBase, config()?.remoteImageBase);
  return {
    openLink: follow,
    get githubRepository() {
      return config()?.githubRepository;
    },
    links: {
      resolved: (path) => resolver.get(path),
      requestLinks: (paths) => resolver.request(paths),
      listFiles: async (prefix) => {
        const from = config()?.path;
        if (!client || !from) return [];
        const answer = await client.call<{ entries?: unknown }>(MARKDOWN_LIST_FILES_OP, { from, prefix });
        return Array.isArray(answer?.entries)
          ? answer.entries.filter((entry): entry is string => typeof entry === "string")
          : [];
      },
      linkLabel: (key) => strings.t(LINK_LABELS[key]),
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
  let editor: MarkdownEditor | null = null;
  const overlays = new LinkOverlays();
  // Relative link targets: checked through the host in batches, cached per file.
  const resolver = new LinkResolver(
    client
      ? async (from, paths) =>
          (await client.call<{ links?: Record<string, ResolvedLink> }>(MARKDOWN_RESOLVE_LINKS_OP, { from, paths }))
            ?.links ?? {}
      : null,
    () => editor?.refreshLinks(),
  );
  store.subscribe(() => {
    const path = store.getState().config?.path;
    if (path) resolver.setFrom(path);
  });
  const scroller = () => document.querySelector<HTMLElement>(".md-scroll");
  const router = new LinkRouter({
    store,
    client,
    resolver,
    scrollToAnchor: (anchor) => editor?.scrollToAnchor(anchor) ?? false,
    scroll: { get: () => scroller()?.scrollTop ?? 0, set: (top) => scroller()?.scrollTo({ top }) },
    afterShow: (run) => requestAnimationFrame(() => run()),
  });
  const host = editorHost(store, client, strings, resolver, (href) => void router.follow(href));
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
      overlays,
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
      // Cmd-[ and Cmd-] are `back` and `forward` (the page's link history), Cmd-K is `link`.
      onCommand: ({ command }) => {
        if (command === "save") void store.save();
        else if (command === "back") void router.go(-1);
        else if (command === "forward") void router.go(1);
        else if (command === "link") editor?.openLinkPopover();
      },
    });
    // The host asks before it closes the tab or quits: pending edits are written first.
    client.handle(MARKDOWN_FLUSH_OP, () => store.flush());
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
    <UiProvider container={root} dir={languageDirection(strings.language)}>
      <MarkdownPage
        store={store}
        strings={strings}
        editorRef={editorRef}
        emptyState={emptyState}
        overlays={overlays}
        onBack={() => void router.go(-1)}
        onForward={() => void router.go(1)}
      />
    </UiProvider>,
  );
  void store.start();
  return store;
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "markdown") mountMarkdownPage(root);
