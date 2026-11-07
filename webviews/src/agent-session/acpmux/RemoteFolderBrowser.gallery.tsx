// l10n-allow-file: gallery fixtures (sample machine and folders), not shipped UI.
//
// The folder menu's browser for another machine (RemoteFolderBrowser.tsx), in the menu's own box at
// the dock's widths. Three looks name where the browser is: `title` (shipped: the folder's name over
// its path, one header row at every width), `crumbs` (every folder from the top, one click to any of
// them, but at 240 px the trail scrolls sideways and hides where it starts) and `field` (the path as
// an editable field: fast for a typed path, but a second text field beside the filter reads as two
// places to type). The states: a folder opened, a listing cut at its cap, and an acpmux too old to list.
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { RemoteFolderBrowser } from "./RemoteFolderBrowser";
import type { BrowseFolders, BrowseReply } from "./folderBrowse";

type Props = ComponentProps<typeof RemoteFolderBrowser>;

const HOME = "/home/leo";
const folders = (parent: string, names: string[]): BrowseReply["entries"] =>
  names.map((name) => ({ name, path: `${parent}/${name}`, kind: "dir" as const }));
const tree: Record<string, BrowseReply["entries"]> = {
  "": folders(HOME, ["Projects", "scratch"]),
  [`${HOME}/Projects`]: [
    ...folders(`${HOME}/Projects`, ["atlas-web", "cmux", "cmux-design-references", "leo-workspace", "relay"]),
    { name: "shared-data", path: "/srv/shared-data", kind: "symlink", target: "dir", outside: true },
  ],
  [`${HOME}/Projects/cmux`]: folders(`${HOME}/Projects/cmux`, ["cmux-tui", "design", "docs", "scripts", "webviews"]),
};

const answer =
  (extra: Partial<BrowseReply> = {}): BrowseFolders =>
  async ({ path }) => {
    // A machine across a network answers in a moment, not at once.
    await new Promise((resolve) => setTimeout(resolve, 120));
    const at = path ?? null;
    const entries =
      tree[at ?? ""] ??
      folders(
        at ?? HOME,
        Array.from({ length: 40 }, (_, i) => `module-${i + 1}`),
      );
    return {
      path: at,
      parent: at ? at.split("/").slice(0, -1).join("/") || "/" : null,
      home: HOME,
      entries,
      total: entries.length,
      offset: 0,
      ...extra,
    };
  };

const base: Props = {
  machine: "big-red",
  peer: "big-red",
  list: answer(),
  start: `${HOME}/Projects`,
  size: { width: 280, height: 300 },
  onPick: () => undefined,
  onBack: () => undefined,
};

const rowsShown: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-browse-row") !== null);
};
const openCmux: Play = async (ctx) => {
  await rowsShown(ctx);
  const row = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-browse-row")].find(
    (r) => r.textContent === "cmux",
  );
  row?.click();
  await ctx.waitFor(() =>
    [...ctx.document.querySelectorAll(".acpmux-browse-row")].some((r) => r.textContent === "webviews"),
  );
};

export default componentEntry<Props>({
  id: "agent-pane.remote-folder-browser",
  title: "Folder menu: browse another machine",
  area: "Agent pane",
  pane: true,
  height: 360,
  widths: { narrow: 240, normal: 320, wide: 320 },
  anchors: [{ selector: ".acpmux-browse" }],
  covers: ["agent-session/acpmux/RemoteFolderBrowser.tsx#RemoteFolderBrowser"],
  styles: () => import("./styles.css"),
  checks: {
    anchorMovePx: { value: 0, reason: "The browser keeps the menu's box: opening a folder moves no edge." },
    layoutShiftMax: {
      value: 0,
      reason:
        "Rows are reserved while the machine answers; its answer fills the list without moving the header or Use.",
    },
    longFrameFailMs: { value: 33, reason: "Only the rows in view mount, whatever the folder's size." },
  },
  load: async () => RemoteFolderBrowser,
  variants: {
    title: {
      note: "Shipped. The folder's name over its full path (cut at its start), Up on the left; one row at every width.",
      props: { ...base, look: "title" },
      play: openCmux,
    },
    crumbs: {
      note: "Every folder from ~ as a breadcrumb; one click to any of them, but the trail scrolls at the dock's width.",
      props: { ...base, look: "crumbs" },
      play: openCmux,
    },
    field: {
      note: "The path as an editable field (Return goes there); a second text field beside the filter.",
      props: { ...base, look: "field" },
      play: openCmux,
    },
    top: {
      note: "Browse big-red… opens on the folders big-red starts chats in; Use waits for a folder.",
      props: { ...base, start: null },
      play: rowsShown,
    },
    truncated: {
      note: "A folder past the machine's entry cap lists what it read and says so in a quiet line.",
      props: {
        ...base,
        start: `${HOME}/Projects/huge`,
        list: answer({ truncated: { reason: "cap", scanned: 5000 } }),
      },
      play: rowsShown,
    },
    unsupported: {
      note: "big-red's acpmux predates browsing: the browser says to update it; the known folders stay in the list.",
      props: { ...base, list: () => Promise.reject({ code: -32601, message: "Method not found" }) },
    },
  },
});
