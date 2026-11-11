// l10n-allow-file: gallery fixtures (sample notices, program and machine names), not shipped UI.
// How a received message names a sender acpmux could not bind to a session, now that the daemon
// names the program behind a send (acpmux sender_program.rs) and verifies first-party senders by
// it (`~/.acpmux/senders.json`). Leo, 2026-11-11, on our own outbox relay's notice drawn as
// "Unverified sender" with an "Xcode" chip: "what's up with this?" then "surely this could be
// more... idk. generally the "unverified sender" things should be more verified". Each variant is
// one received row as the transcript draws it; the unverified mark's tooltip (and accessible name)
// says why: what it claimed, then what acpmux identified. Synthetic data.
import { componentEntry } from "../../../gallery/format";
import { SESSION_ID } from "../../../gallery/fixtures/acpmux";

type State = "before" | "identified" | "verified" | "claimed" | "app";

const TEXT = "#40611 conflicts with feat-cmux-next\n\nRebase it on the new base, then push again.";

/// The `user_message` provenance each variant's row was recorded with.
const PROVENANCE: Record<State, Record<string, unknown>> = {
  // What Leo saw: our relay's unnamed send, nothing identified (an acpmux before this change).
  before: { kind: "unverified", to: SESSION_ID, transport: "unix", verified: false, claimed: { cliHost: "cosmic-gray" } },
  // The same send now: acpmux names the script it found running it.
  identified: {
    kind: "unverified",
    to: SESSION_ID,
    transport: "unix",
    verified: false,
    claimed: { cliHost: "cosmic-gray" },
    identified: { program: "outbox_relay.py" },
  },
  // The relay's program is registered as `outbox-relay`: a first-party sender by its name.
  verified: {
    kind: "agent_message",
    from: "fromAgent",
    fromName: "outbox-relay",
    to: SESSION_ID,
    transport: "unix",
    verified: true,
    verifiedBy: "program",
    program: "outbox_relay.py",
    claimed: { cliHost: "cosmic-gray" },
  },
  // `--from glaeda-gh` from a program that is not glaeda-gh's: its name is only its claim.
  claimed: {
    kind: "agent_message",
    from: "fromAgent",
    fromName: "glaeda-gh",
    to: SESSION_ID,
    transport: "unix",
    verified: false,
    claimed: { cliHost: "cosmic-gray" },
    identified: { program: "stranger.py" },
  },
  // A send acpmux found coming from Xcode's own code (not a tool Xcode ships).
  app: {
    kind: "unverified",
    to: SESSION_ID,
    transport: "unix",
    verified: false,
    claimed: { cliHost: "studio-mac" },
    identified: { app: "Xcode.app" },
  },
};

export default componentEntry<{ state: State }>({
  id: "agent-pane.verified-sender",
  title: "A sender acpmux verified, identified or could not name",
  area: "Agent pane",
  pane: true,
  height: 200,
  widths: { narrow: 420, normal: 760 },
  keywords: ["unverified sender", "verified sender", "outbox relay", "program"],
  covers: [
    "agent-session/acpmux/conversation/unverifiedSender.ts",
    "agent-session/acpmux/conversation/UnverifiedMark.tsx",
    "agent-session/acpmux/conversation/IncomingMessageCard.tsx#SenderChip",
  ],
  load: async () => {
    const { MessageRowLookContext } = await import("./messageRowLook");
    const { IncomingMessageLine } = await import("./IncomingMessageCard");
    const { incomingPrompt } = await import("./incomingMessage");
    return function GalleryVerifiedSender({ state }: { state: State }) {
      const incoming = incomingPrompt(TEXT, { client: "acpmux-cli#1@cosmic-gray", _meta: { provenance: PROVENANCE[state] } });
      return (
        <MessageRowLookContext.Provider value="card">
          <main
            className="acpmux-shell message-row-kinds-gallery"
            style={{ padding: "16px", flexDirection: "column", gap: "0" }}
          >
            {incoming?.kind === "message" && (
              <section className="acpmux-row">
                <div className="cv-incoming">
                  <IncomingMessageLine id={`verified-sender-${state}`} message={incoming.message} onOpen={() => undefined} />
                </div>
              </section>
            )}
          </main>
        </MessageRowLookContext.Provider>
      );
    };
  },
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("./AgentMessageRowKinds.gallery.css")]),
  variants: {
    before: {
      props: { state: "before" },
      note: "Before (Leo's screenshot): our outbox relay's unnamed send reads 'Unverified sender', and its mark says only 'Sender not verified'.",
    },
    identified: {
      props: { state: "identified" },
      note: "The pick: the same unnamed send is named by what acpmux found running it, 'outbox_relay.py, via acpmux CLI', with the same small muted mark; its tooltip reads 'Sent by outbox_relay.py via acpmux CLI on cosmic-gray'.",
    },
    verified: {
      props: { state: "verified" },
      note: "The relay's program is registered for outbox-relay in ~/.acpmux/senders.json: acpmux verifies it by its program, so the row names outbox-relay with no unverified mark.",
    },
    claimed: {
      props: { state: "claimed" },
      note: "A send that says --from glaeda-gh from a program that is not glaeda-gh's: the name stays, marked; the tooltip reads 'Claimed to be glaeda-gh, not proven' then 'Sent by stranger.py via acpmux CLI on cosmic-gray'.",
    },
    app: {
      props: { state: "app" },
      note: "Only when acpmux found the app's own code (Contents/MacOS, not a tool it ships such as Xcode's python) does the name say the app: 'Xcode, via acpmux CLI'.",
    },
  },
});
