// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { StashGalleryProps } from "./galleryFixture";

// The list is windowed: a group's header and its rows are siblings, so a play finds a group's rows by
// their `data-stash` (the group's id), never by nesting or by `:first-of-type` / `:last-of-type`.
const byIndex = (items: Iterable<HTMLElement>) =>
  [...items].sort((a, b) => Number(a.dataset.index) - Number(b.dataset.index));
const groupIds = (document: Document) =>
  byIndex(document.querySelectorAll<HTMLElement>(".stash-group[data-stash]")).map((group) => group.dataset.stash!);
const group = (stash: string) => `.stash-group[data-stash="${CSS.escape(stash)}"]`;
/** The group's bottom row, by its `data-key`. */
const lastRow = (document: Document, stash: string) => {
  const key = byIndex(document.querySelectorAll<HTMLElement>(`.stash-row[data-stash="${CSS.escape(stash)}"]`)).at(-1)
    ?.dataset.key;
  if (!key) throw new Error(`group ${stash} shows no row`);
  return `.stash-row[data-key="${CSS.escape(key)}"]`;
};

export default componentEntry<StashGalleryProps>({
  id: "pages.stash",
  title: "Stashed Tabs",
  area: "Pages",
  height: 640,
  widths: { narrow: 560, normal: 1000, wide: 1400 },
  covers: ["page:cmux.stash", "pages/stash/StashPage.tsx#StashPage", "pages/stash/galleryFixture.tsx"],
  load: async () => (await import("./galleryFixture")).StashGallery,
  styles: async () => {
    await import("../../ui/ui.css");
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    normal: {
      note: "Recommended: three stashes, one compact line per page, a whole workspace with its tabs, and an untitled imported group.",
      props: {},
    },
    empty: { note: "Nothing stashed yet: the hint says where Save and Close is.", props: { stashes: "empty" } },
    "many-stashes": {
      note: "Twelve groups of long titles: rows and group names truncate; Restore All stays on each header row.",
      props: { stashes: "many" },
    },
    search: {
      note: "A search keeps the matching pages only; Restore All still takes the whole group.",
      props: { query: "typescript" },
    },
    "no-matches": { note: "A search that matches nothing.", props: { query: "zzz" } },
    "import-open": {
      note: "Import from OneTab… opens the paste box inline, above the list (never a sheet).",
      props: {
        importText:
          "https://a.example.test/ | A page\nhttps://b.example.test/\n\nhttps://c.example.test/ | Another group",
      },
    },
    disconnected: { note: "The stash owner is not connected.", props: { offline: true } },
    "row-menu": {
      note: "A row has no destructive control of its own: its right-click menu holds Restore and Delete.",
      props: {},
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".stash-row"));
        if (ctx.document.querySelector(".stash-row button:not(.stash-row-main)")) {
          throw new Error("a stash row has a second button");
        }
        await ctx.contextMenu({ selector: ".stash-row" });
        await ctx.waitFor(() => ctx.document.querySelector(".page-menu-item.destructive"));
      },
    },
    "group-menu": {
      note: "A group header shows Restore All only; Shift-F10 on it opens the group's menu: Restore All, Restore in New Workspace, Delete Group.",
      props: {},
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".stash-group-header"));
        if (
          ctx.document.querySelectorAll(".stash-group-header button").length !==
          ctx.document.querySelectorAll(".stash-group").length
        ) {
          throw new Error("a group header shows more than Restore All");
        }
        await ctx.focus({ selector: `${group(groupIds(ctx.document)[0]!)} .stash-group-restore` });
        await ctx.press("Shift+F10");
        await ctx.waitFor(() => ctx.document.querySelector(".page-menu-item.destructive"));
      },
    },
    "group-menu-pointer": {
      note: "A right-click on a group header opens the same menu.",
      props: {},
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".stash-group-header"));
        await ctx.contextMenu({ selector: `${group(groupIds(ctx.document)[0]!)} .stash-group-name` });
        await ctx.waitFor(() => ctx.document.querySelector(".page-menu-item.destructive"));
      },
    },
    "row-delete-keyboard": {
      note: "Shift-F10 on the focused bottom row opens its menu; Delete hides the row behind the app's Undo toast.",
      props: { undoPending: true },
      play: async (ctx) => {
        const rows = () => ctx.document.querySelectorAll(".stash-row").length;
        await ctx.waitFor(() => rows() === 6);
        // The bottom row, so no row moves when it hides.
        const bottom = groupIds(ctx.document).at(-1)!;
        await ctx.focus({ selector: `${lastRow(ctx.document, bottom)} .stash-row-main` });
        await ctx.press("Shift+F10");
        await ctx.waitFor(() => ctx.document.querySelector(".page-menu-item.destructive"));
        await ctx.click({ selector: ".page-menu-item.destructive" });
        await ctx.waitFor(() => rows() === 5);
        await ctx.waitFor(() => !ctx.document.querySelector(".page-menu"));
      },
    },
    "restore-all-during-undo": {
      note: "A row deleted, its Undo toast still up, then Restore All: the hidden row stays hidden; the group's shown rows reopen.",
      props: { undoPending: true },
      play: async (ctx) => {
        const titles = () =>
          [...ctx.document.querySelectorAll(".stash-row-title")].map((title) => title.textContent ?? "");
        await ctx.waitFor(() => titles().length === 6);
        // The bottom group, so nothing under it moves: its last row first, then Restore All.
        const bottom = groupIds(ctx.document).at(-1)!;
        await ctx.contextMenu({ selector: lastRow(ctx.document, bottom) });
        await ctx.waitFor(() => ctx.document.querySelector(".page-menu-item.destructive"));
        await ctx.click({ selector: ".page-menu-item.destructive" });
        await ctx.waitFor(() => titles().length === 5);
        await ctx.waitFor(() => !ctx.document.querySelector(".page-menu"));
        await ctx.click({ selector: `${group(bottom)} .stash-group-restore` });
        await ctx.waitFor(() => titles().length === 4);
        if (titles().includes("https://example.org/long/path")) throw new Error("Restore All reopened the hidden row");
      },
    },
  },
});
