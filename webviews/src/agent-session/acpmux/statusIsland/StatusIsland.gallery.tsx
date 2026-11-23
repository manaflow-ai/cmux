// l10n-allow-file: gallery fixtures (sample chats, asks and errors), not shipped UI.
// Agent status island (StatusIsland.tsx, experiment `agent-status-island`, off by default): the
// floating pill at the top of the chat, compact with nothing running, compact with three agents
// running, and morphed into its card for a pending approval (Allow and Deny, through Needs you's
// answer) and for an agent that stopped on an error. Every variant builds the island's state from
// the real derivations (needsYouItems, islandState) over sample sessions and asks. Press the pill
// or the card's chevron to watch the morph; light and dark come from the gallery's appearance control.
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxPermission } from "../model";
import { needsYouItems, type WatchedAsk } from "../needsYou/model";
import type { AgentQuestion } from "../question/model";
import type { AcpmuxSessionEntry } from "../sessionList";
import { islandState } from "./model";
import type { StatusIslandActions } from "./StatusIsland";

const NOW = Date.now();
const ago = (minutes: number) => NOW - minutes * 60_000;
const session = (fields: Partial<AcpmuxSessionEntry> & { sessionId: string }): AcpmuxSessionEntry => ({
  harness: "claude",
  hostKind: "local",
  host: "This Mac",
  ...fields,
  displayTitle: fields.title,
});

const running: AcpmuxSessionEntry[] = [
  session({
    sessionId: "s-retry",
    title: "Add retry backoff to the uploader",
    indicator: "working",
    updatedAt: ago(1),
  }),
  session({ sessionId: "s-bench", title: "Bench the transcript at 10k rows", indicator: "working", updatedAt: ago(2) }),
  session({
    sessionId: "s-l10n",
    title: "Localize the changes view",
    harness: "codex",
    indicator: "working",
    updatedAt: ago(3),
  }),
];
const asking = session({
  sessionId: "s-tabs",
  title: "Review the terminal tab strip",
  indicator: "input",
  pendingPermissions: 1,
  updatedAt: ago(1),
});
const failed = session({
  sessionId: "s-pairing",
  title: "Port the pairing sheet",
  harness: "codex",
  indicator: "failed",
  laneError: "The agent exited: out of context",
  updatedAt: ago(2),
});
const options: AcpmuxPermission["options"] = [
  { id: "allow_once", name: "Allow", kind: "allow_once", allow: true },
  { id: "allow_always", name: "Always allow", kind: "allow_always", allow: true },
  { id: "reject_once", name: "Deny", kind: "reject_once", allow: false },
];
const ask: WatchedAsk = {
  sessionId: "s-tabs",
  at: ago(1),
  permission: {
    permissionId: "ask-lint",
    title: "Run the linter",
    kind: "execute",
    command: "bun run lint:ci",
    pending: true,
    options,
  },
};
const choosing = session({
  sessionId: "s-auth",
  title: "Settings page sign-in",
  harness: "codex",
  indicator: "input",
  pendingPermissions: 1,
  updatedAt: ago(1),
});
const longChoices: AgentQuestion = {
  id: "ask-auth",
  source: { harness: "codex", session: "s-auth", permission: "ask-auth", answerOption: "allow_once" },
  items: [
    {
      id: "q0",
      header: "Auth",
      prompt: "Which sign-in should the settings page offer first?",
      options: [
        { id: "oauth", label: "OAuth through the existing identity provider, with the current scopes" },
        { id: "passkeys", label: "Passkeys only, with a recovery code printed once at setup" },
        { id: "both", label: "Both: passkeys first, OAuth behind a Use another way link" },
        { id: "later", label: "Neither yet: keep the email link until the security review lands" },
      ],
      multiSelect: false,
      allowsOther: false,
    },
  ],
  state: { kind: "pending" },
};
const choiceAsk: WatchedAsk = {
  sessionId: "s-auth",
  at: ago(1),
  permission: { permissionId: "ask-auth", pending: true, options, question: longChoices },
};

const stateOf = (sessions: AcpmuxSessionEntry[], asks: WatchedAsk[] = []) =>
  islandState({ sessions, items: needsYouItems({ sessions, asks }) });

const actions: StatusIslandActions = {
  answer: async () => undefined,
  goTo: () => undefined,
  openSession: () => undefined,
};

type Props = { sessions: AcpmuxSessionEntry[]; asks?: WatchedAsk[] };

export default componentEntry<Props>({
  id: "agent-pane.status-island",
  title: "Agent status island",
  area: "Agent pane",
  experimental: true,
  height: 360,
  keywords: ["island", "pill", "status", "approval", "needs you", "running", "morph"],
  covers: ["agent-session/acpmux/statusIsland/StatusIsland.tsx"],
  load: () =>
    import("./StatusIsland").then(
      ({ StatusIsland }) =>
        function Stage({ sessions, asks }: Props) {
          return (
            <div className="acpmux-shell" style={{ position: "relative", height: "100vh" }}>
              <StatusIsland state={stateOf(sessions, asks)} actions={actions} />
            </div>
          );
        },
    ),
  styles: async () => {
    await import("../../../ui/ui.css");
    await import("../styles.css");
  },
  variants: {
    "compact-idle": {
      note: "No agent running and nothing waiting: a muted dot and No agents running; the pill does not open.",
      props: { sessions: [] },
    },
    "compact-running": {
      note: "Three agents running: the accent dot and Running · 3. Nothing to show, so it stays a pill.",
      props: { sessions: running },
    },
    "expanded-approval": {
      note: "An agent asks to run a command: the pill morphs into its card with Allow and Deny (Needs you's answer). The chevron folds it back into the pill.",
      props: { sessions: [...running, asking], asks: [ask] },
    },
    "expanded-long-choices": {
      note: "A question with four long choices: one per row across the card, each label wrapping, every choice visible and clickable.",
      props: { sessions: [...running, choosing], asks: [choiceAsk] },
    },
    "expanded-error": {
      note: "An agent stopped on an error: its card says so, with the error and Open Chat.",
      props: { sessions: [running[0]!, running[1]!, failed] },
    },
  },
});
