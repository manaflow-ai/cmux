// l10n-allow-file: gallery fixtures (sample pull requests), not shipped UI.
// A GitHub reference in a reply links (Leo 2026-11-07, on "Relay deploy (subrouter-internal#54):":
// "should we auto-render this as a link?"). Every look renders the real reply renderer.
import { componentEntry, type ChipHostFixture } from "../../../gallery/format";
import { GALLERY_NOW, minutesAgo } from "../../../gallery/clock";
import type { Play } from "../../../gallery/play";
import type { GithubRefLook } from "../../../gallery/fixtures/GithubRefLinksPreview";

const PULL_REQUEST = "https://github.com/manaflow-ai/subrouter-internal/pull/54";
const host: ChipHostFixture = {
  pullRequests: {
    [PULL_REQUEST]: {
      pullRequest: {
        url: PULL_REQUEST,
        number: 54,
        title: "Relay deploy: route canary traffic through the new relay",
        state: "merged",
        review: "approved",
        mergeable: "",
        author: "example-dev",
        updatedAt: new Date(minutesAgo(42)).toISOString(),
        baseRef: "main",
        headRef: "lane/relay-deploy",
        labels: ["deploy"],
        additions: 214,
        deletions: 37,
        changedFiles: 6,
        files: [],
        checks: { state: "passing", passed: 24, total: 24 },
        checkList: [],
      },
      fetchedAt: GALLERY_NOW / 1000 - 30,
    },
  },
};
const openCard: Play = async (ctx) => {
  await ctx.hover({ selector: `a.cv-chip.is-ref[href="${PULL_REQUEST}"]` });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-pr-card"));
};

export default componentEntry<{ look: GithubRefLook }>({
  id: "agent-pane.github-ref-links",
  title: "GitHub references in a reply",
  area: "Agent pane",
  height: 320,
  widths: { narrow: 360, normal: 640, wide: 860 },
  covers: ["githubReferences.ts#githubReferences", "agent-session/acpmux/chips/LinkChips.tsx#UrlChip"],
  load: () => import("../../../gallery/fixtures/GithubRefLinksPreview").then((module) => module.GithubRefLinksPreview),
  styles: () =>
    Promise.all([
      import("../../shared/styles.css"),
      import("../styles.css"),
      import("./conversation.css"),
      import("../chips/chips.css"),
      import("../../../gallery/fixtures/githubRefLinks.gallery.css"),
    ]),
  variants: {
    before: {
      props: { look: "before" },
      note: "Before: subrouter-internal#54, cmux#37758 and lw#1234 were plain text; only hq#4879 and acme/widgets#9 linked.",
    },
    chip: {
      chipHost: host,
      props: { look: "chip" },
      note: "Chosen: the reference chip owner/repo#N and hq#N already draw, its GitHub mark taking the pull request's state colour once read.",
    },
    "chip-card": {
      chipHost: host,
      props: { look: "chip" },
      play: openCard,
      note: "Chosen, hovered: the pull request card every reference chip opens.",
    },
    "plain-link": {
      chipHost: host,
      props: { look: "plain-link" },
      note: "Alternative: an underlined link with no mark. Reads as any web link; a reference no longer looks like one.",
    },
    "link-card": {
      chipHost: host,
      props: { look: "link-card" },
      play: openCard,
      note: "Alternative: the plain link with the pull request card on hover.",
    },
  },
});
