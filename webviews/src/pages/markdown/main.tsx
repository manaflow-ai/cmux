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
import { parseComments } from "./comments";
import { MarkdownEditor, markdownRemoteImagePlaceholder, type EditorLabel, type MarkdownEditorHost } from "./editor";
import table from "./generated/strings.json";
import type { ThemeRegistrationAny } from "shiki/core";
import { CodeHighlighter, codeThemes, preloadHighlighter } from "./highlight";
import {
  MARKDOWN_CONTEXT_TABLE_OP,
  MARKDOWN_DELETE_COMMENT_OP,
  MARKDOWN_FLUSH_OP,
  MARKDOWN_LIST_FILES_OP,
  MARKDOWN_RESOLVE_LINKS_OP,
  MARKDOWN_SELECTION_OP,
  MARKDOWN_SET_TABLE_WIDTHS_OP,
  resolveImageURL,
} from "./host";
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
import { EditorFind } from "../editor/editorFind";
import { markdownFindTarget } from "./markdownFind";
import { L } from "./strings";
import { hostTableWidths, storedTableWidths } from "./tables";
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
  remoteImageBlocked: L.remoteImageBlocked,
  remoteImageLoad: L.remoteImageLoad,
  comment: L.comment,
  deleteComment: L.deleteComment,
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
  const imageListeners = new Set<() => void>();
  let remoteImageBase = config()?.remoteImageBase;
  store.subscribe(() => {
    const next = config()?.remoteImageBase;
    if (next === remoteImageBase) return;
    remoteImageBase = next;
    for (const listener of imageListeners) listener();
  });
  let blockedImage = (_src: string, _alt: string): HTMLElement => document.createElement("span");
  const host: MarkdownEditorHost & {
    setCodeThemes(themes: Promise<ThemeRegistrationAny[]>): Promise<void> | undefined;
  } = {
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
    loadRemoteImages: () => store.loadRemoteImages(),
    observeRemoteImages(refresh) {
      imageListeners.add(refresh);
      return () => imageListeners.delete(refresh);
    },
    // Kept with the file by the host: the page's own storage dies with the tab (its WebKit data
    // store is not persistent). One call per finished resize.
    // Delete on a comment card: the host forgets it and sends the list back (the `comments` command).
    deleteComment: (id) => {
      if (client) void client.call(MARKDOWN_DELETE_COMMENT_OP, { path: config()?.path, id }).catch(() => {});
    },
    tableWidths: client
      ? hostTableWidths(
          () => config()?.path,
          (path) => (config()?.path === path ? config()?.tableWidths : undefined),
          (path, value) => void client.call(MARKDOWN_SET_TABLE_WIDTHS_OP, { path, value }).catch(() => {}),
        )
      : storedTableWidths(() => config()?.path),
    highlight(code, language, refresh) {
      const look = store.getState().look;
      highlighter ??= new CodeHighlighter(codeThemes(markdownCodeTheme(look.settings), look.appearance));
      return highlighter.tokens(code, language, refresh);
    },
    renderDiagram(language, source, target) {
      renderDiagram(libraries, language, source, target, strings.t(L.diagramFailed));
    },
    label: (key) => strings.t(LABELS[key]),
    htmlPreview: (html) => htmlPreview(html, imageURL, blockedImage),
    setCodeThemes(themes) {
      return highlighter?.setThemes(themes);
    },
  };
  blockedImage = (src, alt) => markdownRemoteImagePlaceholder(host, src, alt);
  return host;
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
  /** What the last right-click hit, and the table it was on (what the host was told). */
  let contextTarget: Element | null = null;
  let contextTable: number | null = null;
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
  const find = bindMarkdownFind(store, scroller);
  // A callback ref: React calls it with the element on mount and null on unmount.
  // Another document (a link, back, a reload from disk) brings its own comments in its config.
  let shownConfig = store.getState().config;
  store.subscribe(() => {
    const next = store.getState().config;
    if (next === shownConfig) return;
    shownConfig = next;
    editor?.setComments(parseComments(next?.comments));
  });
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
      if (editor !== next) return;
      store.attachEditor(next);
      next.setComments(parseComments(store.getState().config?.comments));
    });
  };
  if (client) {
    // Cmd-S is the app key dispatcher's `save` page command; the page never reads the chord.
    void subscribePageStreams(client, {
      // Cmd-[ and Cmd-] are `back` and `forward` (the page's link history), Cmd-R `reload` (the
      // file again from disk), `open` a path typed in the omnibar (`text`), Cmd-K is `link`,
      // Cmd-= / Cmd-- / Cmd-0 the text size; `goToTop` is the `markdownGoToTop` action (a user's
      // `g g` in a read-only page).
      onCommand: ({ command, text }) => {
        if (isMarkdownZoomCommand(command)) zoom.run(command);
        else if (command === "save") void store.save();
        else if (command === "back") void router.go(-1);
        else if (command === "forward") void router.go(1);
        else if (command === "reload") void router.reload();
        else if (command === "open" && text) void router.open(text);
        else if (command === "link") editor?.openLinkPopover();
        else if (command === "goToTop") scroller()?.scrollTo({ top: 0 });
        else if (command === "resetTableWidths") editor?.resetTableWidths();
        else if (command === "resetContextTableWidths") editor?.resetTableWidthsAt(contextTarget);
        else if (command === "comments") editor?.setComments(parseComments(parseJSON(text)));
        // Cmd-F, Cmd-G, Shift-Cmd-G, Cmd-E and Hide Find Bar: the app's shared find actions.
        else if (command === "find") find.show(text);
        else if (command === "findNext") find.next();
        else if (command === "findPrevious") find.previous();
        else if (command === "useSelectionForFind") find.useSelection();
        else if (command === "hideFind") find.hide();
      },
    });
    // A right-click tells the host whether it was on a table (its menu then offers Reset Column
    // Widths); WebKit dispatches the event before it asks the app for the menu.
    root.addEventListener(
      "contextmenu",
      (event) => {
        contextTarget = event.target instanceof Element ? event.target : null;
        const table = editor?.tableIndexAt(contextTarget) ?? null;
        if (table !== null || contextTable !== null)
          void client.call(MARKDOWN_CONTEXT_TABLE_OP, { table }).catch(() => {});
        contextTable = table;
      },
      true,
    );
    // The host asks before it closes the tab or quits: pending edits are written first.
    client.handle(MARKDOWN_FLUSH_OP, () => store.flush());
    // Comment… and Quote in Chat on selected text: the host asks for the selection and its lines.
    client.handle(MARKDOWN_SELECTION_OP, () => editor?.selectionQuote() ?? null);
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
        find={find}
      />
    </UiProvider>,
  );
  void store.start();
  preloadHighlighter();
  return store;
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "markdown") mountMarkdownPage(root);

/**
 * Find over the page (markdownFind.ts) in the code editor's find state. While the pill shows, an
 * edit, a document the editor redraws, a link to another file or a switch between rich text and
 * source searches again, once per frame, keeping the active match's place.
 */
function bindMarkdownFind(store: MarkdownStore, scroller: () => HTMLElement | null): EditorFind {
  const find = new EditorFind();
  find.attach(
    markdownFindTarget({
      mode: () => store.getState().mode,
      doc: () => scroller()?.querySelector<HTMLElement>(".md-doc") ?? null,
      source: () => scroller()?.querySelector<HTMLTextAreaElement>(".md-source") ?? null,
      scroller,
    }),
  );
  let frame = 0;
  const refresh = () => {
    if (frame || !find.getState().open) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      find.refresh();
    });
  };
  // Highlights and selections are not DOM changes, so painting never wakes the observer.
  const observer = new MutationObserver(refresh);
  let observed: HTMLElement | null = null;
  let mode = store.getState().mode;
  const follow = () => {
    const open = find.getState().open;
    const target = open ? scroller() : null;
    if (target !== observed) {
      observer.disconnect();
      observed?.removeEventListener("input", refresh);
      observed = target;
      observed?.addEventListener("input", refresh);
      if (observed) observer.observe(observed, { subtree: true, childList: true, characterData: true });
    }
    const next = store.getState().mode;
    if (next !== mode) {
      mode = next;
      refresh();
    }
  };
  find.subscribe(follow);
  store.subscribe(follow);
  return find;
}

/** `text` as JSON, null when it is not. */
function parseJSON(text: string | undefined): unknown {
  try {
    return text ? JSON.parse(text) : null;
  } catch {
    return null;
  }
}
