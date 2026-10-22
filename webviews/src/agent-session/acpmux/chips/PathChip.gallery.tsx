// l10n-allow-file: gallery fixtures (sample paths), not shipped UI.
import { componentEntry, type ChipHostFixture } from "../../../gallery/format";

const file = "/Users/you/src/atlas-web/src/net/retry.ts";
const folder = "/Users/you/src/atlas-web/src/net/";
const outside = "/Users/you/Documents/notes.md";
const denied = "/Users/you/.ssh/id_ed25519";
const shot = "/tmp/cmux-shots/after-opened.png";
const projectShot = "/Users/you/src/atlas-web/shots/after-opened.png";
const log = "/Users/you/src/atlas-web/logs/build.log";
// A 16x10 PNG, public and tiny, standing in for a screenshot.
const shotImage =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAKCAIAAAAy3EnLAAAAFElEQVR42mOwybtEEmIY1TA0NQAA/OjtgR+YOkQAAAAASUVORK5CYII=";

const rootFile: ChipHostFixture = { paths: { [file]: { place: "root", folder: false } } };
const rootFolder: ChipHostFixture = { paths: { [folder]: { place: "root", folder: true } } };
const outsideConfirm: ChipHostFixture = {
  paths: { [outside]: { place: "outside", folder: false } },
  policy: { outsideRoots: "confirm" },
};
// The host draws no thumbnail of an image outside the folders (until #23879), so its card is
// the plain file card: name, path and Open.
const outsidePreview: ChipHostFixture = {
  paths: { [shot]: { place: "outside", folder: false } },
  policy: { outsideRoots: "confirm" },
};
const imagePreview: ChipHostFixture = {
  paths: { [projectShot]: { place: "root", folder: false } },
  images: { [projectShot]: shotImage },
};
const textPreview: ChipHostFixture = {
  paths: { [log]: { place: "root", folder: false } },
  previews: {
    [log]: {
      lines: [
        "$ bun run build",
        "vite v7.1.2 building for production...",
        "✓ 412 modules transformed.",
        "built in 2.14s",
      ],
      truncated: false,
    },
  },
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
      note: "Outside the session roots: the lock advertises the host confirmation boundary.",
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
    "image-preview": {
      note: "A screenshot chip in the project previews on hover: its thumbnail and Open.",
      chipHost: imagePreview,
      props: { path: projectShot },
      play: async (ctx) => {
        await ctx.focus({ selector: ".cv-chip.is-path" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-path-preview__image"));
      },
    },
    "outside-preview": {
      note: "A locked screenshot chip outside the roots still has its card and Open; the host draws no thumbnail there.",
      chipHost: outsidePreview,
      props: { path: shot },
      play: async (ctx) => {
        await ctx.focus({ selector: ".cv-chip.is-outside" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-path-preview .cv-link-preview__open"));
      },
    },
    "text-preview": {
      note: "A log file's hover card shows its first lines from the host's bounded read.",
      chipHost: textPreview,
      props: { path: log },
      play: async (ctx) => {
        await ctx.focus({ selector: ".cv-chip.is-path" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-path-preview__text"));
      },
    },
    denied: { props: { path: denied, written: denied } },
  },
});
