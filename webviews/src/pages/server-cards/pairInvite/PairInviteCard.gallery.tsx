// l10n-allow-file: gallery fixtures, not shipped UI.
// Pair Another Machine (design/server-cards.md): the shipped layout (side: the QR beside the code)
// through every step, and the two layouts it was picked over (stacked, line-first).
import { componentEntry } from "../../../gallery/format";
import type { PairInviteLayout } from "./PairInviteCard";
import { arrivedStatus, endedStatus, mintingStatus, showingStatus, signedOutStatus } from "./fixtures";
import type { PairInviteStatus } from "./types";

type Props = { status: PairInviteStatus; layout?: PairInviteLayout; now?: number };

/** A fixed clock, so the countdown reads the same in every capture. */
const NOW = Date.UTC(2026, 10, 6, 12, 0, 0);

export default componentEntry<Props>({
  id: "pages.server-cards-pair-invite",
  title: "Pair Another Machine card",
  area: "Server cards",
  height: 640,
  widths: { narrow: 460, normal: 460, wide: 460 },
  covers: [
    "pages/server-cards/pairInvite/PairInviteCard.tsx",
    "pages/server-cards/pairInvite/PairInviteCardHost.tsx",
    "pages/server-cards/ServerCardsPage.tsx",
    "page:cmux.server-cards",
  ],
  keywords: ["invite", "pair", "qr", "machine", "code"],
  load: async () => {
    const [{ PairInviteCard }, { createStrings }, table] = await Promise.all([
      import("./PairInviteCard"),
      import("../../shared/i18n"),
      import("../generated/strings.json"),
    ]);
    const strings = createStrings(table.default);
    return function GalleryPairInvite({ status, layout, now = NOW }: Props) {
      return (
        <div className="server-card-frame">
          <PairInviteCard
            status={status}
            strings={strings}
            now={now}
            copied={null}
            layout={layout}
            onAction={() => {}}
            controlStandIn
            onRunChief={() => {}}
          />
        </div>
      );
    };
  },
  styles: async () => {
    await import("../../shared/pageBase.css");
    await import("../../../ui/ui.css");
    await import("../styles.css");
  },
  variants: {
    side: {
      props: { status: showingStatus(NOW) },
      note: "Shipped: the code large with the QR beside it, then the two lines.",
    },
    stacked: {
      props: { status: showingStatus(NOW), layout: "stacked" },
      note: "Variant: the QR above the code, centered.",
    },
    "line-first": {
      props: { status: showingStatus(NOW), layout: "line-first" },
      note: "Variant: the `cmux pair` line first, the code and QR after it.",
    },
    "last-minute": {
      props: { status: showingStatus(NOW, 0.75) },
      note: "Under a minute left: the countdown takes the attention color.",
    },
    minting: { props: { status: mintingStatus() }, note: "Making a code." },
    "looking-up": {
      props: { status: arrivedStatus(NOW, { step: "lookingUp", candidate: undefined, canApprove: false }) },
      note: "A machine used the code; its details are being read.",
    },
    review: {
      props: { status: arrivedStatus(NOW) },
      note: "The arrived machine: its facts, four words, name and Confirm (a click only).",
    },
    "approve-failed": {
      props: {
        status: arrivedStatus(NOW, { step: "approveFailed", reject: "cmux could not pair the machine. Try again." }),
      },
      note: "The approve was refused: Try Again.",
    },
    paired: {
      props: { status: arrivedStatus(NOW, { step: "added", added: "build-box" }) },
      note: "Paired, with Done.",
    },
    voided: { props: { status: endedStatus(NOW, "voided") }, note: "A second machine used the code: New Code." },
    expired: { props: { status: endedStatus(NOW, "expired") }, note: "The code expired: New Code." },
    "signed-out": { props: { status: signedOutStatus() }, note: "Signed out." },
  },
});
