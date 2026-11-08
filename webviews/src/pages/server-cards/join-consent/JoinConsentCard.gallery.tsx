// l10n-allow-file: gallery fixtures, not shipped UI.
// The join consent ask (design/server-cards.md "Join Consent"): the three layouts over the same ask,
// and the stacked pick asking for control, writing and showing why an Allow did not take.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { createStrings } from "../../shared/i18n";
import table from "../generated/strings.json";
import { askStatus } from "./fixtures";
import { JoinConsentCard, type JoinConsentLayout } from "./JoinConsentCard";
import type { JoinConsentStatus } from "./types";

type Props = { layout?: JoinConsentLayout; status?: Partial<JoinConsentStatus> };

function JoinConsentGallery({ layout, status }: Props) {
  const [strings] = useState(() => createStrings(table));
  return (
    <div className="server-card-frame join-consent-frame">
      <JoinConsentCard
        status={askStatus(status)}
        strings={strings}
        layout={layout}
        onDeny={() => undefined}
        controlStandIn
      />
    </div>
  );
}

export default componentEntry<Props>({
  id: "pages.server-cards-join-consent",
  title: "Join Consent ask card",
  area: "Server cards",
  height: 260,
  widths: { narrow: 380, normal: 380, wide: 380 },
  covers: ["pages/server-cards/join-consent/JoinConsentCard.tsx#JoinConsentCard"],
  load: async () => JoinConsentGallery,
  styles: async () => {
    await import("../../shared/pageBase.css");
    await import("../../../ui/ui.css");
    await import("../styles.css");
  },
  variants: {
    stacked: { note: "The pick: question and note on their own lines.", props: { layout: "stacked" } },
    compact: { note: "The note runs after the question; tighter padding.", props: { layout: "compact" } },
    banner: { note: "A mark at the leading edge, the words beside it.", props: { layout: "banner" } },
    control: {
      note: "Asking for control instead of the screen.",
      props: { status: { ask: { requester: "build-box", surface: "control" } } },
    },
    writing: { note: "A grant is landing: Deny and Allow are off.", props: { status: { writing: true } } },
    error: {
      note: "The last Allow did not take; the ask stays and says why.",
      props: { status: { error: "Touch ID was cancelled. Nothing was allowed." } },
    },
  },
});
