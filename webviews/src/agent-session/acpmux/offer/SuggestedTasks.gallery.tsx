// l10n-allow-file: gallery fixtures, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { AcpmuxOfferResult, AcpmuxSessionOffer } from "../model";
import { ReceivedResult, SuggestedTasks } from "./SuggestedTasks";
import { OfferDefaultsContext, type OfferDefaults } from "./offerChoice";

type Props = { initial: AcpmuxSessionOffer[]; received?: AcpmuxOfferResult[]; fails?: boolean };

/// The chat the card is in: a Claude chat on this Mac, and its agent's lists.
const defaults: OfferDefaults = {
  harness: "claude",
  models: [
    { value: "claude-opus-5-5", name: "Opus 5.5" },
    { value: "claude-sonnet-5-5", name: "Sonnet 5.5" },
    { value: "claude-haiku-5-5", name: "Haiku 5.5" },
  ],
  effort: {
    configId: "effort",
    options: [
      { value: "low", name: "Low" },
      { value: "medium", name: "Medium" },
      { value: "high", name: "High" },
      { value: "xhigh", name: "Extra high" },
    ],
  },
  modes: [
    { value: "default", name: "Ask before edits" },
    { value: "acceptEdits", name: "Accept edits" },
    { value: "plan", name: "Plan mode" },
    { value: "bypassPermissions", name: "Bypass permissions" },
  ],
};

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
  // What the last Start carried, for the play that checks the Options picks reach it.
  const [startedWith, setStartedWith] = useState<Record<string, unknown>>();
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
    <OfferDefaultsContext.Provider value={defaults}>
      <div className="acpmux-shell">
        <div
          data-tasks-fixture
          data-started-with={startedWith ? JSON.stringify(startedWith) : undefined}
          style={{ flex: 1, minWidth: 0, padding: 12 }}
        >
          {offers.length > 0 && (
            <SuggestedTasks
              offers={offers}
              actions={{
                start: async (offerId, choice, tickets) => {
                  const [modeTicket, effortTicket] = await Promise.all([tickets.mode, tickets.effort]);
                  setStartedWith({
                    ...choice,
                    ...(modeTicket ? { modeTicket } : {}),
                    ...(effortTicket ? { effortTicket } : {}),
                  });
                  return answer(offerId, {
                    outcome: "accepted",
                    childSessionId: `child-${offerId}`,
                    childStatus: "running",
                    activity: "Reading CartLineItem.tsx",
                  });
                },
                here: (offerId) => answer(offerId, { outcome: "here" }),
                dismiss: (offerId) => answer(offerId, { outcome: "dismissed" }),
                open: () => undefined,
                // The host's ticket, named for the one pick it grants.
                reserve: async (intent) => `ticket ${intent.method} ${Object.values(intent.params).join(" ")}`,
              }}
            />
          )}
          {received.map((result) => (
            <ReceivedResult key={result.offerId} result={result} onOpen={() => undefined} />
          ))}
        </div>
      </div>
    </OfferDefaultsContext.Provider>
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
    "agent-session/acpmux/offer/OfferOptions.tsx#OfferOptions",
    "agent-session/acpmux/offer/OfferOptions.tsx#OfferOptionRows",
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
      note: 'One task offered mid-turn, untouched: "New session", its title over a muted two-line prompt, dismiss, Options, Do it here and Start.',
      props: { initial: single },
      height: 130,
    },
    "options-popover": {
      note: "Options open, as Claude desktop's suggested-session card has them: Environment, the folder, Worktree, Model, Effort and Permissions at Default (the new chat's own), Dismiss at the foot.",
      props: { initial: single },
      height: 420,
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Options" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-task-options-body"));
      },
    },
    "options-model-menu": {
      note: "Options > Model open over the popover, Sonnet 5.5 hovered in the menus' neutral wash, Opus 5.5 checked: the model the agent asked for.",
      props: { initial: single.map((offer) => ({ ...offer, worktree: true, model: "claude-opus-5-5" })) },
      height: 420,
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Options" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-task-options-body"));
        await ctx.click({ role: "button", name: "Model" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-task-menu [role='menuitemradio']"));
        await ctx.hover({ role: "menuitemradio", name: "Sonnet 5.5" });
      },
    },
    "options-start": {
      note: "Play: Options > Worktree on, Model Sonnet 5.5 and Permissions Ask before edits, then Start: the task starts with those picks on this chat's agent, the permission pick under its own ticket, and effort left at Default.",
      props: { initial: single },
      height: 130,
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Options" });
        await ctx.click({ role: "switch", name: "Worktree" });
        await ctx.click({ role: "button", name: "Model" });
        await ctx.click({ role: "menuitemradio", name: "Sonnet 5.5" });
        await ctx.click({ role: "button", name: "Permissions" });
        await ctx.click({ role: "menuitemradio", name: "Ask before edits" });
        await ctx.press("Escape");
        await ctx.click({ role: "button", name: "Start" });
        await ctx.waitFor(() => {
          const started = ctx.document.querySelector<HTMLElement>("[data-started-with]")?.dataset.startedWith;
          return (
            started ===
            JSON.stringify({
              worktree: true,
              harness: "claude",
              model: "claude-sonnet-5-5",
              mode: "default",
              modeTicket: "ticket session/set_mode default",
            })
          );
        });
      },
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
