// l10n-allow-file: gallery fixtures (sample paths), not shipped UI.
import { componentEntry, type ChipHostFixture } from "../../../gallery/format";

const file = "/Users/you/src/atlas-web/src/net/retry.ts";
const folder = "/Users/you/src/atlas-web/src/net/";
const outside = "/Users/you/Documents/notes.md";
const denied = "/Users/you/.ssh/id_ed25519";

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
    denied: { props: { path: denied, written: denied } },
  },
});
