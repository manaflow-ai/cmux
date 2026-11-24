// l10n-allow-file: gallery-only design study (sample paths, branch and checks), not shipped UI.
// Turn end to an open pull request with its checks, three placements (RFD 0167 amendment 1, row 8).
import { componentEntry } from "../../../gallery/format";
import { activity, tool } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../model";
import {
  TurnToPullRequestDesigns,
  type TurnToPullRequestDesign,
  type TurnToPullRequestState,
} from "./TurnToPullRequestDesigns";

const EDITS = [
  {
    path: "/Users/you/atlas-web/src/api/client.ts",
    oldText: "export async function get(url: string) {\n  return fetch(url);\n}\n",
    newText:
      "export async function get(url: string) {\n  return withRetry(() => fetch(url), { tries: 3, delayMs: 250 });\n}\n",
  },
  {
    path: "/Users/you/atlas-web/src/api/retry.test.ts",
    oldText: "",
    newText: "test('retries three times', async () => {\n  expect(await tries()).toBe(3);\n});\n",
  },
];

const ROW = {
  ...activity(
    [
      tool("Edit src/api/client.ts", "edit", "completed", { diffs: [EDITS[0]] }),
      tool("Write src/api/retry.test.ts", "edit", "completed", { diffs: [EDITS[1]] }),
    ],
    2,
  ),
  ended: true,
} as AcpmuxRow;

type Props = { design: TurnToPullRequestDesign; state?: TurnToPullRequestState };

function Gallery({ design, state }: Props) {
  return <TurnToPullRequestDesigns design={design} state={state} row={ROW} />;
}

const DESIGNS: Record<TurnToPullRequestDesign, { title: string; clicks: string }> = {
  "turn-row": {
    title: "Open pull request on the turn's action row",
    clicks: "1 click to the PR with a checks ring and summary; 2 to each check (the chip's popover).",
  },
  "changes-foot": {
    title: "The edited-files card's foot: branch, Open pull request, then every check",
    clicks: "1 click to the PR and every check, failing first. Picked.",
  },
  "composer-chip": {
    title: "A branch chip in the composer's quiet row: branch, then PR, then checks",
    clicks: "3 clicks: the chip's menu, Open pull request, the PR chip's checks.",
  },
};
const STATES: Record<TurnToPullRequestState, string> = {
  ended: "the turn just ended",
  opening: "pushing and opening the PR",
  running: "PR open, checks running",
  green: "checks green",
  red: "checks red",
};

const variants: Record<string, { props: Props; note: string }> = {};
for (const design of Object.keys(DESIGNS) as TurnToPullRequestDesign[]) {
  variants[design] = { props: { design }, note: `${DESIGNS[design].title}. ${DESIGNS[design].clicks} Every state.` };
  for (const state of Object.keys(STATES) as TurnToPullRequestState[])
    variants[`${design}-${state}`] = { props: { design, state }, note: `${DESIGNS[design].title}: ${STATES[state]}.` };
}

export default componentEntry<Props>({
  id: "agent-pane.turn-to-pull-request",
  title: "Turn end to an open pull request with checks (designs)",
  area: "Agent pane",
  experimental: true,
  pane: true,
  covers: ["agent-session/acpmux/turnToPullRequest/TurnToPullRequestDesigns.tsx#TurnToPullRequestDesigns"],
  load: async () => Gallery,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../composerLocation.css"),
      import("../header/header.css"),
      import("./TurnToPullRequestDesigns.gallery.css"),
    ]),
  widths: { normal: 560 },
  height: 620,
  variants,
});
