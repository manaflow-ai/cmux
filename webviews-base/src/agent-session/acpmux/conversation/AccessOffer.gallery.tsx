// l10n-allow-file: gallery fixtures (sample router errors), not shipped UI.
// A model the person cannot use is never a dead end (Leo 2026-10-26: "if user picks a model they
// don't have api key, we offer them to add credits or add their own api key"; accessOffer.ts). This is
// the Add Credits half: on a turn the cmux model router refused (no plan and no credits, or too few
// credits), Add Credits… leads. The model picker keeps a signed-out local harness's own Log In alone:
// credits pay only for the cmux model router and sign no local harness in.
import { componentEntry } from "../../../gallery/format";

type Props = {
  /// The pane offers Add Credits… (off: a pane that cannot run the app's actions).
  access: boolean;
  /// The failed turn's error.
  error: string;
};

const noop = () => undefined;
const access = { addCredits: noop };

const row = (error: string) => ({
  id: "summary-2",
  version: 1,
  at: Date.UTC(2026, 9, 26, 3, 12),
  kind: "turnSummary" as const,
  seq: 2,
  status: "failed" as const,
  durationMs: 1_800,
  error,
  prompt: "Add retries to the fetch helper",
  retryRowId: "user-1",
});

/// The router's refusal as Claude Code reports it (backend inference/messages.ts keeps only the text).
const noCredits =
  'API Error: 402 {"type":"error","error":{"type":"billing_error","message":"AI models need cmux credits, your own API key, or a paid plan"}}';
const lowCredits =
  'API Error: 402 {"type":"error","error":{"type":"billing_error","message":"Not enough cmux credits for this call. Add credits or use your own API key."}}';

export default componentEntry<Props>({
  id: "agent-pane.access-offer",
  title: "Add credits",
  area: "Agent pane",
  pane: true,
  height: 220,
  widths: { narrow: 360, normal: 520, wide: 720 },
  covers: ["agent-session/acpmux/accessOffer.ts", "agent-session/acpmux/conversation/TurnRows.tsx#TurnFooter"],
  keywords: ["credits", "paywall", "upgrade", "model router", "402"],
  load: async () => {
    const [{ TurnFooter }, { TurnActionsContext }] = await Promise.all([import("./TurnRows"), import("./turnActions")]);
    return function GalleryAccessOffer({ access: offered, error }: Props) {
      const actions = {
        retry: noop,
        switchModel: noop,
        route: { name: "cmux model router", harness: "cmux" },
        ...(offered ? { access } : {}),
      };
      return (
        <div style={{ padding: "16px 16px 0" }}>
          <TurnActionsContext.Provider value={actions}>
            <TurnFooter row={row(error) as never} />
          </TurnActionsContext.Provider>
        </div>
      );
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: {
    "turn-no-credits": {
      note: "The router refused the turn (no plan, no credits): Add Credits… leads, Retry and Switch model after.",
      props: { access: true, error: noCredits },
    },
    "turn-low-credits": {
      note: "Credits below this call's price, still no paid plan: the same offer.",
      props: { access: true, error: lowCredits },
    },
    "turn-no-offer": {
      note: "A pane that cannot run the app's actions: the cause line names the way out, Retry and Switch model.",
      props: { access: false, error: noCredits },
    },
  },
});
