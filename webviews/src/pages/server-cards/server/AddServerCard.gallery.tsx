// l10n-allow-file: gallery fixtures, not shipped UI.
// The Add Server card (design/server-cards.md): every step, and the shipped words grid beside the
// two layouts it was picked over (one row, one line).
import { componentEntry } from "../../../gallery/format";
import { idleApprover, reviewApprover, status } from "./fixtures";
import type { WordsLayout } from "./ServerViews";
import type { ServerApprover } from "./types";

type Props = { approver: ServerApprover; words?: WordsLayout };

const noop = () => {};

export default componentEntry<Props>({
  id: "pages.server-cards-add-server",
  title: "Add Server card",
  area: "Server cards",
  height: 600,
  widths: { narrow: 380, normal: 380, wide: 380 },
  covers: ["pages/server-cards/server/ServerViews.tsx"],
  keywords: ["server", "add", "approve", "pair", "code", "words"],
  load: async () => {
    const [{ AddServerCard }, { createStrings }, table] = await Promise.all([
      import("./ServerViews"),
      import("../../shared/i18n"),
      import("../generated/strings.json"),
    ]);
    const strings = createStrings(table.default);
    const actions = {
      setCode: noop,
      setName: noop,
      setTeam: noop,
      setRunChief: noop,
      cancel: noop,
      done: noop,
    };
    return function GalleryAddServer({ approver, words }: Props) {
      return (
        <div className="sv-frame">
          <AddServerCard
            status={status(null, { approver })}
            actions={actions}
            strings={strings}
            words={words}
            autoFocus={false}
            controlStandIn
          />
        </div>
      );
    };
  },
  styles: async () => {
    await import("../../shared/pageBase.css");
    await import("../../../ui/ui.css");
    await import("../styles.css");
    await import("./server.css");
  },
  variants: {
    "words-grid": { props: { approver: reviewApprover() }, note: "Shipped: the found server, its words two by two." },
    "words-row": { props: { approver: reviewApprover(), words: "row" }, note: "Variant: the four words in one row." },
    "words-line": { props: { approver: reviewApprover(), words: "line" }, note: "Variant: the words as one line." },
    "enter-code": { props: { approver: idleApprover() }, note: "The code field, empty." },
    "looking-up": {
      props: {
        approver: { ...idleApprover(), step: "lookingUp", draft: { code: "7KQ4-M2XD", name: "", runChief: false } },
      },
      note: "A complete code is being looked up.",
    },
    "code-refused": {
      props: {
        approver: {
          ...idleApprover(),
          step: "codeRefused",
          reject: "No server is waiting with that code.",
          draft: { code: "7KQ4-M2XE", name: "", runChief: false },
        },
      },
      note: "No server waits with that code.",
    },
    approving: {
      props: { approver: reviewApprover({ step: "approving", canApprove: false }) },
      note: "Adding the server.",
    },
    "approve-failed": {
      props: {
        approver: reviewApprover({ step: "approveFailed", reject: "cmux could not add the server. Try again." }),
      },
      note: "The approve was refused: Try Again.",
    },
    added: {
      props: { approver: { ...idleApprover(), step: "added", added: "build-01" } },
      note: "Added, with Done.",
    },
  },
});
