// l10n-allow-file: gallery fixtures (sample rules, accounts and agent names), not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { ForumRule } from "./RulesNotice";

type Props = { rules: ForumRule[] };

const rules: ForumRule[] = [
  {
    id: "r1",
    key: "builds",
    body: "Builds and tests run on the fleet, never on this Mac.",
    author: { kind: "person", account: "leo" },
    created: 1,
    acks: [
      { sessionId: "s1", at: 2 },
      { sessionId: "s2", at: 3 },
    ],
  },
  {
    id: "r2",
    key: "ci",
    body: "Wait for CI with glaeda-gh wait; never poll the GitHub API in a loop.",
    author: { kind: "agent", sessionId: "s3", name: "fleet-ops" },
    created: 2,
    acks: [],
  },
  {
    id: "r3",
    key: "freeze",
    body: "Nightly is frozen until the release candidate is cut. Land fixes on feat-cmux-next only.",
    author: { kind: "person", account: "lawrence" },
    created: 3,
    acks: [{ sessionId: "s1", at: 4 }],
  },
];

const showAll: Play = async (ctx) => {
  await ctx.click({ selector: '[data-notice-action="rules"]' });
  await ctx.waitFor(() => ctx.document.querySelector('[data-rules-open="true"]'));
};

export default componentEntry<Props>({
  id: "agent-pane.rules-notice",
  title: "Agent rules above the composer",
  area: "Agent pane",
  covers: ["agent-session/acpmux/RulesNotice.tsx#RulesNotice"],
  load: () => import("./RulesNotice").then((module) => module.RulesNotice),
  styles: () => import("./styles.css"),
  widths: { narrow: 360, normal: 640, wide: 900 },
  height: 260,
  anchors: [{ selector: ".acpmux-rules-head" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Show All grows the card below its title row." },
    longFrameFailMs: { value: 33, reason: "Expanding the list is a local state change." },
  },
  variants: {
    collapsed: {
      note: "One line: the title, how many rules, and the newest rule; Show All opens the list.",
      props: { rules },
    },
    "show-all": {
      note: "Every current rule with its key, who posted it (a person or an agent session) and how many agents acked it.",
      props: { rules },
      play: showAll,
    },
    single: {
      note: "A single rule by an agent session.",
      props: { rules: [rules[1]!] },
    },
  },
});
