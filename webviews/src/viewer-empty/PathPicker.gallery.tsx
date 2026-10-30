// l10n-allow-file: gallery labels and paths are fixture content, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { UiProvider, type UiDirection } from "../ui/UiProvider";
import { PathPickerDialog } from "./PathPicker";
import { type PickerEntry, type PickerListing, type PickerMode } from "./ops";
import { viewerEmptyStrings } from "./strings";

const HOME = "/Users/demo";
const PROJECTS = `${HOME}/Projects`;
const CMUX = `${PROJECTS}/cmux`;

type Props = {
  mode?: PickerMode;
  start?: string;
  loading?: boolean;
  fail?: boolean;
  direction?: UiDirection;
  stableFilter?: boolean;
};

function entry(path: string, name: string, kind: PickerEntry["kind"], git = false): PickerEntry {
  return { name, path: `${path}/${name}`, kind, ...(git ? { git: true } : {}) };
}

function entriesAt(path: string): PickerEntry[] {
  if (path === "/") return [entry("/", "Users", "dir")];
  if (path === "/Users") return [entry("/Users", "demo", "dir")];
  if (path === HOME)
    return [
      entry(HOME, "Projects", "dir"),
      entry(HOME, "Desktop", "dir"),
      entry(HOME, "Downloads", "dir"),
      entry(HOME, ".config", "dir"),
      entry(HOME, "README.md", "file"),
    ];
  if (path === PROJECTS)
    return [
      entry(PROJECTS, "cmux", "dir", true),
      entry(PROJECTS, "messageslab", "dir", true),
      entry(PROJECTS, "cmux-gallery", "dir"),
      entry(PROJECTS, "docs", "dir"),
      entry(PROJECTS, "README.md", "file"),
      entry(PROJECTS, "roadmap.md", "file"),
      entry(PROJECTS, "preview.png", "file"),
    ];
  if (path === CMUX)
    return Array.from({ length: 360 }, (_, index) => entry(CMUX, `surface-${String(index).padStart(3, "0")}`, "dir"));
  if (path.startsWith(`${CMUX}/surface-`))
    return Array.from({ length: 360 }, (_, index) => entry(path, `child-${String(index).padStart(3, "0")}`, "dir"));
  if (path === `${PROJECTS}/messageslab`)
    return [
      entry(`${PROJECTS}/messageslab`, "README.md", "file"),
      entry(`${PROJECTS}/messageslab`, "index.ts", "file"),
    ];
  if (path === `${PROJECTS}/cmux-gallery`)
    return [
      entry(`${PROJECTS}/cmux-gallery`, "README.md", "file"),
      entry(`${PROJECTS}/cmux-gallery`, "gallery.tsx", "file"),
    ];
  if (path === `${PROJECTS}/docs`)
    return [entry(`${PROJECTS}/docs`, "picker.md", "file"), entry(`${PROJECTS}/docs`, "parity.md", "file")];
  if (path === `${HOME}/Desktop` || path === `${HOME}/Downloads`) return [];
  throw new Error(`No fixture listing for ${path}`);
}

function listing(path: string | null, hidden: boolean): PickerListing {
  const actual = path == null || path === "~" ? HOME : path;
  const parent = actual === "/" ? null : actual.slice(0, actual.lastIndexOf("/")) || "/";
  return {
    path: actual,
    parent,
    home: HOME,
    entries: entriesAt(actual).filter((item) => hidden || !item.name.startsWith(".")),
  };
}

function GalleryPathPicker({
  mode = "folder",
  start = HOME,
  loading = false,
  fail = false,
  direction = "ltr",
  stableFilter = false,
}: Props) {
  const [container, setContainer] = useState<HTMLElement | null>(null);
  const [receipt, setReceipt] = useState("Ready");
  const strings = viewerEmptyStrings([direction === "rtl" ? "ar" : "en"]);
  const list = async (path: string | null, options: { hidden: boolean }) => {
    // Keep the loading preview stable for the base/head/repeat screenshot matrix.
    if (loading) return new Promise<PickerListing>(() => {});
    if (fail) throw new Error("fixture listing failed");
    const value = listing(path, options.hidden);
    if (stableFilter && value.path === PROJECTS)
      return { ...value, entries: value.entries.filter((item) => item.name.startsWith("cmux")) };
    // The any-file play starts in a project folder with one deliberate fuzzy match. Keeping the
    // initial row count stable makes the measured filter about input response, not row removal.
    if (mode === "anyFile" && value.path === PROJECTS)
      return { ...value, entries: value.entries.filter((item) => item.name === "messageslab") };
    return value;
  };

  return (
    <div
      ref={setContainer}
      className={`ve-sheet-host path-picker-gallery-host${mode === "anyFile" ? " path-picker-gallery-any-file" : ""}`}
    >
      {container ? (
        <UiProvider container={container} dir={direction}>
          <PathPickerDialog
            mode={mode}
            list={list}
            locations={async () => ({
              locations:
                mode === "anyFile" || stableFilter
                  ? []
                  : [
                      { kind: "workspace" as const, path: PROJECTS },
                      { kind: "home" as const, path: HOME },
                      { kind: "desktop" as const, path: `${HOME}/Desktop` },
                      { kind: "downloads" as const, path: `${HOME}/Downloads` },
                    ],
            })}
            strings={strings}
            recents={
              mode === "anyFile" || stableFilter
                ? []
                : mode === "folder"
                  ? [CMUX]
                  : [`${PROJECTS}/README.md`, `${PROJECTS}/messageslab/index.ts`]
            }
            start={start}
            onChoose={(path) => setReceipt(`Chosen: ${path}`)}
            onCancel={() => setReceipt("Cancelled")}
          />
        </UiProvider>
      ) : null}
      <output className="path-picker-gallery-receipt" data-testid="path-picker-gallery-receipt" aria-live="polite">
        {receipt}
      </output>
    </div>
  );
}

const ready: Play = async (ctx) => {
  await ctx.waitFor(() => {
    const picker = ctx.document.querySelector('.ve-picker[data-phase="ready"]');
    const field = picker?.querySelector<HTMLInputElement>(".ve-picker-field");
    // The picker chunk loads its CSS alongside the stage. Do not begin an interaction while the
    // field is still at the browser's intrinsic input height: the first click would then measure
    // the stylesheet landing as a false 13 px navigation shift.
    return field && field.getBoundingClientRect().height >= 30;
  });
};

const locations: Play = async (ctx) => {
  await ready(ctx);
  await ctx.waitFor(() => ctx.find({ role: "option", name: "Projects" }));
  await ctx.click({ role: "option", name: "Projects" });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector('.ve-crumb[aria-current="location"]')?.textContent === "Projects");
};

const filter: Play = async (ctx) => {
  await ready(ctx);
  await ctx.focus({ selector: ".ve-picker-field" });
  await ctx.type("cmux");
  await ctx.waitFor(() => ctx.find({ role: "option", name: /cmux/ }));
};

const hidden: Play = async (ctx) => {
  await ready(ctx);
  await ctx.focus({ selector: ".ve-picker-field" });
  await ctx.type(".");
  await ctx.waitFor(() => ctx.find({ role: "option", name: ".config" }));
};

const pathCompletion: Play = async (ctx) => {
  await ready(ctx);
  await ctx.focus({ selector: ".ve-picker-field" });
  await ctx.type(`${PROJECTS}/cm`);
  await ctx.waitFor(() => ctx.find({ role: "option", name: "cmux/" }));
  await ctx.press("ArrowRight");
  await ctx.waitFor(() => ctx.find({ selector: ".ve-picker-field" }).getAttribute("value") === `${CMUX}/`);
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector('.ve-crumb[aria-current="location"]')?.textContent === "cmux");
};

const recentFolders: Play = async (ctx) => {
  await ready(ctx);
  await ctx.click({ selector: '[data-row="recents"]' });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.find({ selector: `[data-row="recent"][title="${CMUX}"]` }));
};

const recentFile: Play = async (ctx) => {
  await ready(ctx);
  await ctx.click({ selector: '[data-row="recents"]' });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.find({ role: "option", name: "README.md" }));
  if (ctx.document.querySelector('[data-row="recent"][title$="index.ts"]')) {
    throw new Error("The markdown picker must omit non-markdown recent files");
  }
  await ctx.press("Enter");
  await ctx.waitFor(
    () => ctx.find({ testId: "path-picker-gallery-receipt" }).textContent === `Chosen: ${PROJECTS}/README.md`,
  );
};

const chooseFile: Play = async (ctx) => {
  await ready(ctx);
  await ctx.type("README", { selector: ".ve-picker-field" });
  await ctx.waitFor(() => ctx.find({ role: "option", name: "README.md" }));
  await ctx.press("Enter");
  await ctx.waitFor(
    () => ctx.find({ testId: "path-picker-gallery-receipt" }).textContent === `Chosen: ${PROJECTS}/README.md`,
  );
};

const chooseAnyFile: Play = async (ctx) => {
  await ready(ctx);
  // "m" keeps the real fuzzy-filter and folder-enter path while avoiding a multi-key settle
  // budget that varies with the hosted WebKit worker.
  await ctx.type("m", { selector: ".ve-picker-field" });
  await ctx.waitFor(() => ctx.find({ role: "option", name: "messageslab" }));
  await ctx.press("Enter");
  await ctx.waitFor(
    () => ctx.document.querySelector('.ve-crumb[aria-current="location"]')?.textContent === "messageslab",
  );
  await ctx.type("i", { selector: ".ve-picker-field" });
  await ctx.waitFor(() => ctx.find({ role: "option", name: "index.ts" }));
  await ctx.press("Enter");
  await ctx.waitFor(
    () =>
      ctx.find({ testId: "path-picker-gallery-receipt" }).textContent === `Chosen: ${PROJECTS}/messageslab/index.ts`,
  );
};

const parentFolder: Play = async (ctx) => {
  await ready(ctx);
  await ctx.focus({ selector: ".ve-picker-field" });
  await ctx.press("Backspace");
  await ctx.waitFor(() => ctx.document.querySelector('.ve-crumb[aria-current="location"]')?.textContent === "Projects");
  await ctx.waitFor(
    () => ctx.document.querySelector('[role="option"][aria-selected="true"]')?.getAttribute("title") === CMUX,
  );
};

const parentPathQuery: Play = async (ctx) => {
  await ready(ctx);
  await ctx.type(`${CMUX}/`, { selector: ".ve-picker-field" });
  await ctx.waitFor(() => ctx.document.querySelector('.ve-crumb[aria-current="location"]')?.textContent === "cmux");
  await ctx.press("Meta+ArrowUp");
  await ctx.waitFor(() => ctx.find({ selector: ".ve-picker-field" }).getAttribute("value") === "~/Projects/");
  await ctx.waitFor(
    () => ctx.document.querySelector('[role="option"][aria-selected="true"]')?.getAttribute("title") === CMUX,
  );
};

const breadcrumbNavigation: Play = async (ctx) => {
  await ready(ctx);
  await ctx.focus({ selector: ".ve-picker-field" });
  await ctx.click({ role: "button", name: "Projects" });
  await ctx.waitFor(() => ctx.document.querySelector('.ve-crumb[aria-current="location"]')?.textContent === "Projects");
  await ctx.waitFor(
    () => ctx.document.querySelector('[role="option"][aria-selected="true"]')?.getAttribute("title") === CMUX,
  );
  if (ctx.document.activeElement !== ctx.find({ selector: ".ve-picker-field" })) {
    throw new Error("Breadcrumb navigation must keep the query field focused");
  }
};

const emptyFolder: Play = async (ctx) => {
  await ready(ctx);
  await ctx.click({ selector: `[data-row="place"][title="${HOME}/Desktop"]` });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector('.ve-picker[data-phase="ready"] .ve-picker-empty'));
};

const chooseEmptyFolder: Play = async (ctx) => {
  await emptyFolder(ctx);
  await ctx.press("Enter");
  await ctx.waitFor(
    () => ctx.find({ testId: "path-picker-gallery-receipt" }).textContent === `Chosen: ${HOME}/Desktop`,
  );
};

const noMatches: Play = async (ctx) => {
  await ready(ctx);
  await ctx.type("does-not-exist", { selector: ".ve-picker-field" });
  await ctx.waitFor(() => ctx.find({ selector: ".ve-picker-empty" }));
};

const virtualized: Play = async (ctx) => {
  await ready(ctx);
  await ctx.click({ role: "option", name: "surface-000" });
  await ctx.press("Tab");
  await ctx.waitFor(
    () => ctx.document.querySelector('.ve-crumb[aria-current="location"]')?.textContent === "surface-000",
  );
  await ctx.press("End");
  await ctx.waitFor(() => {
    const input = ctx.find({ selector: ".ve-picker-field" });
    const id = input.getAttribute("aria-activedescendant");
    const active = id ? ctx.document.getElementById(id) : null;
    return active?.getAttribute("aria-setsize") === "300" && active.getAttribute("aria-posinset") === "300";
  });
  if (ctx.document.querySelectorAll('[role="option"]').length >= 300) {
    throw new Error("Large folders must keep offscreen options virtualized");
  }
};

const rtlCompletion: Play = async (ctx) => {
  await ready(ctx);
  await ctx.focus({ selector: ".ve-picker-field" });
  await ctx.type("cmux");
  await ctx.waitFor(() => ctx.find({ role: "option", name: /cmux/ }));
  await ctx.press("ArrowLeft");
  await ctx.waitFor(() => ctx.document.querySelector('.ve-crumb[aria-current="location"]')?.textContent === "cmux");
};

const cancel: Play = async (ctx) => {
  await ready(ctx);
  await ctx.focus({ selector: ".ve-picker-field" });
  await ctx.type("does-not-exist");
  await ctx.press("Escape");
  await ctx.press("Escape");
  await ctx.waitFor(() => ctx.find({ testId: "path-picker-gallery-receipt" }).textContent === "Cancelled");
};

export default componentEntry<Props>({
  id: "viewer-empty.path-picker",
  title: "Path picker",
  area: "Viewer empty",
  height: 620,
  widths: { narrow: 420, normal: 620, wide: 820 },
  anchors: [{ selector: ".ve-picker-field" }],
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Changing a picker level must leave the query field anchored in the sheet.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Filtering and folder navigation should stay responsive across the local picker surface.",
    },
    layoutShiftMax: {
      value: 0.02,
      reason:
        "Listing and breadcrumb text can change while the fixed sheet stays anchored; the field anchor is still checked separately.",
    },
    settleMaxMs: {
      value: 900,
      reason: "The first trusted filter key includes hosted WebKit startup; the cold action stays under 900 ms.",
    },
  },
  covers: ["viewer-empty/PathPicker.tsx#PathPicker", "viewer-empty/PathPicker.tsx#PathPickerDialog"],
  styles: () => Promise.all([import("./styles.css"), import("./PathPicker.gallery.css")]),
  load: async () => GalleryPathPicker,
  variants: {
    locations: { props: {}, play: locations },
    filter: { props: { start: PROJECTS, stableFilter: true }, play: filter },
    hidden: { props: {}, play: hidden },
    "path-completion": { props: { start: PROJECTS, stableFilter: true }, play: pathCompletion },
    "recent-folders": { props: {}, play: recentFolders },
    "recent-file": { props: { mode: "file", start: PROJECTS }, play: recentFile },
    "markdown-file": { props: { mode: "file", start: PROJECTS }, play: chooseFile },
    "any-file": { props: { mode: "anyFile", start: PROJECTS }, play: chooseAnyFile },
    "parent-folder": { props: { start: CMUX }, play: parentFolder },
    "parent-path-query": { props: { start: PROJECTS }, play: parentPathQuery },
    breadcrumb: { props: { start: CMUX }, play: breadcrumbNavigation },
    "empty-folder": { props: {}, play: emptyFolder },
    "choose-empty-folder": { props: {}, play: chooseEmptyFolder },
    "no-matches": { props: { start: PROJECTS }, play: noMatches },
    loading: {
      props: { loading: true },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.find({ selector: '.ve-picker[data-phase="loading"] .ve-picker-empty' }));
      },
    },
    error: {
      props: { fail: true },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.find({ selector: '.ve-picker[data-phase="failed"] .ve-picker-empty' }));
      },
    },
    virtualized: { props: { start: CMUX }, play: virtualized },
    rtl: { props: { direction: "rtl", start: PROJECTS, stableFilter: true }, play: rtlCompletion },
    cancel: { props: { start: `${HOME}/Desktop`, stableFilter: true }, play: cancel },
  },
});
