// l10n-allow-file: gallery fixtures (a side question and its answer), not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { SideQuestion } from "./SideQuestion";

type Props = Parameters<typeof SideQuestion>[0];

const actions = { onAdd: () => undefined, onDismiss: () => undefined };
const question = "why does the retry test flake?";

export default componentEntry<Props>({
  id: "agent-pane.side-question",
  title: "Side question",
  area: "Agent pane",
  height: 240,
  experimental: true,
  covers: ["agent-session/acpmux/aside/SideQuestion.tsx#SideQuestion"],
  pane: true,
  load: () => import("./SideQuestion").then(({ SideQuestion }) => SideQuestion),
  variants: {
    answered: {
      props: {
        ...actions,
        state: {
          question,
          answer: "The test raced the **backoff timer**: `retry()` read `Date.now()` before the fake clock advanced.",
        },
      },
    },
    asking: { props: { ...actions, state: { question } } },
    failed: { props: { ...actions, state: { question, error: "the chat is working; ask when the turn ends" } } },
  },
});
