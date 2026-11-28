// l10n-allow-file: synthetic gallery fixtures (model names), not shipped UI.
import { useState, type ReactNode } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";

type CardState = "idle" | "signingIn" | "error" | "done";

type Props = {
  /// `needed`: the row with Connect; `connected`: saved, before the host's list updates; `flow`: a
  /// live host whose one click runs, so Connect opens the inline card and walks its progress line;
  /// `card`: the inline connect card alone, in `look` and `card` state.
  state: "needed" | "connected" | "flow" | "card";
  look?: "card" | "row" | "steps";
  card?: CardState;
  family?: "claude" | "codex";
};

const MODELS = ["Claude Opus 5.5", "Claude Sonnet 5.5", "Claude Haiku 5.5"];

// Connect: the inline card opens already signing in, steps through saving, and the row says Connected.
const connect: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Connect" });
  await ctx.waitFor(() => ctx.document.querySelector("[data-connect-card] [aria-busy]") !== null);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-connect-claude-row[data-connected]") !== null);
};

const ERROR = "The Claude sign-in page closed before you signed in.";
const PROGRESS = {
  idle: { phase: null, error: null },
  signingIn: { phase: "signing_in", error: null },
  error: { phase: null, error: ERROR },
  done: { phase: null, error: null },
} as const;

export default componentEntry<Props>({
  id: "agent-pane.claude-connect-row",
  title: "Picker Claude Code Connect row",
  area: "Agent pane",
  pane: true,
  height: 560,
  widths: { narrow: 320, normal: 420, wide: 560 },
  covers: [
    "agent-session/acpmux/ClaudeConnectRow.tsx#ClaudeConnectRow",
    "agent-session/acpmux/ConnectCard.tsx#ConnectCard",
  ],
  load: async () => {
    const { ClaudeConnectRow, useClaudeConnectFlow } = await import("./ClaudeConnectRow");
    const { ClaudeConnectContext } = await import("./claudeConnect");
    const { ConnectCard } = await import("./ConnectCard");
    const Section = ({ children }: { children: ReactNode }) => (
      <div className="acpmux-shell" style={{ padding: "var(--ds-space-3)" }}>
        <div
          className="ui-glass ui-glass-floats"
          style={{ borderRadius: "var(--ds-radius-popup)", padding: "var(--ds-space-1)", maxWidth: 380 }}
        >
          {children}
          {MODELS.map((model) => (
            <div key={model} className="acpmux-mp-row flex h-[28px] items-center gap-2 px-2 text-control text-fg">
              {model}
            </div>
          ))}
        </div>
      </div>
    );
    const Flow = () => {
      const { row, card } = useClaudeConnectFlow();
      return (
        <div>
          <Section>
            {row && <ClaudeConnectRow name="Claude Code" connected={row.connected} onConnect={row.onConnect} />}
          </Section>
          {/* The composer's chips, under the picker: the card floats above them, as in the pane. */}
          <div className="acpmux-chips">{card}</div>
        </div>
      );
    };
    // A host whose one click steps starting → signing in → saving, then saves.
    const LiveHost = ({ children }: { children: ReactNode }) => {
      const [phase, setPhase] = useState<"starting" | "signing_in" | "saving" | null>(null);
      const begin = async () => {
        setPhase("starting");
        // gallery-capture: these steps run only inside the `connect` play, which waits for the saving card and then the Connected row.
        const step = (next: typeof phase, ms: number) =>
          new Promise((done) => setTimeout(() => done(setPhase(next)), ms));
        await step("signing_in", 500);
        await step("saving", 1200);
        await step(null, 600);
      };
      const host = {
        needed: true,
        begin,
        progress: { phase, error: null },
        cancel: () => setPhase(null),
        add: async () => undefined,
        addKey: async () => undefined,
      };
      return <ClaudeConnectContext.Provider value={host}>{children}</ClaudeConnectContext.Provider>;
    };
    return function GalleryClaudeConnectRow({ state, look = "card", card = "idle", family = "claude" }: Props) {
      if (state === "flow")
        return (
          <LiveHost>
            <Flow />
          </LiveHost>
        );
      if (state === "card")
        return (
          <div className="acpmux-shell" style={{ padding: "var(--ds-space-3)", maxWidth: 420 }}>
            <ConnectCard
              family={family}
              look={look}
              progress={PROGRESS[card]}
              done={card === "done"}
              onBegin={() => undefined}
              onCancel={() => undefined}
              onPaste={async () => undefined}
              onApiKey={async () => undefined}
              onDismiss={() => undefined}
            />
          </div>
        );
      return (
        <Section>
          <ClaudeConnectRow name="Claude Code" connected={state === "connected"} onConnect={() => undefined} />
        </Section>
      );
    };
  },
  styles: () => Promise.all([import("./styles.css"), import("../../ui/ui.css"), import("../../ui/popupSurface.css")]),
  variants: {
    needed: { props: { state: "needed" } },
    connected: { props: { state: "connected" } },
    flow: { props: { state: "flow" }, play: connect },
    ...cardVariants(),
  },
});

/// The inline card's three looks (`card` ships: the progress line sits under the one button, where
/// the eye already is; `row` is the compact one-line form; `steps` adds the Step n of 3 caption),
/// each idle, signing in, failed and done, and Codex's card in the shipped look. Variant names are
/// lower kebab case (gallery/format.ts), so `signingIn` names its variants `signing-in`.
function cardVariants() {
  const states: CardState[] = ["idle", "signingIn", "error", "done"];
  const out: Record<string, { props: Props }> = {};
  // Variant names are lower kebab case (gallery/format.ts VARIANT_NAME): `card-signing-in`.
  const name = (card: CardState) => card.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);
  for (const look of ["card", "row", "steps"] as const)
    for (const card of states) out[`${look}-${name(card)}`] = { props: { state: "card", look, card } };
  for (const card of states)
    out[`codex-${name(card)}`] = { props: { state: "card", look: "card", card, family: "codex" } };
  return out;
}
