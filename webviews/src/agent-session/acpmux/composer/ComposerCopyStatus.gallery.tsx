// l10n-allow-file: gallery fixture notes, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { ComposerCopyStatusLine } from "./ComposerCopyStatus";

type Props = Parameters<typeof ComposerCopyStatusLine>[0];
const total = 177 * 1024 * 1024;
const cancel = () => undefined;

export default componentEntry<Props>({
  id: "agent-pane.composer-copy-status",
  title: "Large composer clipboard copy",
  area: "Agent pane",
  height: 100,
  pane: true,
  covers: ["agent-session/acpmux/composer/ComposerCopyStatus.tsx#ComposerCopyStatusLine"],
  load: () => import("./ComposerCopyStatus").then((module) => module.ComposerCopyStatusLine),
  variants: {
    copying: {
      note: "A 177 MiB selection copies through bounded staging; progress and Cancel stay in one quiet line.",
      props: { status: { phase: "copying", written: total / 4, total, cancel } },
    },
    finishing: {
      note: "The bytes are staged and the clipboard is being published; Cancel remains available until completion.",
      props: { status: { phase: "copying", written: total, total, cancel } },
    },
    failed: {
      note: "A failed copy keeps one actionable line with Retry, without exposing transport details.",
      props: { status: { phase: "failed", retry: () => undefined } },
    },
    incomplete: {
      note: "Valid attachments were copied; an unavailable item is reported and Cut keeps the draft.",
      props: { status: { phase: "failed", partial: true, retry: () => undefined } },
    },
  },
});
