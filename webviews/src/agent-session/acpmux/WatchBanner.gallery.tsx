// l10n-allow-file: gallery fixtures (sample notes), not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { WatchBanner } from "./WatchBanner";

type Props = Parameters<typeof WatchBanner>[0];

const onTakeOver = () => undefined;
const onContinue = () => undefined;

export default componentEntry<Props>({
  id: "agent-pane.watch-banner",
  title: "Watching another app's session",
  area: "Agent pane",
  height: 160,
  covers: ["agent-session/acpmux/WatchBanner.tsx#WatchBanner"],
  pane: true,
  load: () => import("./WatchBanner").then((module) => module.WatchBanner),
  variants: {
    claude: {
      props: { family: "claude", onTakeOver, onContinue },
      note: "Claude Code: Take Over, or Continue in New Chat (a fork)",
    },
    codex: { props: { family: "codex", onTakeOver, onContinue }, note: "Codex: Take Over, or New Chat Here" },
    "take-over-only": { props: { family: "claude", onTakeOver } },
  },
});
