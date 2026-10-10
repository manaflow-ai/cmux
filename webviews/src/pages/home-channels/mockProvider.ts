// l10n-allow-file: dev-loop fixture data (sample agents and messages), not shipped UI.
// An in-memory `cmux.home` provider for the browser dev loop (`/home-channels/?mock`) and the
// gallery. It is not the backend: the session daemon's conversation owner and the Cloud owners are.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { MockPageStreams } from "../shared/pageStreams";
import { HomeOps, type HomeConversation, type HomeEventBatch, type HomeMessage, type HomeParticipant } from "./types";

const me: HomeParticipant = { id: "user_local", kind: "human", name: "You", chief: false };
const chief: HomeParticipant = { id: "agent_chief", kind: "agent", name: "Chief", chief: true };
const agent = (name: string): HomeParticipant => ({
  id: `agent_${name.toLowerCase()}`,
  kind: "agent",
  name,
  chief: false,
});
const builder = agent("Builder");
const reviewer = agent("Reviewer");
const docs = agent("Docs");

const MINUTE = 60_000;
const BASE = Date.UTC(2026, 9, 10, 9, 0, 0);

function text(
  conversation: string,
  seq: number,
  author: HomeParticipant,
  at: number,
  body: string,
  extra: Partial<HomeMessage> = {},
): HomeMessage {
  const mentions = [...body.matchAll(/@(\w+)/g)].flatMap((match) => {
    const who = [me, chief, builder, reviewer, docs].find(
      (p) => p.name === match[1] || (match[1] === "you" && p === me),
    );
    return who ? [{ start: match.index ?? 0, length: match[0].length, participant: who.id }] : [];
  });
  return {
    id: `${conversation}-m${seq}`,
    conversation,
    seq,
    author: author.id,
    createdAt: at,
    retracted: false,
    parts: [{ type: "text", text: body, mentions }],
    reactions: [],
    ...extra,
  };
}

function conversation(
  id: string,
  title: string,
  kind: HomeConversation["kind"],
  participants: HomeParticipant[],
  messages: HomeMessage[],
  unread = 0,
): HomeConversation {
  const last = messages.at(-1);
  return {
    id,
    owner: "local",
    title,
    kind,
    participants: [me, ...participants],
    lastSeq: last?.seq ?? 0,
    rev: last?.seq ?? 0,
    updatedAt: last?.createdAt ?? BASE,
    unread,
    mentions: messages
      .slice(messages.length - unread)
      .filter((m) => m.parts.some((p) => p.type === "text" && p.mentions.some((x) => x.participant === me.id))).length,
    muted: false,
    pinned: false,
    lastText: last?.parts[0]?.type === "text" ? last.parts[0].text : undefined,
  };
}

export function sampleHome(): { conversations: HomeConversation[]; messages: Map<string, HomeMessage[]> } {
  const messages = new Map<string, HomeMessage[]>();
  const chiefDM = [
    text("c-chief", 1, me, BASE, "What is left on the release?"),
    text(
      "c-chief",
      2,
      chief,
      BASE + MINUTE,
      "Three items:\n\n1. **Builder** finishes the sidebar fix.\n2. **Reviewer** checks the diff.\n3. Docs update the changelog.",
    ),
    text("c-chief", 3, me, BASE + 2 * MINUTE, "Start all three."),
    text("c-chief", 4, chief, BASE + 3 * MINUTE, "Started. I post in #release when each one lands."),
  ];
  const release = [
    text("c-release", 1, chief, BASE + 4 * MINUTE, "Release thread for v0.42. @Builder takes the sidebar fix."),
    text("c-release", 2, builder, BASE + 9 * MINUTE, "Sidebar fix is pushed: `a1b2c3d`. Build is green."),
    text("c-release", 3, reviewer, BASE + 11 * MINUTE, "One question on the scroll restore.", {
      replyTo: { message: "c-release-m2", partIndex: 0 },
    }),
    text("c-release", 4, builder, BASE + 12 * MINUTE, "It keeps the anchor row; see `restoreAnchor()`.", {
      threadRoot: "c-release-m2",
    }),
    text("c-release", 5, reviewer, BASE + 13 * MINUTE, "Good. Approved.", { threadRoot: "c-release-m2" }),
    text("c-release", 6, docs, BASE + 20 * MINUTE, "Changelog draft is ready. @you can you read it?"),
    text("c-release", 7, docs, BASE + 21 * MINUTE, "```md\n## v0.42\n- Sidebar keeps its scroll position\n```"),
  ];
  const design = [text("c-design", 1, reviewer, BASE - 60 * MINUTE, "The rail is denser now. Rows are 26 px.")];
  const builderDM = [text("c-builder", 1, builder, BASE + 8 * MINUTE, "Done with the sidebar. Anything else?")];
  messages.set("c-chief", chiefDM);
  messages.set("c-release", release);
  messages.set("c-design", design);
  messages.set("c-builder", builderDM);
  messages.set("c-reviewer", []);
  const conversations = [
    conversation("c-chief", "", "chief", [chief], chiefDM),
    conversation("c-release", "release", "group", [chief, builder, reviewer, docs], release, 2),
    conversation("c-design", "design", "group", [reviewer, docs], design),
    conversation("c-builder", "", "direct", [builder], builderDM, 1),
    conversation("c-reviewer", "", "direct", [reviewer], []),
  ];
  return { conversations, messages };
}

export class MockHomeProvider implements PageClient {
  readonly page = new MockPageStreams();
  private readonly data = sampleHome();
  private readonly listeners = new Set<(batch: HomeEventBatch, seq: number) => void>();
  private seq = 0;

  async call<R>(op: string, rawParams: unknown): Promise<R> {
    const params = (rawParams ?? {}) as Record<string, unknown>;
    const id = String(params.conversation ?? "");
    switch (op) {
      case HomeOps.inbox:
        return { me, conversations: this.data.conversations, rev: 1 } as R;
      case HomeOps.page: {
        const found = this.data.conversations.find((c) => c.id === id);
        if (!found) throw pageError("cmux.home.not_found", id);
        return { conversation: found, messages: this.data.messages.get(id) ?? [] } as R;
      }
      case HomeOps.history:
        return { messages: [] } as R;
      case HomeOps.read: {
        const index = this.data.conversations.findIndex((c) => c.id === id);
        if (index >= 0) {
          const updated = { ...this.data.conversations[index]!, unread: 0, mentions: 0 };
          this.data.conversations[index] = updated;
          this.emit({ conversations: [updated] });
        }
        return {} as R;
      }
      case HomeOps.send: {
        const list = this.data.messages.get(id) ?? [];
        const thread = typeof params.threadRoot === "string" ? params.threadRoot : undefined;
        const message = text(
          id,
          list.length + 1,
          me,
          Date.now(),
          String(params.text ?? ""),
          thread ? { threadRoot: thread } : {},
        );
        list.push(message);
        this.data.messages.set(id, list);
        this.emit({ messages: [message] });
        return {} as R;
      }
      case HomeOps.edit:
      case HomeOps.retract: {
        const list = this.data.messages.get(id) ?? [];
        const index = list.findIndex((m) => m.id === params.message);
        if (index < 0) throw pageError("cmux.home.not_found", String(params.message));
        const old = list[index]!;
        const updated: HomeMessage =
          op === HomeOps.edit
            ? { ...old, editedAt: Date.now(), parts: [{ type: "text", text: String(params.text ?? ""), mentions: [] }] }
            : { ...old, retracted: true, parts: [] };
        list[index] = updated;
        this.emit({ messages: [updated] });
        return {} as R;
      }
      case HomeOps.react:
      case HomeOps.search:
        return { hits: [] } as R;
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    const pageStream = this.page.subscribe(stream, onEvent as (data: unknown, seq: number) => void);
    if (pageStream) return pageStream;
    if (stream !== HomeOps.events) throw pageError("cmux.protocol.unknown_op", stream);
    const listener = onEvent as (batch: HomeEventBatch, seq: number) => void;
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => undefined;
  }

  private emit(batch: HomeEventBatch): void {
    queueMicrotask(() => {
      for (const listener of this.listeners) listener(batch, ++this.seq);
    });
  }
}
