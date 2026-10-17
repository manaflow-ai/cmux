// l10n-allow-file: gallery fixture for the team-facing Run launcher.
import { componentEntry } from "../../../gallery/format";
import { createFixtureRunApiClient } from "./runApi";
import { runBoardFixture } from "./fixtures";
import type { TeamRunBoardProps } from "./TeamRunBoard";

const props: TeamRunBoardProps = { client: createFixtureRunApiClient(runBoardFixture) };

export default componentEntry<TeamRunBoardProps>({
  id: "agent-pane.team-run-board",
  title: "Team Run board · fan-out launcher",
  area: "Agent pane",
  height: 880,
  widths: { narrow: 560, normal: 920, wide: 1200 },
  covers: [
    "agent-session/acpmux/run-board/TeamRunBoard.tsx#TeamRunBoard",
    "agent-session/acpmux/run-board/RunBoard.tsx#RunBoard",
  ],
  styles: () => import("./styles.css"),
  load: async () => (await import("./TeamRunBoard")).TeamRunBoard,
  variants: {
    launcher: {
      note: "The team starts a bounded cloud-vm fan-out from one immutable source, then compares durable attempt evidence on the same board.",
      props,
    },
  },
});
