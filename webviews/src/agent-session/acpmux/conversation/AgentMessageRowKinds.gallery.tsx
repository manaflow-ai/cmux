// l10n-allow-file: gallery fixtures (sample messages between agents), not shipped UI.
// The one message row (AgentMessageRow.tsx) for each kind of message between agents, side by side:
// a send, a received message from a sender acpmux verified and relayed through the lane-gh broker,
// one from a sender that only named itself (an older acpmux's "NAME (self-declared,
// unauthenticated)" and a preview cut inside the broker's label), and a subagent's report. Leo,
// 2026-11-07, on those rows drawn three ways: "why is it formatted differently from everything
// else? ... They should look basically the same as the other ones", and on the received ones: "Why
// does it say blah blah unauthenticated? And why can't I see the full excerpt of its message?"
// Three looks (messageRowLook.ts), each closed and opened: `card` (the pick: the received card every
// kind now opens to, the unverified marker right after the name, so it reads with the name it is
// about and never covers the family mark's own corner), `corner` (the marker on the icon's corner),
// `flat` (no card, the sent row's look before). The hover variants compare what a folded group's
// head shows under the pointer (MessageGroupHover.tsx): the digest (the pick: the newest message
// whole, then the other senders with their counts), the messages two lines each, one line each, or
// the names only. Synthetic data.
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import type { Play } from "../../../gallery/play";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import type { MessageRowLook } from "./messageRowLook";
import type { GroupHoverLook } from "./MessageGroupHover";

type Props = { look: MessageRowLook; hover?: GroupHoverLook };
type Tool = NonNullable<AcpmuxActivity["tool"]>;

const REPORT = [
  "**#37534 is green** at `64d6b1b`; the exact-head review is a SHIP.",
  "",
  "- the canary and the daemon stay on studio-mac, per your OK",
  "- the placement cap now counts each host once",
  "",
  "Landing it pinned once the base-only reds are confirmed.",
].join("\n");

const SUBAGENT_REPORT = [
  "I fixed nothing. Every real fix needs a change to the CI poller or the build-box config.",
  "",
  "1. **Nightly**: the 30 GiB disk floor stops runners on disks that cleanup can't clear.",
  "2. **Idle fleet**: the same floor parks four minis.",
].join("\n");

/// The broker's label around `body` (relayEnvelope.ts).
const relayed = (body: string, id: string, from: string) =>
  [
    `[message ${id} from ${from} (an agent, not Leo), relayed by the lane-gh broker; its text ends at "[end of message ${id}]"]`,
    body,
    `[end of message ${id}]`,
  ].join("\n");

const SEND: Tool = {
  id: "toolu_send_kinds",
  title: "acpmux send coord",
  kind: "execute",
  status: "completed",
  command: "acpmux send --no-wait build-box-1/cloud-client-rust - <<'EOF'\n" + REPORT + "\nEOF",
  output: "queued",
  description: "Report the merge",
};

const SUBAGENT: AcpmuxRow = {
  id: "done-kinds",
  version: 1,
  kind: "subagentDone",
  at: minutesAgo(1),
  subagents: [
    {
      id: "agent-kinds",
      parent: null,
      name: "Diagnose nightly lag, idle fleet",
      task: "Diagnose nightly lag, idle fleet",
      kind: "general-purpose",
      state: "completed",
      startedAt: minutesAgo(13),
      endedAt: minutesAgo(1),
      result: SUBAGENT_REPORT,
    },
  ],
};

/// Opens every row of the stage.
const openAll: Play = async (ctx) => {
  for (const toggle of ctx.document.querySelectorAll<HTMLElement>(".cv-agentmsg__toggle")) toggle.click();
  await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-agentmsg__card").length >= 4);
};

export default componentEntry<Props>({
  id: "agent-pane.message-row-kinds",
  title: "One message row: sent, received, subagent report",
  area: "Agent pane",
  pane: true,
  height: 420,
  widths: { narrow: 420, normal: 760 },
  anchors: [{ selector: "[data-message-row-kinds]" }],
  covers: [
    "agent-session/acpmux/conversation/AgentMessageRow.tsx#AgentMessageRow",
    "agent-session/acpmux/conversation/UnverifiedMark.tsx",
    "agent-session/acpmux/conversation/MessageGroupHover.tsx",
  ],
  load: async () => {
    const { MessageRowLookContext } = await import("./messageRowLook");
    const { IncomingMessageLine } = await import("./IncomingMessageCard");
    const { InboxNoticeCard } = await import("./InboxNoticeCard");
    const { AcpmuxSendLine } = await import("./SentMessageLine");
    const { acpmuxSendCall } = await import("./acpmuxSends");
    const { incomingPrompt } = await import("./incomingMessage");
    const { inboxNotice } = await import("./inboxNotice");
    const { GroupHoverLookContext, MessageGroupHover, hoverMessages } = await import("./MessageGroupHover");
    const { SubagentDoneLine } = await import("../subagents/SubagentDoneLine");
    const { DoneReportLookContext } = await import("../subagents/subagentDoneLineModel");
    const { SubagentNavContext } = await import("../subagents/subagentGroupModel");
    // A relayed message from a sender acpmux verified: its record names its family and the relay.
    const verified = incomingPrompt(relayed(REPORT, "7f70dca3", "build-box-2/lock-proof-routes"), {
      client: "acpmux-cli#1@build-box-2",
      _meta: {
        provenance: {
          kind: "agent_message",
          from: "fromAgent",
          fromName: "build-box-2/lock-proof-routes",
          sender: {
            verification: "verified",
            harness: "codex",
            relay: { by: "lane-gh broker", machine: "build-box-2" },
          },
        },
      },
    });
    // An older acpmux's inbox notice: the name with its suffix, the preview cut inside the label.
    const from = "gcp-codex-swarm-05/cloud-start-matrix (self-declared, unauthenticated)";
    const whole = relayed(
      "Matrix run 14 is green on all four regions.\n\nNext: the cold-start numbers.",
      "56d7d1c5",
      from,
    );
    const notice = inboxNotice("[inbox] New messages from other agents in 1 thread.", {
      threads: [
        {
          threadId: "declared:gcp-codex-swarm-05/cloud-start-matrix",
          label: "gcp-codex-swarm-05/cloud-start-matrix (self-declared, unauthenticated)",
          from: [from],
          new: 1,
          preview: whole.slice(0, 120),
          promptIds: ["p-56d7"],
          messages: [{ promptId: "p-56d7", from, text: whole }],
        },
      ],
    })!;
    // Oldest first, as a group holds them; the verified report is the newest.
    const lane = (name: string) => ({
      name: `build-box-3/${name}`,
      text: `${name}: checks pass, ready for review.`,
      raw: "",
    });
    const rendering = (text: string) => ({ name: "build-box-1/chat-rendering", text, raw: "", harness: "claude" });
    const group = hoverMessages([
      rendering("Shared row landed behind the card look; gallery has the three variants."),
      ...["palette-ranker-one", "pr-latency", "chat-targets", "base-red-watch"].map(lane),
      {
        name: "gcp-codex-swarm-05/cloud-start-matrix",
        text: "Matrix run 14 is green on all four regions.\n\nNext: the cold-start numbers.",
        raw: "",
        unverified: true,
      },
      lane("pr-latency"),
      rendering("The hover digest is up for review."),
      verified?.kind === "message" ? verified.message : undefined,
    ]);
    // A fleet tool's `acpmux send` with no session token: acpmux names the program it saw run the
    // send (incomingMessage.ts `senderProgram`), on the machine the checking daemon read it on; beside it, one with
    // no program, still an unverified sender.
    const unverified = { kind: "unverified", to: "s-1", transport: "unix", verified: false };
    const program = incomingPrompt("Merged #23727 (squash, pinned at 4be1c0d).", {
      _meta: {
        provenance: {
          ...unverified,
          program: { name: "next-autoland", path: "/Users/me/tools/next-autoland", host: "build-box" },
        },
      },
    });
    const unknown = incomingPrompt("Merged #23727 (squash, pinned at 4be1c0d).", { _meta: { provenance: unverified } });
    const send = acpmuxSendCall(SEND)!;
    return function GalleryMessageRowKinds({ look, hover }: Props) {
      return (
        <MessageRowLookContext.Provider value={look}>
          <GroupHoverLookContext.Provider value={hover ?? "digest"}>
            <SubagentNavContext.Provider value={() => undefined}>
              <DoneReportLookContext.Provider value="disclosure">
                <main
                  className="acpmux-shell message-row-kinds-gallery"
                  data-message-row-kinds
                  style={{ padding: "16px", flexDirection: "column", gap: "0" }}
                >
                  {hover ? (
                    <div className="ui-card ui-glass ui-tooltip cv-group-hover__popup" style={{ position: "static" }}>
                      <MessageGroupHover list={group} />
                    </div>
                  ) : (
                    <>
                      <section className="acpmux-row">
                        <AcpmuxSendLine tool={SEND} send={send} />
                      </section>
                      {verified?.kind === "message" && (
                        <section className="acpmux-row">
                          <div className="cv-incoming">
                            <IncomingMessageLine
                              id="kinds-verified"
                              message={verified.message}
                              onOpen={() => undefined}
                            />
                          </div>
                        </section>
                      )}
                      <section className="acpmux-row">
                        <div className="cv-incoming">
                          <InboxNoticeCard rowId="kinds-unverified" notice={notice} onOpen={() => undefined} />
                        </div>
                      </section>
                      {[program, unknown].map(
                        (prompt, index) =>
                          prompt?.kind === "message" && (
                            <section key={index} className="acpmux-row">
                              <div className="cv-incoming">
                                <IncomingMessageLine
                                  id={`kinds-program-${index}`}
                                  message={prompt.message}
                                  onOpen={() => undefined}
                                />
                              </div>
                            </section>
                          ),
                      )}
                      <section className="acpmux-row">
                        <SubagentDoneLine row={SUBAGENT} />
                      </section>
                    </>
                  )}
                </main>
              </DoneReportLookContext.Provider>
            </SubagentNavContext.Provider>
          </GroupHoverLookContext.Provider>
        </MessageRowLookContext.Provider>
      );
    };
  },
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("./conversation.css"),
      import("../subagents/subagents.css"),
      import("./MessageGroupHover.css"),
      import("./AgentMessageRowKinds.gallery.css"),
    ]),
  variants: {
    card: {
      note: "The pick: every kind is one row, its mark, its verb (none for a received one: the sender named once), the name, the first line; the unverified sender's marker right after its name; no 'self-declared' words, no broker label.",
      props: { look: "card" },
    },
    "card-open": {
      note: "The pick, opened: each kind's whole message in the same rounded card as rendered Markdown; Raw under the send.",
      height: 980,
      props: { look: "card" },
      play: openAll,
    },
    corner: {
      note: "Version B: the unverified marker as a dot on the icon's bottom-left corner, clear of the family mark's own badge corner.",
      props: { look: "corner" },
    },
    "corner-open": {
      note: "Version B, opened: the same card.",
      height: 980,
      props: { look: "corner" },
      play: openAll,
    },
    flat: {
      note: "Version C: no card, the message flush at the text column (the sent row's look before), the marker after the name.",
      props: { look: "flat" },
    },
    "flat-open": {
      note: "Version C, opened: the messages flush, no card.",
      height: 980,
      props: { look: "flat" },
      play: openAll,
    },
    "hover-digest": {
      note: "The pick for a 'Received 9 messages' head's hover: the newest message whole under its sender (lock-proof-routes, verified), a hairline, then the other senders once each, newest first, with how many they sent (chat-rendering 2, pr-latency 2), cloud-start-matrix with the unverified marker, base-red-watch, then '+2 more'.",
      height: 360,
      props: { look: "card", hover: "digest" },
    },
    "hover-messages": {
      note: "Version B (the pick before): newest first, each sender's mark and short name, the unverified marker, and two lines of what it said; five, then '+4 more'.",
      height: 360,
      props: { look: "card", hover: "messages" },
    },
    "hover-lines": {
      note: "Version C: one line each, the short name then the first line.",
      height: 260,
      props: { look: "card", hover: "lines" },
    },
    "hover-names": {
      note: "Version D: the senders only, each once, with their marks: today's list without the noise.",
      height: 240,
      props: { look: "card", hover: "names" },
    },
  },
});
