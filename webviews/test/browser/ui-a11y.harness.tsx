// Browser harness for test/ui-a11y.test.ts: the ui wrapper's widgets and the migrated pages in a
// real engine. `?case=widgets` a menu with a submenu, a toolbar with tooltips and the recent list;
// `?case=picker` the real path picker sheet over a fake file system (one folder of 2,000 entries);
// `?case=markdown` the real markdown page toolbar and editor (link popover, hover card).
// `&rtl` runs right to left (Arabic). Outcomes go to #result for the keyboard scripts.
import { createRoot } from "react-dom/client";
import { useState } from "react";
import "../../src/pages/shared/pageBase.css";
import "../../src/ui/ui.css";
import "../../src/viewer-empty/styles.css";
import "../../src/pages/markdown/styles.css";
import { Menu, MenuButton, MenuItem, MenuPopup, Submenu } from "../../src/ui/Menu";
import { Toolbar, ToolbarButton } from "../../src/ui/Toolbar";
import { TooltipProvider } from "../../src/ui/Tooltip";
import { UiProvider } from "../../src/ui/UiProvider";
import { RecentList } from "../../src/viewer-empty/EmptyState";
import { PathPickerDialog } from "../../src/viewer-empty/PathPicker";
import { viewerEmptyStrings } from "../../src/viewer-empty/strings";
import type { PickerEntry, PickerListing, PickerMode } from "../../src/viewer-empty/ops";
import { MarkdownPage } from "../../src/pages/markdown/MarkdownPage";
import { MarkdownEditor } from "../../src/pages/markdown/editor";
import { LinkOverlays } from "../../src/pages/markdown/overlays";
import { createStrings } from "../../src/pages/shared/i18n";
import markdownTable from "../../src/pages/markdown/generated/strings.json";

const params = new URLSearchParams(location.search);
const rtl = params.has("rtl");
const language = rtl ? "ar" : "en";
document.documentElement.lang = language;
document.documentElement.dir = rtl ? "rtl" : "ltr";
const root = document.getElementById("root")!;
const page = document.getElementById("page")!;
const report = (text: string) => (document.getElementById("result")!.textContent = text);

function Widgets() {
  const strings = viewerEmptyStrings([language]);
  const now = Date.UTC(2026, 9, 4, 12);
  return (
    <>
      <Menu>
        <MenuButton className="source">Source</MenuButton>
        <MenuPopup>
          <MenuItem onSelect={() => report("source: Working tree")}>Working tree</MenuItem>
          <MenuItem onSelect={() => report("source: Staged")}>Staged</MenuItem>
          <Submenu label="Committed">
            {["HEAD~1", "HEAD~2", "main"].map((ref) => (
              <MenuItem key={ref} onSelect={() => report(`source: ${ref}`)}>
                {ref}
              </MenuItem>
            ))}
          </Submenu>
        </MenuPopup>
      </Menu>
      <Toolbar label="Diff tools">
        {["Split view", "Unified view", "Wrap lines", "Collapse all files"].map((label) => (
          <ToolbarButton key={label} label={label} onPress={() => report(`tool: ${label}`)}>
            {label.slice(0, 1)}
          </ToolbarButton>
        ))}
      </Toolbar>
      <RecentList
        items={["alpha", "beta", "bravo", "charlie"].map((name, index) => ({
          path: `/Users/me/fun/${name}`,
          openedAt: now - (index + 1) * 3_600_000,
        }))}
        home="/Users/me"
        icon="repo"
        strings={strings}
        label="Recent repositories"
        emptyText="None"
        now={now}
        autoFocus={false}
        onOpen={(item) => report(`open: ${item.path}`)}
      />
    </>
  );
}

const HOME = "/Users/me";
const TREE: Record<string, Array<Omit<PickerEntry, "path">>> = {
  "/": [
    { name: "Users", kind: "dir" },
    { name: "tmp", kind: "dir" },
  ],
  "/Users": [{ name: "me", kind: "dir" }],
  [HOME]: [
    { name: "Documents", kind: "dir" },
    { name: "fun", kind: "dir" },
    { name: "big", kind: "dir" },
  ],
  [`${HOME}/fun`]: [
    { name: "cmuxterm-hq", kind: "dir", git: true },
    { name: "chatmux", kind: "dir", git: true },
    { name: "scratch", kind: "dir" },
  ],
  [`${HOME}/fun/scratch`]: [],
  [`${HOME}/Documents`]: [],
  [`${HOME}/big`]: Array.from({ length: 2000 }, (_, index) => ({
    name: `folder-${String(index).padStart(4, "0")}`,
    kind: "dir" as const,
  })),
  "/tmp": [],
};

async function list(path: string | null, options: { mode: PickerMode; hidden: boolean }): Promise<PickerListing> {
  await new Promise((resolve) => setTimeout(resolve, 30));
  const dir = path == null || path === "~" ? HOME : path;
  const entries = TREE[dir];
  if (!entries) throw new Error(`no such folder ${dir}`);
  return {
    path: dir,
    parent: dir === "/" ? null : dir.slice(0, dir.lastIndexOf("/")) || "/",
    home: HOME,
    entries: entries
      .filter((entry) => options.hidden || !entry.name.startsWith("."))
      .map((entry) => ({ ...entry, path: `${dir === "/" ? "" : dir}/${entry.name}` })),
  };
}

function Picker() {
  const [open, setOpen] = useState(true);
  if (!open) return null;
  return (
    <PathPickerDialog
      mode="folder"
      list={list}
      strings={viewerEmptyStrings([language])}
      recents={[`${HOME}/fun/scratch`]}
      start={`${HOME}/fun`}
      onChoose={(path) => {
        report(`chose: ${path}`);
        setOpen(false);
      }}
      onCancel={() => {
        report("cancel");
        setOpen(false);
      }}
    />
  );
}

/** The markdown page over a fake store (no host): toolbar, editor, link popover, hover card. */
function markdown() {
  const strings = createStrings(markdownTable, [language]);
  let state = {
    phase: "ready" as const,
    config: { path: "/w/notes.md" },
    mode: "rich" as "rich" | "source",
    status: "saved" as const,
    readOnly: false,
    conflict: null,
    source: "",
    revision: 0,
    look: { settings: undefined, themeCSS: undefined, appearance: undefined },
    canBack: true,
    canForward: false,
  };
  const listeners = new Set<() => void>();
  const store = {
    subscribe: (listener: () => void) => (listeners.add(listener), () => listeners.delete(listener)),
    getState: () => state,
    setMode: (mode: "rich" | "source") => {
      state = { ...state, mode };
      listeners.forEach((listener) => listener());
      report(`mode: ${mode}`);
    },
    setSource: () => {},
    start: async () => {},
    reloadFromDisk: () => {},
    keepMine: async () => {},
  };
  let editor: MarkdownEditor | null = null;
  const overlays = new LinkOverlays();
  const editorRef = (element: HTMLDivElement | null) => {
    if (!element || editor) return;
    const next = new MarkdownEditor({
      root: element,
      overlays,
      host: {
        openLink: (href) => report(`open: ${href}`),
        imageURL: (src) => src,
        label: (key) => key,
        links: {
          resolved: () => ({ exists: true, path: "/w/docs/guide.md", kind: "markdown" }),
          requestLinks: () => {},
          listFiles: async (prefix) =>
            ["docs/", "docs/guide.md", "README.md"].filter((entry) => entry.startsWith(prefix)),
          linkLabel: (key) => (key === "linkPlaceholder" ? "Link URL or path" : key),
        },
      },
    });
    editor = next;
    void next.create().then(() => {
      next.load("# Getting Started\n\nSee [the guide](docs/guide.md) for more.\n\n## API\n\nPlain words here.\n");
      const api = window as unknown as Record<string, unknown>;
      // The `link` page command (Cmd-K comes from the app's key dispatcher, never the page).
      api.__openLink = () => next.openLinkPopover();
      api.__snapshot = () => next.snapshot().text;
      api.__ready = true;
    });
  };
  return (
    <TooltipProvider>
      <MarkdownPage
        store={store as never}
        strings={strings}
        editorRef={editorRef}
        overlays={overlays}
        onBack={() => report("back")}
        onForward={() => report("forward")}
      />
    </TooltipProvider>
  );
}

// The markdown page brings its own landmarks (header, main); the others sit in a main.
const view =
  params.get("case") === "markdown" ? (
    markdown()
  ) : (
    <main>
      <h1>ui a11y harness</h1>
      {params.get("case") === "picker" ? <Picker /> : <Widgets />}
    </main>
  );
createRoot(root).render(
  <UiProvider container={page} dir={rtl ? "rtl" : "ltr"}>
    <TooltipProvider>{view}</TooltipProvider>
  </UiProvider>,
);
