// l10n-allow-file: gallery fixtures (sample prompts, paths and file text), not shipped UI.
// Transcript Work Log (Settings > Advanced > Experiments, experiments.transcriptWorkLog, off by
// default; taste build 9): a finished turn as a work log. Its steps sit in
// the closed "Worked for", a hairline card under the reply sums the files it changed (+N -N) over the
// session's branch, and a sent file's chip says "added to context". `off` is the same
// chat at the default look, to compare; `expanded` opens the Worked for in place.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { PromptContentPart } from "../model";

/// Turns the switch on as the app's push does (`cmuxAcpmuxBridge.applyExperiments`), then waits for
/// the card to draw its work-log head.
type Bridge = { cmuxAcpmuxBridge?: { applyExperiments?: (value: unknown) => void } };
const workLogOn: Play = async ({ document, waitFor }) => {
  const apply = () => (document.defaultView as unknown as Bridge).cmuxAcpmuxBridge?.applyExperiments;
  await waitFor(() => Boolean(apply()));
  apply()!({ transcriptWorkLog: true });
  await waitFor(() => document.querySelector(".acpmux-worklog-headline"));
};

const BRANCH = "ride/drv-364-reset-dimmed-rows";

type Edit = { path: string; oldText?: string; newText: string };
const EDITS: Edit[] = [
  {
    path: "src/rides/RideRow.tsx",
    oldText: "const dimmed = dimmedIds.has(ride.id);\nreturn <Row dimmed={dimmed} />;\n",
    newText: "const dimmed = isItemDimmed(ride, waitingStatusById);\nreturn <Row dimmed={dimmed} />;\n",
  },
  {
    path: "src/rides/dimming.ts",
    oldText:
      "export const dimmedIds = new Set<string>();\nexport function dim(id: string) {\n  dimmedIds.add(id);\n}\n",
    newText:
      'export function isItemDimmed(ride: Ride, waiting: Map<string, Status>) {\n  return waiting.get(ride.id) === "waiting";\n}\n',
  },
];
const NOTES: PromptContentPart = {
  kind: "file",
  name: "DRV-364.md",
  uri: "file:///Users/you/rides/notes/DRV-364.md",
  mimeType: "text/markdown",
  size: 2_140,
};
const PROMPT = "Fix the dimmed ride rows that never reset and open a PR";

/// One finished turn: a prompt with a file, reads and a search, two edits, a test run, the reply.
function workedTurn(edits: Edit[] = EDITS, branch = BRANCH) {
  return chat(
    [
      user(PROMPT, 6, {
        seq: 1,
        inlineParts: [{ kind: "text", text: PROMPT }, NOTES],
      }),
      activity(
        [
          tool("Read src/rides/RideRow.tsx", "read", "completed"),
          tool("Search dimmedIds", "search", "completed"),
          tool("Read src/rides/dimming.ts", "read", "completed"),
          ...edits.map((file) => tool(`Edit ${file.path}`, "edit", "completed", { diffs: [file] })),
          tool("bun test src/rides", "execute", "completed"),
        ],
        5.9,
      ),
      assistant(
        "Pushed and opened a draft PR. Removed `dimmedIds`: `isItemDimmed` now checks `waitingStatusById` directly.",
        5.7,
      ),
      summary(5.7, { status: "completed", durationMs: 10_000, toolCount: 4 + edits.length }),
    ],
    { title: "Reset dimmed ride rows", branch },
  );
}

const MANY: Edit[] = Array.from({ length: 6 }, (_, index) => ({
  path: `src/rides/part${index}.ts`,
  oldText: "export const a = 1;\n",
  newText: `export const a = ${index + 2};\nexport const b = ${index};\n`,
}));

const openWorked: Play = async (ctx) => {
  await workLogOn(ctx);
  const { click, waitFor, document } = ctx;
  await waitFor(() => document.querySelector(".cv-worked"));
  await click({ selector: ".cv-worked" });
  await waitFor(() => document.querySelector('.cv-worked[aria-expanded="true"]'));
};

const variants: Record<string, AgentPaneVariant> = {
  collapsed: {
    note: "Work log on: the turn's steps in the closed Worked for 10s, the reply, then the changes card (Changed 2 files +N -N over the branch); the sent file reads 'added to context'. Hairline borders, no fills.",
    height: 560,
    snapshot: workedTurn(),
    play: workLogOn,
  },
  expanded: {
    note: "Work log on, Worked for opened in place: the steps draw under it and the card keeps its place below the reply.",
    height: 760,
    snapshot: workedTurn(),
    play: openWorked,
  },
  off: {
    note: "The same chat with the switch off (the default look), to compare.",
    height: 560,
    snapshot: workedTurn(),
  },
  "many-files": {
    note: "Work log on, a turn that changed six files: the card's file rows split by 5% rules under its head.",
    height: 760,
    snapshot: workedTurn(MANY),
    play: workLogOn,
  },
  "long-branch": {
    note: "Work log on with a long branch name: it ends in an ellipsis (see the narrow width).",
    height: 560,
    snapshot: workedTurn(EDITS, "leo/experiments/transcript-work-log-with-a-very-long-branch-name-v2"),
    play: workLogOn,
  },
};

export default agentPaneEntry({
  id: "agent-pane.transcript-work-log",
  title: "Transcript work log (experiment)",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/conversation/EditedFilesCard.tsx",
    "agent-session/acpmux/conversation/InlinePromptContent.tsx#PromptFile",
  ],
  variants,
});
