// l10n-allow-file: gallery fixtures (sample paths), not shipped UI.
import { componentEntry, type ChipHostFixture } from "../../../gallery/format";
import { fileKindIcon } from "./fileKindIcon.experiment";

const file = "/Users/you/src/atlas-web/src/net/retry.ts";
const folder = "/Users/you/src/atlas-web/src/net/";
const outside = "/Users/you/Documents/notes.md";
const denied = "/Users/you/.ssh/id_ed25519";
// A report's supporting artifacts: a document, data and a log (fileKindIcon.experiment.ts).
const doc = "/Users/you/src/atlas-web/reports/october/manifest.md";
const data = "/Users/you/src/atlas-web/reports/october/pr-evidence.json";
const log = "/Users/you/src/atlas-web/reports/october/git-discovery.log";
const inRoot = (path: string): ChipHostFixture => ({ paths: { [path]: { place: "root", folder: false } } });

const rootFile: ChipHostFixture = { paths: { [file]: { place: "root", folder: false } } };
const rootFolder: ChipHostFixture = { paths: { [folder]: { place: "root", folder: true } } };
const outsideConfirm: ChipHostFixture = {
  paths: { [outside]: { place: "outside", folder: false } },
  policy: { outsideRoots: "confirm" },
};
const outsideText: ChipHostFixture = {
  paths: { [outside]: { place: "outside", folder: false } },
  policy: { outsideRoots: "text" },
};

export default componentEntry<{ path: string; label?: string; written?: string }>({
  id: "agent-pane.path-chip",
  title: "Path chips",
  area: "Agent pane",
  covers: ["agent-session/acpmux/chips/LinkChips.tsx#PathChip"],
  load: () => import("./LinkChips").then((module) => module.PathChip),
  styles: () =>
    Promise.all([import("../styles.css"), import("../conversation/conversation.css"), import("./chips.css")]),
  widths: { narrow: 360, normal: 640, wide: 860 },
  variants: {
    file: { chipHost: rootFile, props: { path: file } },
    folder: { chipHost: rootFolder, props: { path: folder } },
    "outside-lock": {
      note: "Outside the session roots: hover explains the boundary without a persistent lock.",
      chipHost: outsideConfirm,
      props: { path: outside },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".cv-chip.is-outside"));
        await ctx.click({ selector: ".cv-chip.is-outside" });
      },
    },
    "outside-text": {
      note: "The same outside path under the text-only policy.",
      chipHost: outsideText,
      props: { path: outside, written: outside },
    },
    denied: { props: { path: denied, written: denied } },
    "kind-document": { note: "A document: the page.", chipHost: inRoot(doc), props: { path: doc } },
    "kind-data": { note: "Data or code: braces.", chipHost: inRoot(data), props: { path: data } },
    "kind-log": { note: "A log: the terminal mark.", chipHost: inRoot(log), props: { path: log } },
  },
  // How the chip's icon follows the file's kind; compare the kind-* variants across the arms.
  experiment: { definition: fileKindIcon, script: [{ name: "The chip", run: async () => undefined }] },
});
