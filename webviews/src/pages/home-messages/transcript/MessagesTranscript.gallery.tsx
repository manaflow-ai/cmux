// l10n-allow-file: gallery fixtures (sample conversations), not shipped UI.
// The Messages transcript and compose bar (home-messages/transcript): three bubble looks, a chat's own
// colours, and the states the Swift transcript draws (empty, long, a failed send, offline, typing,
// attachments, a diagram, a group chat, a Chief turn's agent pills and the agent pane beside the chat). The data is plain HomeMessage values; images come from the
// Channels mock provider through the real attachment service.
import { useState } from "react";
import { GALLERY_NOW, minutesAgo } from "../../../gallery/clock";
import { componentEntry } from "../../../gallery/format";
import { AttachmentService } from "../../home-channels/attachmentService";
import { MockHomeProvider } from "../../home-channels/mockProvider";
import "../../home-channels/paneStrings";
import type { PendingSend } from "../../home-channels/store";
import type { HomeConversation, HomeMessage, HomeParticipant, HomePart } from "../../home-channels/types";
import type { BubbleLook, ChatColors } from "./colors";
import { MessagesTranscript, type MessagesTranscriptProps } from "./MessagesTranscript";
import type { ReadCursor } from "./rows";
import { createTranscriptStrings } from "./strings";
import type { ChiefPlace } from "./ChiefPlace";
import { AgentSidePane } from "../cards/pills/AgentSidePane";
import {
  agentChatContent,
  closeAgent,
  openAgent,
  selectAgent,
  type AgentPaneState,
  type AgentThread,
  type AgentThreadSource,
} from "../cards/pills/agentModel";
import { cardStrings } from "../cards/strings";

type State =
  | "conversation"
  | "empty"
  | "long"
  | "failed"
  | "offline"
  | "typing"
  | "attachments"
  | "diagram"
  | "group"
  | "agents"
  | "agentsMany";

type Fixture = Pick<MessagesTranscriptProps, "conversation" | "messages" | "connection"> &
  Partial<
    Pick<
      MessagesTranscriptProps,
      "readCursors" | "pending" | "typing" | "hasOlder" | "viewing" | "initialDraft" | "agents"
    >
  >;

type ChiefHeader = "here" | "away" | "moving" | "failed";
type Props = {
  look: BubbleLook;
  state: State;
  colors?: ChatColors;
  panels?: boolean;
  chiefHeader?: ChiefHeader;
  /** The agent pane open beside the chat on these agents (the Messages page's frame). */
  pane?: AgentPaneState;
};

/** The agents' chats the pills open (agents state): what the host's `agents` stream sends. */
const AGENT_THREADS: readonly AgentThread[] = [
  {
    peer: "a1",
    title: "Find the resize flicker",
    state: "reported",
    task: "Title: Find the resize flicker\nProfile the sidebar while the divider drags.",
    entries: [{ id: "r1", sender: "agent", text: "The list re-measures every row on each width step." }],
    startedAt: minutesAgo(26),
    endedAt: minutesAgo(21),
  },
  {
    peer: "a2",
    title: "Keep measured heights",
    state: "told",
    task: "Keep the measured row heights; re-measure only the visible rows.",
    entries: [],
    startedAt: minutesAgo(20),
  },
  {
    peer: "a3",
    title: "Release notes line",
    state: "queued",
    task: "Write the release notes line.",
    entries: [],
    startedAt: minutesAgo(2),
  },
  {
    peer: "a4",
    title: "Check the narrow window",
    state: "stopped",
    task: "Check the fix at 360 points.",
    entries: [],
    startedAt: minutesAgo(19),
    endedAt: minutesAgo(18),
  },
];

/** A Chief's picked character, as the host sends it (a data URL). */
const CHIEF_PICTURE =
  "data:image/svg+xml," +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36"><rect width="36" height="36" fill="#5E5CE6"/><circle cx="13" cy="15" r="3" fill="#fff"/><circle cx="23" cy="15" r="3" fill="#fff"/><path d="M11 23q7 6 14 0" stroke="#fff" stroke-width="2.5" fill="none" stroke-linecap="round"/></svg>',
  );

/** The header's face and location chip for each Chief header state (the host's words). */
function chiefHeaderProps(kind: ChiefHeader): Pick<MessagesTranscriptProps, "face" | "place"> {
  const chip = (tone: ChiefPlace["tone"], text: string, glyph: ChiefPlace["glyph"]): ChiefPlace => ({
    conversation: "c-chief",
    tone,
    text,
    glyph,
    label: `Chief location: ${text}`,
    help: "Moves the Chief to another Mac or to cmux Cloud",
  });
  switch (kind) {
    case "here":
      return { face: { picture: CHIEF_PICTURE }, place: chip("here", "This Mac", "thisMac") };
    case "away":
      return { face: { picture: CHIEF_PICTURE }, place: chip("away", "Chief is on studio-mini", "host") };
    case "moving":
      return { face: { text: "🦊" }, place: chip("running", "Moving to cmux Cloud…", "moving") };
    case "failed":
      return { place: chip("failed", "Move to studio-mini failed", "failed") };
  }
}

const me: HomeParticipant = { id: "me", kind: "human", name: "Taylor", chief: false };
const chief: HomeParticipant = { id: "chief", kind: "agent", name: "Chief", chief: true };
const ana: HomeParticipant = { id: "ana", kind: "human", name: "Ana Ruiz", chief: false };
const sam: HomeParticipant = { id: "sam", kind: "human", name: "Sam Okafor", chief: false };

function conversation(kind: HomeConversation["kind"], participants: HomeParticipant[]): HomeConversation {
  return {
    id: `c-${kind}`,
    owner: "local",
    title: kind === "group" ? "Launch crew" : "",
    kind,
    participants,
    lastSeq: 0,
    rev: 1,
    updatedAt: GALLERY_NOW,
    unread: 0,
    mentions: 0,
    muted: false,
    pinned: false,
  };
}

let seq = 0;
function message(
  author: string,
  minutes: number,
  parts: HomePart[] | string,
  extra: Partial<HomeMessage> = {},
): HomeMessage {
  seq += 1;
  return {
    id: `m${seq}`,
    conversation: "c",
    seq,
    author,
    createdAt: minutesAgo(minutes),
    retracted: false,
    parts: typeof parts === "string" ? [{ type: "text", text: parts, mentions: [] }] : parts,
    reactions: [],
    ...extra,
  };
}

function chat(): HomeMessage[] {
  seq = 0;
  return [
    message("me", 26 * 60, "Can you look at why the sidebar flickers on resize?"),
    message("chief", 26 * 60 - 1, "On it. I'll start with the divider drag and the live resize."),
    message("chief", 95, "Found it: the list re-measured every row on each width step."),
    message("chief", 95, "The fix keeps the measured heights and re-measures only the visible rows."),
    message("me", 40, "Nice. Ship it?", {
      reactions: [{ author: "chief", partIndex: 0, value: "👍", tapback: "like" }],
    }),
    message("chief", 39, "Opened the PR and asked for a review."),
    message("me", 3, "Thanks! Ping me when it lands."),
    message("me", 2, "Also the release notes line, please."),
  ];
}

function data(state: State): Fixture {
  const direct = conversation("chief", [me, chief]);
  const cursors: Record<string, ReadCursor> = { chief: { seq: 7, at: minutesAgo(2) } };
  const base = {
    conversation: direct,
    messages: chat(),
    readCursors: cursors,
    connection: "online" as Fixture["connection"],
  };
  switch (state) {
    case "conversation":
      return base;
    case "empty":
      return { ...base, messages: [], readCursors: {} };
    case "long": {
      seq = 0;
      const long = Array.from({ length: 10_000 }, (_, index) =>
        message(index % 3 ? "chief" : "me", 10_000 - index, `Message ${index + 1} of a long chat.`),
      );
      return { ...base, messages: long, hasOlder: true, readCursors: { chief: { seq: 10_000, at: minutesAgo(0) } } };
    }
    case "failed": {
      const pending: PendingSend[] = [
        {
          key: "k1",
          conversation: direct.id,
          text: "This one didn't make it.",
          createdAt: minutesAgo(1),
          failed: true,
        },
      ];
      return { ...base, pending };
    }
    case "offline": {
      const pending: PendingSend[] = [
        {
          key: "k2",
          conversation: direct.id,
          text: "Sending while the owner reconnects",
          createdAt: minutesAgo(1),
          failed: false,
        },
      ];
      return {
        ...base,
        pending,
        connection: "offline" as Fixture["connection"],
        initialDraft: "Draft kept while offline",
      };
    }
    case "typing":
      return { ...base, typing: ["chief"] };
    case "attachments": {
      const messages = chat();
      const jpeg = (hash: string) => ({ hash, mimeType: "image/jpeg", byteCount: 24_000 });
      messages.push(
        message("chief", 1, [
          { type: "text", text: "Before and after:", mentions: [] },
          {
            type: "attachment",
            hash: "a".repeat(64),
            name: "sidebar-before.png",
            mimeType: "image/png",
            byteCount: 812_000,
            width: 1600,
            height: 1000,
            preview: jpeg("b".repeat(64)),
          },
          {
            type: "attachment",
            hash: "c".repeat(64),
            name: "sidebar-after.png",
            mimeType: "image/png",
            byteCount: 790_000,
            width: 1600,
            height: 1000,
            preview: jpeg("d".repeat(64)),
          },
        ]),
        message("chief", 1, [
          {
            type: "attachment",
            hash: "2".repeat(64),
            name: "release-notes.pdf",
            mimeType: "application/pdf",
            byteCount: 90_000,
          },
        ]),
      );
      return { ...base, messages };
    }
    case "diagram": {
      const messages = chat();
      messages.push(
        message(
          "chief",
          1,
          "Here is the resize path now:\n\n```mermaid\nflowchart LR\n  Drag --> Width[New width]\n  Width --> Visible[Measure visible rows]\n  Visible --> Frame[One frame]\n```",
        ),
      );
      return { ...base, messages };
    }
    case "agents":
      return {
        ...base,
        agents: [
          {
            group: "g1",
            after: "m2",
            row: {
              peers: ["a1", "a2"],
              titles: ["Find the resize flicker", "Keep measured heights"],
              states: ["reported", "told"],
            },
          },
        ],
      };
    case "agentsMany":
      return {
        ...base,
        agents: [
          {
            group: "g1",
            after: "m2",
            row: {
              peers: ["a1", "a2", "a4"],
              titles: ["Find the resize flicker", "Keep measured heights", "Check the narrow window"],
              states: ["reported", "told", "stopped"],
              unread: [true, false, false],
            },
          },
          { group: "g2", after: "m8", row: { peers: ["a3"], titles: ["Release notes line"], states: ["queued"] } },
        ],
      };
    case "group": {
      seq = 0;
      const room = conversation("group", [me, ana, sam, chief]);
      const messages = [
        message("ana", 50, "Is the launch checklist up to date?"),
        message("ana", 50, "I added the store screenshots."),
        message("sam", 30, "Updated it this morning."),
        message("me", 20, "Great, thanks both."),
        message("chief", 5, "I can draft the announcement if you want."),
      ];
      return {
        ...base,
        conversation: room,
        messages,
        typing: ["sam"],
        readCursors: { ana: { seq: 4, at: minutesAgo(10) } },
        viewing: ["ana", "sam"],
      };
    }
  }
}

const panelIcon = (d: string) => (
  <svg viewBox="0 0 20 20" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden>
    <path d={d} />
  </svg>
);

function TranscriptGallery({ look, state, colors, panels, chiefHeader, pane: initialPane }: Props) {
  const [strings] = useState(() => createTranscriptStrings());
  const [cards] = useState(() => cardStrings());
  const [pane, setPane] = useState<AgentPaneState>(initialPane ?? { tabs: [] });
  const source: AgentThreadSource = {
    thread: (peer) => AGENT_THREADS.find((thread) => thread.peer === peer),
    markSeen: () => {},
    send: () => {},
  };
  const [agentPills] = useState(() => ({
    strings: cards,
    open: (peer: string) => setPane((current) => openAgent(current, peer, source)),
  }));
  const [service] = useState(() => new AttachmentService(new MockHomeProvider(undefined, false, "none", false, true)));
  const [fixture] = useState(() => data(state));
  const [pending, setPending] = useState<readonly PendingSend[]>(() => fixture.pending ?? []);
  const [messages, setMessages] = useState(fixture.messages);
  return (
    <div style={{ height: "100%", position: "relative" }}>
      <div className="hm-detail-frame">
        <MessagesTranscript
          strings={strings}
          me="me"
          {...fixture}
          messages={messages}
          pending={pending}
          look={look}
          colors={colors}
          attachments={service}
          now={GALLERY_NOW}
          {...(chiefHeader ? chiefHeaderProps(chiefHeader) : {})}
          panels={
            panels
              ? [
                  {
                    id: "agents",
                    icon: panelIcon("M3.5 4.5h13v11h-13zM12 4.5v11"),
                    label: "Agents",
                    shortcut: "⌥⌘B",
                    on: true,
                  },
                  {
                    id: "info",
                    icon: panelIcon("M10 9v5M10 6.5v.5M10 17a7 7 0 1 0 0-14 7 7 0 0 0 0 14z"),
                    label: "Info",
                    on: false,
                  },
                ]
              : undefined
          }
          onSend={async (text) => {
            const last = messages.at(-1)?.seq ?? 0;
            setMessages((list) => [...list, { ...message("me", 0, text), seq: last + 1, id: `sent${last + 1}` }]);
            return true;
          }}
          onRetry={(key) =>
            setPending((list) => list.map((entry) => (entry.key === key ? { ...entry, failed: false } : entry)))
          }
          onDiscard={(key) => setPending((list) => list.filter((entry) => entry.key !== key))}
          onLoadOlder={() => {}}
          {...(fixture.agents ? { agentPills } : {})}
        />
        <AgentSidePane
          pane={pane}
          content={(peer) => {
            const thread = source.thread(peer);
            return thread ? agentChatContent(thread, GALLERY_NOW, cards) : undefined;
          }}
          strings={cards}
          onSelect={(peer) => setPane(selectAgent(pane, peer, source))}
          onClose={(peer) => setPane(closeAgent(pane, peer, source))}
          onGoToWorkspace={() => {}}
          onSend={() => {}}
        />
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "home.messages-transcript",
  title: "Messages transcript and composer",
  area: "Home and Chief",
  height: 720,
  widths: { narrow: 360, normal: 560, wide: 820 },
  covers: [
    "pages/home-messages/transcript/MessagesTranscript.tsx#MessagesTranscript",
    "pages/home-messages/transcript/TranscriptRows.tsx#TranscriptRowView",
    "pages/home-messages/transcript/MessageComposer.tsx#MessageComposer",
    "pages/home-messages/transcript/TranscriptHeader.tsx#TranscriptHeader",
    "pages/home-messages/transcript/ChiefPlace.tsx#ChiefPlaceChip",
  ],
  load: async () => TranscriptGallery,
  styles: () =>
    Promise.all([
      import("../../home-channels/styles.css"),
      import("./transcript.css"),
      import("../cards/cards.css"),
      import("../detail/detail.css"),
    ]),
  variants: {
    imessage: {
      note: "The default look: Messages' blue for mine, its grey for theirs, tails on each group's last bubble, Read under my newest read message.",
      props: { look: "imessage", state: "conversation", panels: true },
    },
    theme: {
      note: "The theme's look: my bubbles in the theme's accent, theirs on its surface.",
      props: { look: "theme", state: "conversation", panels: true },
    },
    outline: {
      note: "The outline look: my bubbles in the accent, theirs a hairline outline.",
      props: { look: "outline", state: "conversation", panels: true },
    },
    "chat-colors": {
      note: "The chat's own colours (Chat Colors) over the look: yellow mine with automatic black text, navy theirs.",
      props: { look: "imessage", state: "conversation", colors: { sent: "#FFD60A", received: "#1C2A4A" } },
    },
    empty: { note: "A conversation with no messages yet.", props: { look: "imessage", state: "empty" } },
    long: {
      note: "10,000 messages: only the rows near the viewport render, so it opens as fast as a short chat.",
      props: { look: "imessage", state: "long" },
    },
    "failed-send": {
      note: "A send the owner refused: Not Delivered under it, the red mark to Try Again; the right-click menu has Delete.",
      props: { look: "imessage", state: "failed" },
    },
    offline: {
      note: "Offline: a send waits (dimmed), Send is off and the draft stays.",
      props: { look: "imessage", state: "offline" },
    },
    typing: {
      note: "The Chief is typing: one typing bubble under the newest message.",
      props: { look: "imessage", state: "typing" },
    },
    attachments: {
      note: "Images as one media row under their text, and a PDF row.",
      props: { look: "imessage", state: "attachments" },
    },
    diagram: {
      note: "A mermaid fence in the Chief's reply draws as a diagram.",
      props: { look: "imessage", state: "diagram" },
    },
    "chief-here": {
      note: "Picked: a Chief chat's header with the Chief's picked character and its location chip (This Mac); the chip opens the app's Teleport menu.",
      props: { look: "imessage", state: "conversation", panels: true, chiefHeader: "here" },
    },
    "chief-away": {
      note: "The Chief runs on another Mac: the chip says where.",
      props: { look: "imessage", state: "conversation", panels: true, chiefHeader: "away" },
    },
    "chief-moving": {
      note: "A move runs: the chip shows its step; the profile's text avatar in the header.",
      props: { look: "imessage", state: "conversation", panels: true, chiefHeader: "moving" },
    },
    "chief-failed": {
      note: "A move failed: the chip in the danger colour; no picture, the name's monogram.",
      props: { look: "imessage", state: "conversation", panels: true, chiefHeader: "failed" },
    },
    group: {
      note: "A group chat: names over each run, avatars beside its last bubble, faces of who else is here, Sam typing.",
      props: { look: "imessage", state: "group", panels: true },
    },
    agents: {
      note: "Picked: a Chief turn's agents as one pill each under the message they follow (a check once reported, the turning arc while working); a click opens the agent.",
      props: { look: "imessage", state: "agents", panels: true },
    },
    "agents-many": {
      note: "Two turns' agents: a stopped one (cross), an unread report (dot), a queued one (still clock) under the newest message.",
      props: { look: "imessage", state: "agentsMany", panels: true },
    },
    "agents-pane": {
      note: "An agent opened from its pill with no session link: its chat in the agent pane right of the conversation, which narrows to keep 320 points.",
      props: { look: "imessage", state: "agentsMany", panels: true, pane: { tabs: ["a1", "a2"], selected: "a1" } },
    },
  },
});
