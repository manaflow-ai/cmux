// l10n-allow-file: gallery fixtures, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { AcpmuxOfferResult, AcpmuxSessionOffer } from "../model";
import { ReceivedResult, SuggestedTasks } from "./SuggestedTasks";

type Props = { initial: AcpmuxSessionOffer[]; received?: AcpmuxOfferResult[]; fails?: boolean };

const task = (n: number, title: string, prompt: string, groupId?: string): AcpmuxSessionOffer => ({
  offerId: `offer-${n}`,
  title,
  prompt,
  cwd: "/Users/you/Projects/storefront",
  worktree: false,
  ...(groupId ? { groupId } : {}),
});

const three = [
  task(
    1,
    "Cart: add width and height to thumbnails",
    "In src/components/CartLineItem.tsx the thumbnail has no width or height, so the cart shifts the same way the product grid did.",
    "g-1",
  ),
  task(
    2,
    "Images: lazy-load below the fold",
    'Product images in ProductCard and Gallery all load eagerly. Add loading="lazy" to the ones below the fold.',
    "g-1",
  ),
  task(
    3,
    "Checkout: label the form fields",
    "In src/checkout/CheckoutForm.tsx six inputs rely on placeholders. Give each a visible label.",
    "g-1",
  ),
];

const single = [
  task(
    9,
    "Add width and height to cart thumbnail images",
    "CartLineItem and MiniCart render product images without dimensions, which causes the same shift there.",
  ),
];

const started = (status: string, activity?: string) => (offer: AcpmuxSessionOffer, index: number) => ({
  ...offer,
  outcome: "accepted" as const,
  childSessionId: `child-${index + 1}`,
  childStatus: status,
  ...(activity ? { activity } : {}),
});

const live = [
  started("running", "Reading CartLineItem.tsx")(three[0]!, 0),
  started("waiting")(three[1]!, 1),
  started("idle")(three[2]!, 2),
];

/// The card with acpmux stood in: Start, Do it here and dismiss record the answer after a beat, as
/// the decision record would; `fails` refuses as a lost offer would.
function GallerySuggestedTasks({ initial, received = [], fails = false }: Props) {
  const [offers, setOffers] = useState(initial);
  const answer = (offerId: string, next: Partial<AcpmuxSessionOffer>) =>
    new Promise<void>((resolve, reject) =>
      setTimeout(() => {
        if (fails) return reject(new Error("no open offer has that offerId"));
        setOffers((current) => current.map((offer) => (offer.offerId === offerId ? { ...offer, ...next } : offer)));
        resolve();
      }, 300),
    );
  return (
    // The shell carries the pane's tokens; the fixture inside it is a plain column, as the thread is.
    <div className="acpmux-shell">
      <div data-tasks-fixture style={{ flex: 1, minWidth: 0, padding: 12 }}>
        {offers.length > 0 && (
          <SuggestedTasks
            offers={offers}
            actions={{
              start: (offerId) =>
                answer(offerId, {
                  outcome: "accepted",
                  childSessionId: `child-${offerId}`,
                  childStatus: "running",
                  activity: "Reading CartLineItem.tsx",
                }),
              here: (offerId) => answer(offerId, { outcome: "here" }),
              dismiss: (offerId) => answer(offerId, { outcome: "dismissed" }),
              open: () => undefined,
            }}
          />
        )}
        {received.map((result) => (
          <ReceivedResult key={result.offerId} result={result} onOpen={() => undefined} />
        ))}
      </div>
    </div>
  );
}

const startAll: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Start all" });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-task-started").length === 3);
};

const startOne: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Start" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-task-started"));
};

const refused: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Start" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-task-error"));
};

export default componentEntry<Props>({
  id: "agent-pane.suggested-tasks",
  title: "Suggested tasks",
  area: "Agent pane",
  pane: true,
  height: 340,
  widths: { narrow: 360, normal: 560, wide: 760 },
  anchors: [{ selector: "[data-tasks-fixture]" }],
  covers: [
    "agent-session/acpmux/offer/SuggestedTasks.tsx#SuggestedTasks",
    "agent-session/acpmux/offer/SuggestedTasks.tsx#ReceivedResult",
    "agent-session/acpmux/conversation/icons.tsx#Bot",
  ],
  styles: () => import("../styles.css"),
  load: async () => GallerySuggestedTasks,
  variants: {
    open: {
      note: "Three tasks the agent suggested together, untouched: each with Options, Do it here and Start.",
      props: { initial: three },
      height: 330,
    },
    "start-all": {
      note: "Play: Start all starts each task as its own chat, in order; the card becomes its started rows.",
      props: { initial: three },
      height: 330,
      play: startAll,
    },
    single: {
      note: "One task offered mid-turn, untouched: Options, Do it here, Start and dismiss.",
      props: { initial: single },
      height: 130,
    },
    "single-started": {
      note: "Play: Start turns the lone task into one quiet row with what its chat does now.",
      props: { initial: single },
      height: 130,
      play: startOne,
    },
    started: {
      note: "Every task started: the card is its count and a row per chat (running, needs input, done).",
      props: { initial: live },
      height: 150,
    },
    received: {
      note: "The tasks' results came back to the chat as one line each, which opens that task's chat.",
      props: {
        initial: three.map(started("idle")),
        received: three.map((offer, index) => ({
          offerId: offer.offerId,
          childSessionId: `child-${index + 1}`,
          title: offer.title,
        })),
      },
      height: 240,
    },
    worktree: {
      note: "A task the agent asked to start in a new worktree says so beside Options.",
      props: { initial: single.map((offer) => ({ ...offer, worktree: true })) },
      height: 130,
    },
    refused: {
      note: "Play: a Start acpmux refused keeps the task and says why.",
      props: { initial: single, fails: true },
      height: 150,
      play: refused,
    },
  },
});
