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
  delayMs?: number;
  fail?: boolean;
  direction?: UiDirection;
};

function entry(path: string, name: string, kind: PickerEntry["kind"], git = false): PickerEntry {
  return { name, path: `${path}/${name}`, kind, ...(git ? { git: true } : {}) };
}

function entriesAt(path: string): PickerEntry[] {
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

function GalleryPathPicker({ mode = "folder", start = HOME, delayMs = 0, fail = false, direction = "ltr" }: Props) {
  const [container, setContainer] = useState<HTMLElement | null>(null);
  const [receipt, setReceipt] = useState("Ready");
  const strings = viewerEmptyStrings([direction === "rtl" ? "ar" : "en"]);
  const list = async (path: string | null, options: { hidden: boolean }) => {
    if (delayMs) await new Promise((resolve) => setTimeout(resolve, delayMs));
    if (fail) throw new Error("fixture listing failed");
    return listing(path, options.hidden);
  };

  return (
    <div ref={setContainer} className="ve-sheet-host path-picker-gallery-host">
      {container ? (
        <UiProvider container={container} dir={direction}>
          <PathPickerDialog
            mode={mode}
            list={list}
            locations={async () => ({
              locations: [
                { kind: "workspace", path: PROJECTS },
                { kind: "home", path: HOME },
                { kind: "desktop", path: `${HOME}/Desktop` },
                { kind: "downloads", path: `${HOME}/Downloads` },
              ],
            })}
            strings={strings}
            recents={[CMUX, `${PROJECTS}/messageslab`].slice(0, mode === "folder" ? 1 : 2)}
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

const locations: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.find({ role: "option", name: "Projects" }));
  await ctx.click({ role: "option", name: "Projects" });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector('.ve-crumb[aria-current="location"]')?.textContent === "Projects");
};

const filter: Play = async (ctx) => {
  await ctx.focus({ selector: ".ve-picker-field" });
  await ctx.type("cmux");
  await ctx.waitFor(() => ctx.find({ role: "option", name: /cmux/ }));
};

const hidden: Play = async (ctx) => {
  await ctx.focus({ selector: ".ve-picker-field" });
  await ctx.type(".");
  await ctx.waitFor(() => ctx.find({ role: "option", name: ".config" }));
};

const pathCompletion: Play = async (ctx) => {
  await ctx.focus({ selector: ".ve-picker-field" });
  await ctx.type(`${PROJECTS}/cm`);
  await ctx.waitFor(() => ctx.find({ role: "option", name: "cmux/" }));
  await ctx.press("ArrowRight");
  await ctx.waitFor(() => ctx.find({ selector: ".ve-picker-field" }).getAttribute("value") === `${CMUX}/`);
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector('.ve-crumb[aria-current="location"]')?.textContent === "cmux");
};

const virtualized: Play = async (ctx) => {
  await ctx.click({ role: "option", name: "surface-000" });
  await ctx.press("Tab");
  await ctx.waitFor(
    () => ctx.document.querySelector('.ve-crumb[aria-current="location"]')?.textContent === "surface-000",
  );
  await ctx.press("End");
  await ctx.waitFor(() => {
    const input = ctx.find({ selector: ".ve-picker-field" });
    const id = input.getAttribute("aria-activedescendant");
    return id !== null && ctx.document.getElementById(id)?.getAttribute("aria-setsize") === "300";
  });
};

const rtlCompletion: Play = async (ctx) => {
  await ctx.focus({ selector: ".ve-picker-field" });
  await ctx.type("cmux");
  await ctx.waitFor(() => ctx.find({ role: "option", name: /cmux/ }));
  await ctx.press("ArrowLeft");
  await ctx.waitFor(() => ctx.document.querySelector('.ve-crumb[aria-current="location"]')?.textContent === "cmux");
};

const cancel: Play = async (ctx) => {
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
      value: 400,
      reason: "A local listing transition includes the fixture's asynchronous host response.",
    },
  },
  covers: ["viewer-empty/PathPicker.tsx#PathPicker", "viewer-empty/PathPicker.tsx#PathPickerDialog"],
  styles: () => Promise.all([import("./styles.css"), import("./PathPicker.gallery.css")]),
  load: async () => GalleryPathPicker,
  variants: {
    locations: { props: {}, play: locations },
    filter: { props: { start: PROJECTS }, play: filter },
    hidden: { props: {}, play: hidden },
    "path-completion": { props: { start: PROJECTS }, play: pathCompletion },
    "any-file": { props: { mode: "anyFile", start: PROJECTS } },
    loading: { props: { delayMs: 500 } },
    error: { props: { fail: true } },
    virtualized: { props: { start: CMUX }, play: virtualized },
    rtl: { props: { direction: "rtl", start: PROJECTS }, play: rtlCompletion },
    cancel: { props: {}, play: cancel },
  },
});
