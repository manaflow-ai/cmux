// l10n-allow-file: gallery fixtures (sample paths and search results), not shipped UI.
import { useState, type ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";
import { Composer } from "./Composer";
import type { Play } from "../../gallery/play";
import { FileSearch } from "./FileSearch";
import type { FileSearchSource } from "./fileSearchModel";

type Props = ComponentProps<typeof FileSearch>;

const files = [
  { path: "src/agent-session/acpmux/Composer.tsx", matches: [0, 1, 2, 3, 4, 5, 6] },
  { path: "src/agent-session/acpmux/ComposerPickers.tsx", matches: [0, 1, 2, 3, 4, 5, 6] },
  { path: "src/agent-session/acpmux/composerControls.css", matches: [0, 1, 2, 3, 4, 5, 6] },
  { path: "webviews/src/gallery/format.ts", matches: [] },
];
const composerFiles = files.slice(0, 3);

const search: FileSearchSource = async (query) => {
  await new Promise((resolve) => setTimeout(resolve, 12));
  if (query === "zz") return { root: "/Users/you/src/cmux", results: [] };
  return {
    root: "/Users/you/src/cmux",
    search_root: "",
    results: query.toLowerCase().includes("composer") ? composerFiles : files,
  };
};

const truncatedSearch: FileSearchSource = async () => ({
  root: "/Users/you/src/cmux",
  results: files,
  truncated: true,
});

const outsideRepository: FileSearchSource = async () => {
  const error = new Error("not a repository");
  Object.assign(error, { details: { extra: { code: "not_a_repository" } } });
  throw error;
};

const baseProps: Props = {
  search,
  onPick: () => undefined,
  onClose: () => undefined,
  debounceMs: 10,
};

const field = { selector: 'input[role="combobox"]' };

/// The chat the palette opens over: Search Files sits over the transcript, in the composer's parent.
const hostChat = chat([
  user("Where does the composer render its pickers?", 4),
  assistant("ComposerPickers.tsx draws the model and effort chips; Composer.tsx places them.", 3),
]);
const NoChips = () => null;

/// The pane's frame (App.tsx) with the real composer the palette opens from (Composer.tsx portals
/// FileSearch into the composer's parent), so a closed palette leaves that composer in view.
function GalleryFileSearch(props: Props) {
  const [open, setOpen] = useState(true);
  const [picked, setPicked] = useState("");
  return (
    <section className="acpmux-shell" aria-label={hostChat.summary?.title}>
      <div className="acpmux-main">
        <div className="acpmux-stage">
          <output data-file-search-picked={picked || undefined} data-file-search-closed={open ? undefined : "true"}>
            {picked}
          </output>
        </div>
        <div className="acpmux-dock">
          <Composer snapshot={hostChat} chips={NoChips} onSend={() => true} onStop={() => undefined} />
          {open && (
            <FileSearch
              {...props}
              onPick={(path) => {
                setOpen(false);
                setPicked(path);
                props.onPick(path);
              }}
              onClose={() => {
                setOpen(false);
                props.onClose();
              }}
            />
          )}
        </div>
      </div>
    </section>
  );
}

const openResults: Play = async (ctx) => {
  await ctx.type("Composer", field);
  await ctx.waitFor(() => ctx.document.querySelectorAll('[role="option"]').length === composerFiles.length);
  const input = ctx.find(field);
  const active = input.getAttribute("aria-activedescendant");
  if (!active || ctx.document.getElementById(active)?.getAttribute("aria-selected") !== "true")
    throw new Error("file search did not expose its highlighted result");
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => ctx.find(field).getAttribute("aria-activedescendant")?.endsWith("-1") ?? false);
};

const pickResult: Play = async (ctx) => {
  await openResults(ctx);
  await ctx.press("Enter");
  await ctx.waitFor(
    () =>
      ctx.document.querySelector("[data-file-search-picked]")?.getAttribute("data-file-search-picked") ===
      composerFiles[1]!.path,
  );
};

const noResults: Play = async (ctx) => {
  await ctx.type("zz", field);
  await ctx.waitFor(
    () =>
      ctx.document.querySelector('[role="listbox"][aria-busy="false"]') !== null &&
      ctx.document.querySelectorAll('[role="option"]').length === 0 &&
      Boolean(ctx.document.querySelector(".acpmux-file-note")?.textContent?.trim()),
  );
};

const closeWithEscape: Play = async (ctx) => {
  await ctx.press("Escape");
  await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-file-search"));
  if (!ctx.document.querySelector(".acpmux-composer")) throw new Error("closing file search removed the composer");
};

export default componentEntry<Props>({
  id: "agent-pane.file-search",
  title: "File search",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/FileSearch.tsx#FileSearch"],
  load: async () => GalleryFileSearch,
  styles: () => import("./styles.css"),
  widths: { narrow: 360, normal: 520, wide: 760 },
  height: 460,
  anchors: [{ selector: ".acpmux-file-search" }],
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Searching is an overlay over the transcript and must not move the underlying composer anchor.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "Results and notes stay inside the fixed file-search dialog instead of reflowing the pane.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Typing and stepping through file results should remain responsive on the gallery host.",
    },
    settleMaxMs: {
      value: 250,
      reason: "File search typing, navigation and dismissal should settle within a quarter second.",
    },
  },
  variants: {
    idle: { note: "The palette opens with an empty query and a quiet hint.", props: baseProps },
    matches: {
      note: "A query highlights matching characters and ArrowDown moves the active result without leaving the field.",
      props: baseProps,
      play: openResults,
    },
    pick: {
      note: "Enter picks the highlighted path for the composer mention flow.",
      props: baseProps,
      play: pickResult,
    },
    "no-results": {
      note: "A query with no matches reports the empty state without stale rows.",
      props: baseProps,
      play: noResults,
    },
    truncated: {
      note: "A large result set keeps the service's truncated notice below the visible rows.",
      props: { ...baseProps, search: truncatedSearch },
      play: async (ctx) => {
        await ctx.type("src", field);
        await ctx.waitFor(() => ctx.document.querySelectorAll('[role="option"]').length === files.length);
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-file-note").length === 1);
      },
    },
    "outside-repository": {
      note: "A search outside a repository names the host failure instead of showing a blank palette.",
      props: { ...baseProps, search: outsideRepository },
      play: async (ctx) => {
        await ctx.type("src", field);
        await ctx.waitFor(
          () =>
            ctx.document.querySelector('[role="listbox"][aria-busy="false"]') !== null &&
            Boolean(ctx.document.querySelector(".acpmux-file-note")?.textContent?.trim()),
        );
      },
    },
    escape: {
      note: "Escape closes the palette and leaves dismissal to the host: the chat's composer stays.",
      props: baseProps,
      play: closeWithEscape,
    },
  },
});
