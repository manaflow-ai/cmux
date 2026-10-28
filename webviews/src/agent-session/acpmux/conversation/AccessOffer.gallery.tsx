// l10n-allow-file: gallery fixtures (sample models and router errors), not shipped UI.
// A model the person cannot use is never a dead end (Leo 2026-10-26: "if user picks a model they
// don't have api key, we offer them to add credits or add their own api key"; accessOffer.ts). In
// the model picker a signed-out harness lists Add API Key… and Add Credits… after Log In; on a turn
// the cmux model router refused for want of credits, the card offers the same two. Compare arms
// shows the `access-offer` experiment's three placements on the card.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { ModelPickerProps } from "../modelPickerLayout";
import { accessOfferLook } from "./accessOffer.experiment";

type Props = {
  surface: "picker" | "turn";
  /// The pane offers Add API Key… and Add Credits… (off: the picker before this change).
  access: boolean;
  /// The failed turn's error (surface `turn`).
  error?: string;
};

const noop = () => undefined;
const access = { addKey: noop, addCredits: noop };

const catalog: ModelPickerProps["catalog"] = [
  {
    id: "claude",
    name: "Claude Code",
    models: [
      { id: "claude-opus-5-5", name: "Opus 5.5" },
      { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
    ],
  },
  {
    id: "codex",
    name: "Codex",
    models: [
      { id: "gpt-6.1-sol", name: "GPT-6.1-Sol" },
      { id: "gpt-6-astra", name: "GPT-6-Astra" },
    ],
  },
];

const picker: ModelPickerProps = {
  catalog,
  harness: "claude",
  model: "claude-opus-5-5",
  label: "Opus 5.5",
  efforts: [],
  recents: [],
  onLand: noop,
  onEffort: noop,
  signedOut: { codex: "codex login" },
  onLogIn: noop,
};

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

const openSignedOut: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Model" });
  await ctx.click({ selector: ".acpmux-mp-harness[data-signed-out]" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-mp-login") !== null);
};

export default componentEntry<Props>({
  id: "agent-pane.access-offer",
  title: "Add credits or your own API key",
  area: "Agent pane",
  pane: true,
  height: 420,
  widths: { narrow: 360, normal: 520, wide: 720 },
  covers: [
    "agent-session/acpmux/accessOffer.ts",
    "agent-session/acpmux/ModelPicker.tsx#ModelPicker",
    "agent-session/acpmux/conversation/TurnRows.tsx#TurnFooter",
  ],
  keywords: ["api key", "credits", "paywall", "upgrade", "signed out", "model router", "402"],
  load: async () => {
    const [{ ModelPicker }, { TurnFooter }, { TurnActionsContext }] = await Promise.all([
      import("../ModelPicker"),
      import("./TurnRows"),
      import("./turnActions"),
    ]);
    return function GalleryAccessOffer({ surface, access: offered, error }: Props) {
      if (surface === "picker")
        return (
          <div style={{ padding: 16 }}>
            <ModelPicker {...picker} {...(offered ? { access } : {})} />
          </div>
        );
      const actions = {
        retry: noop,
        switchModel: noop,
        route: { name: "cmux model router", harness: "cmux" },
        ...(offered ? { access } : {}),
      };
      return (
        <div style={{ padding: "16px 16px 0" }}>
          <TurnActionsContext.Provider value={actions}>
            <TurnFooter row={row(error ?? noCredits) as never} />
          </TurnActionsContext.Provider>
        </div>
      );
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("../modelPicker.css"), import("./conversation.css")]),
  variants: {
    "turn-no-credits": {
      note: "The router refused the turn (no plan, no credits): Add Credits… and Add API Key… lead, Retry and Switch model after.",
      height: 220,
      props: { surface: "turn", access: true, error: noCredits },
    },
    "turn-low-credits": {
      note: "Credits below this call's price: the same offer.",
      height: 220,
      props: { surface: "turn", access: true, error: lowCredits },
    },
    "turn-no-offer": {
      note: "A pane that cannot run the app's actions: the cause line names the way out, Retry and Switch model.",
      height: 220,
      props: { surface: "turn", access: false, error: noCredits },
    },
    "picker-signed-out": {
      note: "Codex is signed out: Log In, then Add API Key… and Add Credits…, in place of its models.",
      props: { surface: "picker", access: true },
      play: openSignedOut,
    },
    "picker-before": {
      note: "Before: a signed-out harness offered Log In only.",
      props: { surface: "picker", access: false },
      play: openSignedOut,
    },
  },
  experiment: {
    definition: accessOfferLook,
    script: [
      // Runs on the first variant (turn-no-credits) in every arm: the card as it first draws.
      {
        name: "card drawn",
        run: async (ctx) => {
          await ctx.waitFor(() => ctx.document.querySelector(".cv-turn-error") !== null);
        },
      },
    ],
  },
});
