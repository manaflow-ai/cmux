// l10n-allow-file: gallery fixtures (sample prose), not shipped UI.
// A nightly build or an Actions run in a reply links to its run (Leo 2026-11-10, of "build
// 4270949510401," as plain text: "should these be linked too?"). Every look renders the real
// reply renderer.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { RunRefLook } from "../../../gallery/fixtures/RunRefLinksPreview";

const BUILD = "https://github.com/manaflow-ai/cmux/actions/runs/42709495104";
const openCard: Play = async (ctx) => {
  await ctx.hover({ selector: `a.cv-chip.is-ref[href="${BUILD}"]` });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-link-preview"));
};

export default componentEntry<{ look: RunRefLook }>({
  id: "agent-pane.run-ref-links",
  title: "Nightly builds and Actions runs in a reply",
  area: "Agent pane",
  height: 300,
  widths: { narrow: 360, normal: 640, wide: 860 },
  covers: ["githubReferences.ts#runReferences", "agent-session/acpmux/conversation/proseIds.ts#proseIds"],
  load: () => import("../../../gallery/fixtures/RunRefLinksPreview").then((module) => module.RunRefLinksPreview),
  styles: () =>
    Promise.all([
      import("../../shared/styles.css"),
      import("../styles.css"),
      import("./conversation.css"),
      import("../chips/chips.css"),
      import("../../../gallery/fixtures/runRefLinks.gallery.css"),
    ]),
  variants: {
    before: {
      props: { look: "before" },
      note: "Before: build 4270949510401, build #4270949510402 and run 42709495104 were plain text; cmux#39931 and the SHA linked.",
    },
    chip: {
      props: { look: "chip" },
      note: "Chosen: the reference chip cmux#N draws, the GitHub mark and the number; the word before it stays prose. It opens the run's page.",
    },
    "chip-card": {
      props: { look: "chip" },
      play: openCard,
      note: "Chosen, hovered: the link card every web chip opens, with Open and Open in.",
    },
    "plain-link": {
      props: { look: "plain-link" },
      note: "Alternative: an underlined number with no mark. Reads as any link; a run no longer looks like a GitHub reference.",
    },
  },
});
