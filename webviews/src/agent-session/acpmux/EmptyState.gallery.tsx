import { componentEntry } from "../../gallery/format";
import type { NewChatEntrance } from "./newChatEntrance";
import type { TourOfferActions } from "./repoTour/TourOffer";

type Props = {
  tour?: TourOfferActions;
  entrance?: NewChatEntrance;
  /** Draws the empty state in a pane with a composer under it, as the chat view lays out a new chat, so
   *  the entrance's composer part shows. The composer here is a stand-in box with a real textarea. */
  inPane?: boolean;
};

/** The empty state, alone or in a pane over a composer (the entrance variants). */
const loadEmptyState = () =>
  import("./EmptyState").then(({ EmptyState }) => {
    function Plain({ inPane, ...props }: Props) {
      if (!inPane) return <EmptyState {...props} />;
      return (
        <div
          className="acpmux-main"
          data-new-chat=""
          style={{ display: "flex", flexDirection: "column", height: "100%" }}
        >
          <EmptyState {...props} />
          <div className="acpmux-dock">
            <div className="acpmux-composer">
              <div className="acpmux-composer-box" style={{ padding: "12px 16px" }}>
                <textarea
                  aria-label="Message"
                  placeholder="Ask anything"
                  rows={2}
                  style={{
                    resize: "none",
                    border: 0,
                    outline: 0,
                    background: "transparent",
                    color: "inherit",
                    font: "inherit",
                  }}
                />
              </div>
            </div>
          </div>
        </div>
      );
    }
    return Plain;
  });

const tour: TourOfferActions = {
  onTake: () => undefined,
  onDismiss: () => undefined,
};

export default componentEntry<Props>({
  id: "agent-pane.empty-state",
  title: "Plain new chat",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/EmptyState.tsx#EmptyState",
    "agent-session/acpmux/repoTour/TourOffer.tsx#TourOffer",
    "agent-session/acpmux/newChatEntrance.ts#playNewChatEntrance",
  ],
  load: loadEmptyState,
  styles: () => import("./styles.css"),
  widths: { narrow: 360, normal: 640, wide: 900 },
  height: 420,
  checks: {
    layoutShiftMax: {
      value: 0,
      reason: "The plain new chat draws nothing that moves.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "An empty chat draws on its first frame.",
    },
  },
  keywords: ["entrance", "animation", "startup", "motion", "spring"],
  options: [
    {
      id: "entrance",
      label: "Entrance",
      kind: "choice",
      choices: [
        { value: "rise", label: "Rise (default)" },
        { value: "bloom", label: "Bloom" },
        { value: "focus", label: "Focus" },
        { value: "off", label: "Off" },
      ],
      defaultValue: "rise",
    },
  ],
  variants: {
    "entrance-rise": {
      note: 'The default (Leo 2026-11-22: "claude code has such a nice animation on startup"): the tour offer and the composer rise into place on one spring (response 0.42 s, damping 0.82, as iOS), at rest by 440 ms, once per chat. The composer types at frame 0.',
      props: { tour, entrance: "rise", inPane: true },
    },
    "entrance-bloom": {
      note: "Bloom: the tour offer grows from 92% at its center, then the composer rises after it.",
      props: { tour, entrance: "bloom", inPane: true },
    },
    "entrance-focus": {
      note: "Focus: the tour offer comes from out of focus to sharp; the composer only rises.",
      props: { tour, entrance: "focus", inPane: true },
    },
    plain: {
      note: "A new chat with no turns, on every path (new, connecting, reconnecting, a host error): no question, no project picker, no lists. The builder screen is an opt-in look (examples/looks/codex/send-parity).",
      props: {},
    },
    "tour-offer": {
      note: "A folder no chat has used: Take a tour of this repo, centered; a dim × (Not now) sits beside it.",
      props: { tour },
    },
    "tour-offer-hover": {
      note: "Hovering the offer fills it; the × closes it for this folder.",
      props: { tour },
      play: async (ctx) => {
        await ctx.hover({ selector: ".acpmux-tour-offer-take" });
      },
    },
  },
});
