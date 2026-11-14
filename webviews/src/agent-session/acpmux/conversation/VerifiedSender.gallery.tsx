// l10n-allow-file: gallery fixtures (sample messages from the owner's own tools), not shipped UI.
// A named sender acpmux verified by this host's sender token (acpmux sender_token.rs: one of the
// owner's own tools, `acpmux send --from NAME` with `ACPMUX_SENDER_TOKEN`), beside the same name
// with no token. Leo, 2026-11-11, on the outbox relay's notice drawn as an unverified sender:
// "generally the "unverified sender" things should be more verified". The verified one draws its
// name bare, no mark (the pick); the one with no token keeps the mark, its tooltip and accessible
// name now saying what is wrong: "Claimed to be outbox-relay, not proven". The same two in the
// inbox's notice card, whose thread's sender record acpmux wrote. Synthetic data.
import { componentEntry } from "../../../gallery/format";

type Case = "token" | "claimed" | "inbox-token" | "inbox-claimed";
type Props = { case: Case };

const TEXT = "#40611 conflicts with feat-cmux-next: rebase it before the nightly cut.";
const NAMED = { kind: "agent_message", from: "fromAgent", fromName: "outbox-relay", to: "s-1", transport: "unix" };

export default componentEntry<Props>({
  id: "agent-pane.verified-sender",
  title: "A named sender verified by the host token",
  area: "Agent pane",
  pane: true,
  height: 200,
  widths: { narrow: 420, normal: 760 },
  anchors: [{ selector: "[data-verified-sender]" }],
  covers: [
    "agent-session/acpmux/conversation/UnverifiedMark.tsx",
    "agent-session/acpmux/conversation/senderIdentity.ts",
  ],
  load: async () => {
    const { IncomingMessageLine } = await import("./IncomingMessageCard");
    const { InboxNoticeCard } = await import("./InboxNoticeCard");
    const { incomingPrompt } = await import("./incomingMessage");
    const { inboxNotice } = await import("./inboxNotice");
    const line = (provenance: Record<string, unknown>) => {
      const prompt = incomingPrompt(TEXT, { _meta: { provenance } });
      return prompt?.kind === "message" ? prompt.message : undefined;
    };
    const lines = {
      token: line({ ...NAMED, verified: true, verifiedBy: "host-token" }),
      claimed: line(NAMED),
    };
    const notice = (sender: Record<string, unknown>) =>
      inboxNotice("[inbox] New messages from other agents in 1 thread.", {
        threads: [
          {
            threadId: "from:outbox-relay",
            label: "outbox-relay",
            from: ["outbox-relay"],
            new: 1,
            preview: TEXT,
            promptIds: ["p-4061"],
            sender,
            messages: [{ promptId: "p-4061", from: "outbox-relay", text: TEXT }],
          },
        ],
      })!;
    const notices = {
      "inbox-token": notice({ label: "outbox-relay", verification: "verified", verifiedBy: "host-token" }),
      "inbox-claimed": notice({ label: "outbox-relay", labelDeclared: true, verification: "declared" }),
    };
    return function GalleryVerifiedSender({ case: shown }: Props) {
      const message = shown === "token" || shown === "claimed" ? lines[shown] : undefined;
      return (
        <main
          className="acpmux-shell"
          data-verified-sender
          style={{ padding: "16px", flexDirection: "column", gap: "0" }}
        >
          <section className="acpmux-row">
            <div className="cv-incoming">
              {message ? (
                <IncomingMessageLine id={`verified-${shown}`} message={message} onOpen={() => undefined} />
              ) : (
                <InboxNoticeCard
                  rowId={`verified-${shown}`}
                  notice={notices[shown as "inbox-token" | "inbox-claimed"]}
                  onOpen={() => undefined}
                />
              )}
            </div>
          </section>
        </main>
      );
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: {
    token: {
      note: "The pick: a named sender whose send carried the host's sender token: its name bare, no mark, as a session acpmux proved.",
      props: { case: "token" },
    },
    claimed: {
      note: "The same name with no token: the mark stays; its tooltip and accessible name say 'Claimed to be outbox-relay, not proven' instead of 'Sender not verified'.",
      props: { case: "claimed" },
    },
    "inbox-token": {
      note: "The inbox's notice card for the token-verified sender: its thread's sender record says verified by the host token, so no mark.",
      props: { case: "inbox-token" },
    },
    "inbox-claimed": {
      note: "The inbox's notice card for the same name with no token: the mark, with the claim in its tooltip.",
      props: { case: "inbox-claimed" },
    },
  },
});
