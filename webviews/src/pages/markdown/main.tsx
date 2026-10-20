// Boots the markdown editor page: cmux-page://cmux.markdown/ serves webviews/markdown-page.html
// from the webviews-app build, which loads this module. The host installs the cmuxPage bridge
// (host.ts lists the ops); the dev server installs a stand-in (devBridge.ts) before this runs.
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
import { lazy, Suspense, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { applyDiffViewerAppearance, followHostTerminalTheme, resolveDiffViewerAppearance } from "../../appearance";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings, type Strings } from "../shared/i18n";
import { subscribePageStreams } from "../shared/pageStreams";
import { DiagramLibraries, renderDiagram } from "./diagrams";
import { MarkdownEditor, type EditorLabel, type MarkdownEditorHost } from "./editor";
import table from "./generated/strings.json";
import type { ThemeRegistrationAny } from "shiki/core";
import { CodeHighlighter, codeThemes, preloadHighlighter } from "./highlight";
import { MARKDOWN_FLUSH_OP, MARKDOWN_LIST_FILES_OP, MARKDOWN_RESOLVE_LINKS_OP, resolveImageURL } from "./host";
import type { LinkLabel } from "./linkEditing";
import { LinkRouter } from "./linkRouter";
import { LinkResolver, type ResolvedLink } from "./links";
import { htmlPreview } from "./htmlPreview";
import { MarkdownPage } from "./MarkdownPage";
import { LinkOverlays } from "./overlays";
import { MarkdownStore } from "./store";
import type { ReadingSettingsActions } from "./ReadingSettings";
import { MARKDOWN_READING, bindMarkdownLook, markdownCodeTheme } from "./settings";
import { MarkdownFontZoom, isMarkdownZoomCommand } from "./fontZoom";
import { L } from "./strings";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import "../shared/pageBase.css";
import "../../ui/ui.css";
import "./styles.css";
import "../../viewer-empty/styles.css";
import { appPopupHost } from "../shared/pagePopupHost";

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
  opensInCmux: L.opensInCmux,
  opensFile: L.opensFile,
  opensMail: L.opensMail,
  linkPlaceholder: L.linkPlaceholder,
  footnote: L.footnote,
  bubble: L.linkBubble,
  open: L.linkOpen,
  copy: L.linkCopy,
  copied: L.linkCopied,
  edit: L.linkEdit,
  remove: L.linkRemove,
  text: L.linkText,
  textPlaceholder: L.linkTextPlaceholder,
  url: L.linkURL,
  apply: L.linkApply,
  insertTitle: L.linkInsertTitle,
  editTitle: L.linkEditTitle,
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
      const flag = config()?.mermaidRenderer;
      const mermaidRenderer = flag === "mermaid" || flag === "ondine" ? flag : undefined;
      renderDiagram(libraries, language, source, target, strings.t(L.diagramFailed), mermaidRenderer);
    },
    label: (key) => strings.t(LABELS[key]),
    htmlPreview: (html) => htmlPreview(html, imageURL),
    setCodeThemes(themes) {
      return highlighter?.setThemes(themes);
    },
  };
}

/** The code block size in pixels the Reading Settings wrote before code became a share of the text. */
const LEGACY_CODE_BLOCK_SIZE_KEY = "markdown.code.blockSize";

/**
 * The Reading Settings popover's writes: each option is its `markdown.*` key through the store's one
 * settings write path. A new text size is the default size, so this viewer goes back to the
 * default (Cmd-0) and shows it.
 */
function readingActions(store: MarkdownStore, zoom: MarkdownFontZoom): ReadingSettingsActions {
  return {
    set(option, value) {
      store.setPreference(MARKDOWN_READING[option].key, value);
      // A fixed code block size (cmux.json, or the old Reading Settings row) would hide the change.
      if (option === "codeScale") store.setPreference(LEGACY_CODE_BLOCK_SIZE_KEY, null);
      if (option === "fontSize") zoom.run("zoomReset");
    },
    reset() {
      for (const option of Object.values(MARKDOWN_READING)) store.setPreference(option.key, null);
      store.setPreference(LEGACY_CODE_BLOCK_SIZE_KEY, null);
      zoom.run("zoomReset");
    },
  };
}

/** The empty state as a lazy component, its chunk requested at once. */
function lazyEmptyState(client: PageClient, store: MarkdownStore): () => ReactNode {
  const module = Promise.all([
    import("../../viewer-empty/MarkdownEmptyState"),
    import("../../viewer-empty/strings"),
  ]).then(([{ MarkdownEmptyState }, { viewerEmptyStrings }]) => {
    const strings = viewerEmptyStrings();
    return {
      default: () => <MarkdownEmptyState client={client} strings={strings} open={(path) => store.openFile(path)} />,
    };
  });
  const EmptyState = lazy(() => module);
  return () => (
    <Suspense fallback={null}>
      <EmptyState />
    </Suspense>
  );
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
  // Cmd-= / Cmd-- / Cmd-0: this viewer's text size over the `markdown.font.size` default.
  const zoom = new MarkdownFontZoom(document.documentElement);
  let zoomSettings: unknown = null;
  store.subscribe(() => {
    const { config, look, phase } = store.getState();
    if (config?.path) resolver.setFrom(config.path);
    if (phase === "ready" && look.settings !== zoomSettings) {
      zoomSettings = look.settings;
      zoom.setSettings(look.settings);
    }
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
      // Cmd-[ and Cmd-] are `back` and `forward` (the page's link history), Cmd-K is `link`,
      // Cmd-= / Cmd-- / Cmd-0 the text size.
      onCommand: ({ command }) => {
        if (isMarkdownZoomCommand(command)) zoom.run(command);
        else if (command === "save") void store.save();
        else if (command === "back") void router.go(-1);
        else if (command === "forward") void router.go(1);
        else if (command === "link") editor?.openLinkPopover();
      },
    });
    // The host asks before it closes the tab or quits: pending edits are written first.
    client.handle(MARKDOWN_FLUSH_OP, () => store.flush());
  }
  // Leaving the page (tab closed, app quit) writes pending edits.
  addEventListener("pagehide", () => {
    store.flushPreferences();
    void store.save();
  });
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") void store.save();
  });
  // The look (settings, theme.css, terminal appearance) applies in place whenever the host sends
  // one: CSS variables, the user stylesheet, the code font and the code theme. Never a reload.
  // Code colors follow the terminal theme in place, through the page's syntax variables.
  followHostTerminalTheme(() =>
    applyDiffViewerAppearance(resolveDiffViewerAppearance(store.getState().look?.appearance)),
  );
  bindMarkdownLook(store, {
    appearance: (appearance) => applyDiffViewerAppearance(resolveDiffViewerAppearance(appearance)),
    codeTheme: (names, appearance) =>
      void host.setCodeThemes(codeThemes(names, appearance))?.then(() => editor?.refreshHighlight()),
  });
  // The empty state (no file yet) and its string table load off the first paint's path: the
  // import starts now, beside the host's config round trip that decides between a file and the
  // empty state, so it is in hand before the empty phase renders (Suspense covers the rare miss).
  const emptyState = client ? lazyEmptyState(client, store) : undefined;
  createRoot(root).render(
    <UiProvider container={root} popupHost={appPopupHost(client)} dir={languageDirection(strings.language)}>
      <MarkdownPage
        store={store}
        strings={strings}
        editorRef={editorRef}
        emptyState={emptyState}
        overlays={overlays}
        onBack={() => void router.go(-1)}
        onForward={() => void router.go(1)}
        reading={readingActions(store, zoom)}
      />
    </UiProvider>,
  );
  void store.start();
  preloadHighlighter();
  return store;
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "markdown") mountMarkdownPage(root);
