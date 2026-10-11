// l10n-allow-file: dev-loop fixture data (sample agents and messages), not shipped UI.
// An in-memory `cmux.home` provider for the browser dev loop (`/home-channels/?mock`) and the
// gallery. It is not the backend: the session daemon's conversation owner and the Cloud owners are.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { MockPageStreams } from "../shared/pageStreams";
import { threadOf } from "./model";
import {
  HomeOps,
  type HomeConversation,
  type HomeDraftItem,
  type HomeEventBatch,
  type HomeMessage,
  type HomeParticipant,
  type HomeThreadStats,
} from "./types";

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
    text("c-release", 2, builder, BASE + 9 * MINUTE, "Sidebar fix is pushed: `a1b2c3d`. Build is green.", {
      reactions: [
        { author: reviewer.id, partIndex: 0, value: "✅" },
        { author: chief.id, partIndex: 0, value: "✅" },
        { author: docs.id, partIndex: 0, value: "🙌" },
      ],
    }),
    text("c-release", 3, reviewer, BASE + 11 * MINUTE, "One question on the scroll restore.", {
      replyTo: { message: "c-release-m2", partIndex: 0 },
    }),
    text("c-release", 4, builder, BASE + 12 * MINUTE, "It keeps the anchor row; see `restoreAnchor()`.", {
      threadRoot: "c-release-m2",
    }),
    text("c-release", 5, reviewer, BASE + 13 * MINUTE, "Good. Approved.", { threadRoot: "c-release-m2" }),
    text("c-release", 6, docs, BASE + 20 * MINUTE, "Changelog draft is ready. @you can you read it?", {
      reactions: [{ author: me.id, partIndex: 0, value: "👀" }],
    }),
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
    conversation("c-release", "release", "group", [chief, builder, reviewer, docs], release, 4),
    conversation("c-design", "design", "group", [reviewer, docs], design),
    conversation("c-builder", "", "direct", [builder], builderDM, 1),
    conversation("c-reviewer", "", "direct", [reviewer], []),
  ];
  return { conversations, messages };
}

/** #incident (gallery `longThread`): a root whose 130 thread replies reach past one page, then a
 * newer top-level message, so the newest page holds neither the root nor its first replies. Reply
 * 50 is retracted: it stays in the thread as deleted but does not count (129 replies). */
export function addLongThread(home: ReturnType<typeof sampleHome>): void {
  const id = "c-incident";
  const list = [text(id, 1, chief, BASE - 120 * MINUTE, "Incident: the build queue is stuck. Updates in the thread.")];
  for (let index = 1; index <= 130; index += 1) {
    const author = index % 2 ? builder : reviewer;
    list.push(
      text(id, index + 1, author, BASE - 119 * MINUTE + index * 10_000, `Update ${index}.`, {
        threadRoot: `${id}-m1`,
        ...(index === 50 ? { retracted: true, parts: [] } : {}),
      }),
    );
  }
  list.push(text(id, 132, chief, BASE - 90 * MINUTE, "Queue is moving again."));
  home.messages.set(id, list);
  home.conversations.push(conversation(id, "incident", "group", [chief, builder, reviewer], list));
}

/** The owner's stats of the thread roots in `page`, counted over every reply of the conversation that
 * is not retracted (as both owners count them). */
function statsFor(all: readonly HomeMessage[], page: readonly HomeMessage[]): HomeThreadStats[] {
  const roots = new Set(page.filter((m) => !threadOf(m)).map((m) => m.id));
  const stats = new Map<string, HomeThreadStats>();
  for (const message of all) {
    const root = threadOf(message);
    if (!root || !roots.has(root) || message.retracted) continue;
    const entry = stats.get(root) ?? { root, replyCount: 0, authors: [] };
    entry.replyCount += 1;
    entry.lastReplySeq = message.seq;
    entry.lastReplyAt = message.createdAt;
    if (entry.authors.length < 3 && !entry.authors.includes(message.author)) entry.authors.push(message.author);
    stats.set(root, entry);
  }
  return [...stats.values()];
}

/** The Chief's running reply in the Chief DM (gallery): it grows, or it posts and a late item follows. */
export type MockDraft = "growing" | "posted";

const DRAFT_TURN = "turn-draft-1";
const DRAFT_TEXT = ["Checking the release: ", "Builder's fix is merged, ", "Reviewer approved it. ", "Docs is next."];

export class MockHomeProvider implements PageClient {
  readonly page = new MockPageStreams();
  private readonly data = sampleHome();
  private readonly listeners = new Set<(batch: HomeEventBatch, seq: number) => void>();
  private seq = 0;

  constructor(
    private readonly draft?: MockDraft,
    longThread = false,
  ) {
    if (longThread) addLongThread(this.data);
  }

  /** The Chief writes its reply after the page subscribes: one fresh item, then appends. */
  private playDraft(): void {
    if (!this.draft) return;
    const item = (seq: number, text: string, fresh: boolean, done = false): HomeDraftItem => ({
      conversation: "c-chief",
      participant: chief.id,
      turn: DRAFT_TURN,
      segment: 0,
      seq,
      talk: true,
      text,
      fresh,
      done,
    });
    const items = DRAFT_TEXT.map((text, index) => item(index + 1, text, index === 0));
    this.emit({ typing: [{ conversation: "c-chief", participant: chief.id, on: true }], drafts: items });
    if (this.draft !== "posted") return;
    const list = this.data.messages.get("c-chief") ?? [];
    const posted = text("c-chief", list.length + 1, chief, BASE + 4 * MINUTE, DRAFT_TEXT.join(""), {
      clientMessageId: DRAFT_TURN,
    });
    list.push(posted);
    // The reply posts, then a late draft item of the same turn arrives: it must not show again.
    this.emit({ messages: [posted], typing: [{ conversation: "c-chief", participant: chief.id, on: false }] });
    this.emit({ drafts: [item(DRAFT_TEXT.length + 1, " (late)", false)] });
  }

  async call<R>(op: string, rawParams: unknown): Promise<R> {
    const params = (rawParams ?? {}) as Record<string, unknown>;
    const id = String(params.conversation ?? "");
    switch (op) {
      case HomeOps.inbox:
        return { me, conversations: this.data.conversations, rev: 1 } as R;
      case HomeOps.page: {
        const found = this.data.conversations.find((c) => c.id === id);
        if (!found) throw pageError("cmux.home.not_found", id);
        const all = this.data.messages.get(id) ?? [];
        const messages = all.slice(-Math.max(1, Number(params.tail ?? 100)));
        return { conversation: found, messages, threads: statsFor(all, messages) } as R;
      }
      case HomeOps.history: {
        const all = this.data.messages.get(id) ?? [];
        const before = all.filter((m) => m.seq < Number(params.beforeSeq ?? 0));
        const messages = before.slice(-Math.max(1, Number(params.limit ?? 100)));
        return { messages, threads: statsFor(all, messages) } as R;
      }
      case HomeOps.thread: {
        const all = this.data.messages.get(id) ?? [];
        const root = all.find((m) => m.id === params.root && !threadOf(m));
        if (!root) throw pageError("cmux.home.not_found", String(params.root));
        const after = Number(params.afterSeq ?? 0);
        const limit = Math.max(1, Number(params.limit ?? 100));
        const replies = all.filter((m) => threadOf(m) === root.id && m.seq > after);
        const [thread] = statsFor(all, [root]);
        return {
          root,
          replies: replies.slice(0, limit),
          hasMore: replies.length > limit,
          thread: thread ?? { root: root.id, replyCount: 0, authors: [] },
        } as R;
      }
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
      case HomeOps.react: {
        const list = this.data.messages.get(id) ?? [];
        const index = list.findIndex((m) => m.id === params.message);
        if (index < 0) throw pageError("cmux.home.not_found", String(params.message));
        const old = list[index]!;
        const value = String(params.value ?? "");
        const reactions = params.remove
          ? old.reactions.filter((r) => !(r.author === me.id && r.value === value))
          : [...old.reactions, { author: me.id, partIndex: 0, value }];
        list[index] = { ...old, reactions };
        this.emit({ messages: [list[index]!] });
        return {} as R;
      }
      case HomeOps.createGroup: {
        const ids = (params.participants as string[] | undefined) ?? [];
        const people = [chief, builder, reviewer, docs].filter((p) => ids.includes(p.id));
        const id = `c-${this.data.conversations.length + 1}`;
        const created = conversation(id, String(params.title ?? ""), "group", people, []);
        this.data.conversations.push(created);
        this.data.messages.set(created.id, []);
        return { conversation: created.id } as R;
      }
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
    this.playDraft();
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
