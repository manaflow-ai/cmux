// l10n-allow-file: gallery fixtures, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { AcpmuxSessionOffer } from "../model";
import { OfferChip } from "./OfferChip";

type Props = { initial: AcpmuxSessionOffer; fails?: boolean };

const base: AcpmuxSessionOffer = {
  offerId: "offer-1",
  title: "Fix the flaky upload test",
  prompt: "The upload test fails one run in five: find why and fix it.",
  cwd: "/Users/leo/Projects/demo-app",
  worktree: true,
  harness: "codex",
};

/// The chip with acpmux stood in: Start and Dismiss record the answer after a beat, as its
/// decision record would; `fails` refuses Start as a lost offer would.
function GalleryOfferChip({ initial, fails = false }: Props) {
  const [offer, setOffer] = useState(initial);
  const later = (next: Partial<AcpmuxSessionOffer>) =>
    new Promise<void>((resolve, reject) =>
      setTimeout(() => {
        if (fails) return reject(new Error("no open offer has that offerId"));
        setOffer((current) => ({ ...current, ...next }));
        resolve();
      }, 300),
    );
  return (
    <div className="acpmux-shell" data-offer-fixture>
      <OfferChip
        offer={offer}
        onStart={() => later({ outcome: "accepted", childSessionId: "child-1" })}
        onDismiss={() => later({ outcome: "dismissed" })}
        onOpen={() => undefined}
      />
    </div>
  );
}

const start: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Start" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Open" }));
};

const dismiss: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Dismiss" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-session-offer-status")?.textContent === "Dismissed");
};

const refused: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Start" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-session-offer-error"));
};

export default componentEntry<Props>({
  id: "agent-pane.session-offer",
  title: "Session offer chip",
  area: "Agent pane",
  height: 110,
  widths: { narrow: 360, normal: 520, wide: 720 },
  anchors: [{ selector: "[data-offer-fixture]" }],
  covers: ["agent-session/acpmux/offer/OfferChip.tsx#OfferChip"],
  styles: () => import("../styles.css"),
  load: async () => GalleryOfferChip,
  variants: {
    open: { props: { initial: base }, play: start },
    dismiss: { props: { initial: base }, play: dismiss },
    here: { props: { initial: { ...base, worktree: false } } },
    long: {
      props: {
        initial: {
          ...base,
          title: "Move the retry and backoff logic out of the upload client into one shared helper",
        },
      },
    },
    refused: { props: { initial: base, fails: true }, play: refused },
    started: { props: { initial: { ...base, outcome: "accepted", childSessionId: "child-1" } } },
    dismissed: { props: { initial: { ...base, outcome: "dismissed" } } },
  },
});
