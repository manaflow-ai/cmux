// l10n-allow-file: dev-loop fixture data (sample agents and messages), not shipped UI.
// An in-memory `cmux.home` provider for the browser dev loop (`/home-channels/?mock`) and the
// gallery. It is not the backend: the session daemon's conversation owner and the Cloud owners are.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { MockPageStreams } from "../shared/pageStreams";
import { threadOf } from "./model";
import {
  HomeOps,
  type HomeAttachment,
  type HomeChief,
  type HomeConversation,
  type HomeDraftItem,
  type HomeEventBatch,
  type HomeLiveFrame,
  type HomeLiveSnapshot,
  type HomeMessage,
  type HomeParticipant,
  type HomeRun,
  type HomeRunStep,
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
/** Teammates (gallery `teammates`): people on the same Home, as `tailnet:<login>` ids. */
const human = (login: string, name: string): HomeParticipant => ({
  id: `tailnet:${login}`,
  kind: "human",
  name,
  chief: false,
});
export const ana = human("ana@example.com", "Ana Ruiz");
export const sam = human("sam@example.com", "Sam Okafor");

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

/** #launch (gallery `teammates`): a channel two teammates share with you and the Chief. */
export function addTeammates(home: ReturnType<typeof sampleHome>): void {
  const id = "c-launch";
  const list = [
    text(id, 1, ana, BASE + 40 * MINUTE, "Launch checklist is up. I take the store listing."),
    text(id, 2, sam, BASE + 41 * MINUTE, "I take the release notes."),
    text(id, 3, chief, BASE + 42 * MINUTE, "Noted. I post each item here when it lands."),
  ];
  home.messages.set(id, list);
  home.conversations.push(conversation(id, "launch", "group", [ana, sam, chief], list));
}

/** A sample file part (gallery `media`): the mock draws its pixels when the page reads it. */
function file(hash: string, name: string, mimeType: string, byteCount: number, extra: Partial<HomeAttachment> = {}) {
  return { type: "attachment" as const, hash, name, mimeType, byteCount, ...extra };
}

/** #media (gallery `media`): screenshots, a run recording with its poster, and a PDF. */
export function addMedia(home: ReturnType<typeof sampleHome>): void {
  const id = "c-media";
  const jpeg = (hash: string) => ({ hash, mimeType: "image/jpeg", byteCount: 24_000 });
  const message = text(id, 1, builder, BASE + 30 * MINUTE, "Screens from the sidebar fix, and the run.");
  message.parts.push(
    file("a".repeat(64), "sidebar-before.png", "image/png", 812_000, {
      width: 1600,
      height: 1000,
      preview: jpeg("b".repeat(64)),
    }),
    file("c".repeat(64), "sidebar-after.png", "image/png", 790_000, {
      width: 1600,
      height: 1000,
      preview: jpeg("d".repeat(64)),
    }),
    file("e".repeat(64), "scroll.png", "image/png", 64_000, { width: 640, height: 400 }),
    file("f".repeat(64), "run-recording.mp4", "video/mp4", 2_300_000, {
      width: 1280,
      height: 720,
      durationMs: 6_000,
      poster: jpeg("1".repeat(64)),
    }),
    file("2".repeat(64), "release-notes.pdf", "application/pdf", 90_000),
  );
  home.messages.set(id, [message]);
  home.conversations.push(conversation(id, "media", "group", [builder, reviewer], [message]));
}

/** A raster picture of `hash` as base64 PNG (the mock stores no bytes; it draws one per hash). */
async function picture(hash: string): Promise<string> {
  const canvas = document.createElement("canvas");
  canvas.width = 320;
  canvas.height = 200;
  const context = canvas.getContext("2d");
  if (context) {
    const hue = (parseInt(hash.slice(0, 2), 16) * 47) % 360;
    const gradient = context.createLinearGradient(0, 0, 320, 200);
    gradient.addColorStop(0, `hsl(${hue} 55% 45%)`);
    gradient.addColorStop(1, `hsl(${(hue + 60) % 360} 55% 25%)`);
    context.fillStyle = gradient;
    context.fillRect(0, 0, 320, 200);
  }
  const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/png"));
  const bytes = new Uint8Array(await (blob ?? new Blob()).arrayBuffer());
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
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

/** Sample agent runs (`MockRuns`): none, the Chief's finished run on its last DM reply, or that
 * plus a run that works now and streams its steps. */
export type MockRuns = "none" | "done" | "live";

const RUN_TURN = "turn:mock:c-chief-m4";
const LIVE_TURN = "turn:mock:c-chief-m6";
const SESSION = { kind: "acpmux", id: "01a139a8-f91e-7be2-86aa-516bf4c7e5e5" };

function sampleRun(): { run: HomeRun; steps: HomeRunStep[] } {
  const at = BASE + 2 * MINUTE + 4_000;
  const tool = (
    seq: number,
    id: string,
    name: string,
    kind: string,
    title: string,
    input: Record<string, unknown>,
    output: string,
    extra: Partial<NonNullable<HomeRunStep["tool"]>> = {},
  ): HomeRunStep => ({
    id: `tool:${id}`,
    seq,
    at: at + seq * 6_000,
    rev: seq,
    kind: "tool",
    status: "done",
    tool: { name, kind, title, input, output, files: [], ...extra },
    attachments: [],
    links: [],
  });
  const steps: HomeRunStep[] = [
    tool(
      1,
      "t1",
      "Bash",
      "execute",
      "gh pr list --label release",
      { command: "gh pr list --label release" },
      "#20412  sidebar fix   Builder\n#20418  changelog     Docs",
    ),
    tool(
      2,
      "t2",
      "Read",
      "read",
      "Read CHANGELOG.md",
      { file_path: "CHANGELOG.md" },
      "## 0.66.0 (unreleased)\n- Sidebar fix",
    ),
    {
      id: "thought:0",
      seq: 3,
      at: at + 18_000,
      rev: 3,
      kind: "thought",
      text: "The changelog has the sidebar fix; the checklist still lists it as open.",
      attachments: [],
      links: [],
    },
    tool(4, "t3", "Edit", "edit", "Edit release/checklist.md", { file_path: "release/checklist.md" }, "", {
      files: [
        {
          path: "release/checklist.md",
          oldText: "- [ ] sidebar fix\n- [ ] review\n",
          newText: "- [x] sidebar fix\n- [ ] review\n- [ ] changelog\n",
          added: 2,
          removed: 1,
        },
      ],
    }),
    {
      id: "talk:0",
      seq: 5,
      at: at + 50_000,
      rev: 5,
      kind: "talk",
      text: "Started. I post in #release when each one lands.",
      attachments: [],
      links: [{ label: "Agent session", url: `cmux://chief/5176e030/session/${SESSION.id}` }],
    },
  ];
  return {
    run: {
      id: RUN_TURN,
      conversation: "c-chief",
      author: chief.id,
      status: "done",
      startedAt: at,
      endedAt: BASE + 3 * MINUTE,
      updatedAt: BASE + 3 * MINUTE,
      rev: 6,
      stepCount: steps.length,
      turn: RUN_TURN,
      answers: ["c-chief-m3"],
      title: "Start the three release items",
      usage: { input: 1_840, output: 612, cacheRead: 46_200 },
      costUsd: 0.0421,
      model: "claude-opus-5-5",
      harness: "claude",
      session: SESSION,
    },
    steps,
  };
}

/** A Chief as the owner sends it (the host relay answers raw records). */
function rawChief(c: HomeChief): Record<string, unknown> {
  return {
    id: c.id,
    display_name: c.name,
    role: c.role,
    personality: c.personality,
    instructions: c.instructions,
    tools: c.tools,
    harnesses: c.harnesses,
    self_edit: c.selfEdit,
    is_default: c.isDefault,
    rev: c.rev,
    created_at: c.createdAt,
    avatar: c.avatar ? { sha256: c.avatar, media_type: "image/png", bytes: 0 } : null,
    ...(c.engine ? { engine: c.engine } : {}),
    locked: c.locked === true,
  };
}

/** The sample acpmux harnesses (`cmux.chief.backend.list`). */
const MOCK_BACKENDS = {
  harnesses: {
    defaultHarness: "claude",
    harnesses: {
      claude: { displayName: "Claude Code" },
      codex: { displayName: "Codex" },
      "claude-sr2": { displayName: "Claude (SR2)" },
      opencode: { displayName: "OpenCode" },
      unii: { displayName: "Unii" },
    },
  },
  models: {
    harnesses: [
      {
        harness: "claude",
        models: [
          { id: "claude-opus-5-5", name: "Opus 5.5", efforts: ["low", "medium", "high", "max"] },
          { id: "claude-sonnet-5-5", name: "Sonnet 5.5", efforts: ["low", "medium", "high"] },
        ],
      },
      { harness: "codex", models: [{ id: "gpt-6-astra", name: "GPT-6 Astra", efforts: ["low", "medium", "high"] }] },
    ],
  },
};

/** The backend and lock a create or update names (an empty engine text clears it). */
function engineFields(params: Record<string, unknown>, old: HomeChief | undefined): Partial<HomeChief> {
  const out: Partial<HomeChief> = {};
  const engine: NonNullable<HomeChief["engine"]> = {};
  for (const key of ["harness", "model", "effort"] as const) {
    const value = typeof params[key] === "string" ? (params[key] as string) : old?.engine?.[key];
    if (value && !(key === "harness" && value === "default")) engine[key] = value;
  }
  // Cleared fields drop out; no field left is the Chief's usual.
  out.engine = Object.keys(engine).length > 0 ? engine : undefined;
  if (typeof params.locked === "boolean") out.locked = params.locked;
  else if (old?.locked) out.locked = true;
  return out;
}

export class MockHomeProvider implements PageClient {
  readonly page = new MockPageStreams();
  private readonly data = sampleHome();
  private readonly listeners = new Set<(batch: HomeEventBatch, seq: number) => void>();
  private seq = 0;

  private readonly runs = new Map<string, { run: HomeRun; steps: HomeRunStep[] }>();
  /** The live run's text so far (chief-live-v1): what `cmux.home.live` answers. */
  private liveSnapshot: HomeLiveSnapshot | undefined;
  private readonly uploads = new Map<string, Record<string, unknown>>();
  /** The Chief records (the sample Chief is the default one). */
  private readonly chiefs = new Map<string, HomeChief>([
    [
      chief.id,
      {
        id: chief.id,
        name: chief.name,
        role: "Runs the team's agents",
        personality: "Brief.",
        instructions: "",
        tools: ["browser", "chiefs", "cloud_vms", "memory_import", "spawn", "tell", "workspaces"],
        harnesses: [],
        selfEdit: ["avatar"],
        isDefault: true,
        rev: 1,
        createdAt: new Date(BASE).toISOString(),
      },
    ],
  ]);
  private readonly pictures = new Map<string, { mediaType: string; data: string }>();
  /** Also serve the host's `cmux.chief.profile.*` relay (a page in the app). */
  hostGrants = false;
  /** Every committed record state, by Chief id, oldest first (`chief.profile.history`). */
  private readonly revisions = new Map<
    string,
    { rev: number; at: string; actor: string; operation: string; record: HomeChief }[]
  >();
  /** Backends the person brought (`cmux.chief.backend.add`). */
  private readonly brought: Record<string, { displayName: string }> = {};

  private commit(record: HomeChief, operation: string, actor = ""): void {
    this.chiefs.set(record.id, record);
    const list = this.revisions.get(record.id) ?? [];
    list.push({ rev: record.rev, at: new Date(BASE + list.length * MINUTE).toISOString(), actor, operation, record });
    this.revisions.set(record.id, list);
  }

  /** Adds a Chief (the host's create; the gallery's second Chief). */
  addChief(name: string, fields: Partial<HomeChief> = {}): HomeChief {
    const made: HomeChief = {
      id: `agent_new${this.chiefs.size}`,
      name,
      role: "",
      personality: "",
      instructions: "",
      tools: ["chiefs", "spawn", "tell", "workspaces"],
      harnesses: [],
      selfEdit: ["avatar"],
      isDefault: false,
      rev: 1,
      createdAt: new Date(BASE).toISOString(),
      ...fields,
    };
    this.chiefs.set(made.id, made);
    return made;
  }

  private chief(id: string): HomeChief {
    const found = this.chiefs.get(id);
    if (!found) throw pageError("cmux.home.not_found", id);
    return found;
  }

  /** People met so far and the Chiefs, not me. */
  private directory(): HomeParticipant[] {
    const byId = new Map<string, HomeParticipant>();
    for (const c of this.chiefs.values()) byId.set(c.id, { id: c.id, kind: "agent", name: c.name, chief: true });
    for (const c of this.data.conversations) for (const p of c.participants) if (!byId.has(p.id)) byId.set(p.id, p);
    byId.delete(me.id);
    return [...byId.values()];
  }

  constructor(
    private readonly draft?: MockDraft,
    longThread = false,
    private readonly runMode: MockRuns = "none",
    /** The owner refuses pins and marks (the page puts the row back and says why). */
    private readonly refuseInbox = false,
    media = false,
    teammates = false,
  ) {
    if (longThread) addLongThread(this.data);
    if (media) addMedia(this.data);
    if (teammates) addTeammates(this.data);
    if (runMode !== "none") {
      const done = sampleRun();
      this.runs.set(done.run.id, done);
      const list = this.data.messages.get("c-chief") ?? [];
      const reply = list.find((m) => m.id === "c-chief-m4");
      if (reply) reply.clientMessageId = RUN_TURN;
    }
  }

  /** A run that works now: a new question, then the Chief's steps one by one. */
  private playRun(): void {
    if (this.runMode !== "live") return;
    const list = this.data.messages.get("c-chief") ?? [];
    const asked = text("c-chief", list.length + 1, me, Date.now() - 20_000, "Is CI green on the release branch?");
    asked.id = "c-chief-m5";
    list.push(asked);
    const started = Date.now() - 18_000;
    const run: HomeRun = {
      id: LIVE_TURN,
      conversation: "c-chief",
      author: chief.id,
      status: "running",
      startedAt: started,
      updatedAt: started,
      rev: 2,
      stepCount: 2,
      turn: LIVE_TURN,
      answers: [asked.id],
      title: "Check CI on the release branch",
      harness: "claude",
      session: SESSION,
    };
    const steps: HomeRunStep[] = [
      {
        id: "tool:c1",
        seq: 1,
        at: started + 2_000,
        rev: 1,
        kind: "tool",
        status: "done",
        tool: {
          name: "Bash",
          kind: "execute",
          title: "gh run list --branch release",
          input: { command: "gh run list --branch release --limit 3" },
          output: "completed  success  CI  release  2m",
          files: [],
        },
        attachments: [],
        links: [],
      },
      {
        id: "tool:c2",
        seq: 2,
        at: started + 9_000,
        rev: 2,
        kind: "tool",
        status: "running",
        tool: {
          name: "Bash",
          kind: "execute",
          title: "gh run view --log-failed",
          input: { command: "gh run view 38544550381 --log-failed" },
          files: [],
        },
        attachments: [],
        links: [],
      },
    ];
    this.runs.set(run.id, { run, steps });
    this.emit({ messages: [asked], runs: [{ run, steps }] });
    // It writes its reply as it works (chief-live-v1): two frames, and what it works on now.
    const since = started + 9_000;
    const frames: HomeLiveFrame[] = [
      {
        type: "run.activity",
        conversation: "c-chief",
        run: run.id,
        author: chief.id,
        line: "Running gh run view --log-failed",
        since,
        at: since,
      },
      {
        type: "step.delta",
        conversation: "c-chief",
        run: run.id,
        author: chief.id,
        step: "talk:0",
        kind: "talk",
        seq: 0,
        text: "Two of the three runs passed. ",
      },
      {
        type: "step.delta",
        conversation: "c-chief",
        run: run.id,
        author: chief.id,
        step: "talk:0",
        kind: "talk",
        seq: 1,
        text: "Reading the failed job's log now",
      },
    ];
    this.liveSnapshot = {
      type: "run.live",
      conversation: "c-chief",
      runs: [
        {
          run: run.id,
          author: chief.id,
          steps: [
            {
              step: "talk:0",
              kind: "talk",
              seq: 1,
              text: "Two of the three runs passed. Reading the failed job's log now",
            },
          ],
          activity: { line: "Running gh run view --log-failed", since, at: since },
        },
      ],
    };
    this.emit({ live: frames });
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
        return { me, conversations: this.data.conversations, rev: 1, inboxState: true } as R;
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
      case HomeOps.pin:
      case HomeOps.markUnread: {
        if (this.refuseInbox) throw pageError("cmux.page.unavailable", "this cmux instance keeps no pins");
        const index = this.data.conversations.findIndex((c) => c.id === id);
        if (index < 0) throw pageError("cmux.home.not_found", id);
        const current = this.data.conversations[index]!;
        const pinned = op === HomeOps.pin ? params.pinned === true : current.pinned;
        const markedUnread = op === HomeOps.markUnread ? params.unread === true : current.markedUnread === true;
        const change = {
          conversation: id,
          pinned,
          markedUnread,
          ...(pinned ? { pinPosition: op === HomeOps.pin && !current.pinned ? Date.now() : current.pinPosition } : {}),
        };
        const updated = { ...current, pinned, markedUnread, pinPosition: change.pinPosition };
        this.data.conversations[index] = updated;
        this.emit({ inbox: [change] });
        return { conversation: id } as R;
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
        const parent = typeof params.replyTo === "string" ? params.replyTo : undefined;
        const message = text(
          id,
          list.length + 1,
          me,
          Date.now(),
          String(params.text ?? ""),
          thread ? { threadRoot: thread, ...(parent ? { replyTo: { message: parent, partIndex: 0 } } : {}) } : {},
        );
        // The owner keeps the sender's idempotency key as the message's client id (the page's
        // pending send ends on it).
        if (typeof params.idempotencyKey === "string") message.clientMessageId = params.idempotencyKey;
        if (!message.parts[0] || (message.parts[0].type === "text" && !message.parts[0].text)) message.parts = [];
        if (Array.isArray(params.attachments)) message.parts.push(...(params.attachments as HomeAttachment[]));
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
      case HomeOps.capabilities:
        return { start: true, invite: true, chiefs: true } as R;
      case HomeOps.directory:
        return { people: this.directory() } as R;
      case HomeOps.startConversation: {
        const ids = (params.participants as string[] | undefined) ?? [];
        const title = String(params.title ?? "").trim();
        if (ids.length === 1 && !title) {
          const direct = this.data.conversations.find(
            (c) => c.participants.length === 2 && c.participants.some((p) => p.id === ids[0]),
          );
          if (direct) return { conversation: direct.id } as R;
        }
        const people = this.directory().filter((p) => ids.includes(p.id));
        const id = `c-${this.data.conversations.length + 1}`;
        const name = title || people.map((p) => p.name).join(", ");
        const created = conversation(
          id,
          name,
          people.length === 1 ? (people[0]!.chief ? "chief" : "direct") : "group",
          people,
          [],
        );
        this.data.conversations.push(created);
        this.data.messages.set(created.id, []);
        this.emit({ conversations: [created] });
        return { conversation: created.id } as R;
      }
      case HomeOps.invite: {
        const found = this.data.conversations.find((c) => c.id === id);
        if (!found) throw pageError("cmux.home.not_found", id);
        const ids = (params.participants as string[] | undefined) ?? [];
        const added = this.directory().filter(
          (p) => ids.includes(p.id) && !found.participants.some((q) => q.id === p.id),
        );
        const updated = { ...found, participants: [...found.participants, ...added] };
        this.data.conversations = this.data.conversations.map((c) => (c.id === id ? updated : c));
        this.emit({ conversations: [updated] });
        return { conversation: id } as R;
      }
      case HomeOps.chiefs:
        return { chiefs: [...this.chiefs.values()] } as R;
      case HomeOps.chiefUpdate: {
        const old = this.chief(String(params.chief));
        const changed = { ...old, name: String(params.name), role: String(params.role ?? ""), rev: old.rev + 1 };
        this.chiefs.set(changed.id, changed);
        return { chief: changed } as R;
      }
      case HomeOps.chiefAvatarSet: {
        const old = this.chief(String(params.chief));
        const clear = params.clear === true;
        const changed = { ...old, avatar: clear ? "" : `pic-${old.rev + 1}`, rev: old.rev + 1 };
        this.chiefs.set(changed.id, changed);
        if (clear) this.pictures.delete(changed.id);
        else this.pictures.set(changed.id, { mediaType: String(params.mediaType), data: String(params.data) });
        return { chief: changed } as R;
      }
      case HomeOps.chiefAvatar:
        return { avatar: this.pictures.get(String(params.chief)) ?? null } as R;
      case "cmux.chief.profile.list":
        if (!this.hostGrants) throw pageError("cmux.protocol.unknown_op", op);
        return {
          chiefs: [...this.chiefs.values()].map((c) => ({ id: c.id, rev: c.rev, created_at: c.createdAt })),
        } as R;
      case "cmux.chief.profile.create": {
        if (!this.hostGrants) throw pageError("cmux.protocol.unknown_op", op);
        // The gallery reads what the sheet sent (which grant fields it named).
        if (typeof document !== "undefined")
          document.documentElement.dataset.mockChiefCreate = Object.keys(params).sort().join(",");
        const made = this.addChief(String(params.display_name), {
          role: String(params.role ?? ""),
          personality: String(params.personality ?? ""),
          instructions: String(params.instructions ?? ""),
          ...(Array.isArray(params.tools) ? { tools: params.tools as string[] } : {}),
          ...(Array.isArray(params.harnesses) ? { harnesses: params.harnesses as string[] } : {}),
          ...engineFields(params, undefined),
        });
        this.commit(made, "chief.profile.create");
        return { value: rawChief(made) } as R;
      }
      case "cmux.chief.profile.update": {
        if (!this.hostGrants) throw pageError("cmux.protocol.unknown_op", op);
        const old = this.chief(String(params.chief));
        const text = (key: string, fallback: string) =>
          typeof params[key] === "string" ? String(params[key]) : fallback;
        const changed = {
          ...old,
          personality: text("personality", old.personality),
          instructions: text("instructions", old.instructions),
          tools: (params.tools as string[] | undefined) ?? old.tools,
          harnesses: (params.harnesses as string[] | undefined) ?? old.harnesses,
          ...engineFields(params, old),
          rev: old.rev + 1,
        };
        if (!this.revisions.has(old.id)) this.commit(old, "chief.profile.create");
        this.commit(changed, "chief.profile.update");
        return { value: rawChief(changed) } as R;
      }
      case "cmux.chief.profile.history": {
        if (!this.hostGrants) throw pageError("cmux.protocol.unknown_op", op);
        const id = String(params.chief);
        const current = this.chief(id);
        if (!this.revisions.has(id)) this.commit(current, "chief.profile.create");
        const list = [...(this.revisions.get(id) ?? [])].reverse();
        return { chief: id, revisions: list.map((r) => ({ ...r, record: rawChief(r.record) })) } as R;
      }
      case "cmux.chief.profile.undo": {
        if (!this.hostGrants) throw pageError("cmux.protocol.unknown_op", op);
        const old = this.chief(String(params.chief));
        const list = this.revisions.get(old.id) ?? [];
        const target =
          typeof params.to_rev === "number" ? list.find((r) => r.rev === params.to_rev) : list[list.length - 2];
        if (!target) throw pageError("cmux.home.not_found", "no earlier revision");
        const changed = { ...target.record, rev: old.rev + 1 };
        this.commit(changed, "chief.profile.undo");
        return { value: rawChief(changed) } as R;
      }
      case "cmux.chief.backend.list":
        if (!this.hostGrants) throw pageError("cmux.protocol.unknown_op", op);
        return {
          harnesses: {
            ...MOCK_BACKENDS.harnesses,
            harnesses: { ...MOCK_BACKENDS.harnesses.harnesses, ...this.brought },
          },
          models: MOCK_BACKENDS.models,
        } as R;
      case "cmux.chief.backend.add": {
        if (!this.hostGrants) throw pageError("cmux.protocol.unknown_op", op);
        const name = String(params.name ?? "backend");
        const id =
          name
            .toLowerCase()
            .replace(/[^a-z0-9]+/g, "-")
            .replace(/^-|-$/g, "") || "my-backend";
        this.brought[id] = { displayName: name };
        return { id } as R;
      }
      case "cmux.chief.backend.doctor":
        if (!this.hostGrants) throw pageError("cmux.protocol.unknown_op", op);
        // The sample "broken" backend fails its hello turn, with the fix the doctor names.
        return (
          String(params.id).includes("broken")
            ? {
                ok: false,
                steps: [
                  { name: "launch", ok: true },
                  { name: "prompt", ok: false, detail: "401 Unauthorized", fix: "Check the API key." },
                ],
              }
            : {
                ok: true,
                steps: [
                  { name: "launch", ok: true },
                  { name: "prompt", ok: true },
                ],
              }
        ) as R;
      case "cmux.chief.profile.delete":
        if (!this.hostGrants) throw pageError("cmux.protocol.unknown_op", op);
        this.chiefs.delete(String(params.chief));
        return {} as R;
      case HomeOps.createGroup: {
        const ids = (params.participants as string[] | undefined) ?? [];
        const people = [chief, builder, reviewer, docs].filter((p) => ids.includes(p.id));
        const id = `c-${this.data.conversations.length + 1}`;
        const created = conversation(id, String(params.title ?? ""), "group", people, []);
        this.data.conversations.push(created);
        this.data.messages.set(created.id, []);
        return { conversation: created.id } as R;
      }
      case HomeOps.updateThread: {
        const list = this.data.messages.get(id) ?? [];
        const index = list.findIndex((m) => m.id === params.root && !threadOf(m));
        if (index < 0) throw pageError("cmux.home.not_found", String(params.root));
        const old = list[index]!;
        const thread = { ...old.thread };
        if (typeof params.title === "string") thread.title = params.title || undefined;
        if (typeof params.owner === "string") thread.owner = params.owner || undefined;
        if (params.status === "resolved") thread.resolved = { by: me.id, at: Date.now(), seq: list.length };
        if (params.status === "open") thread.resolved = undefined;
        const empty = !thread.title && !thread.owner && !thread.resolved;
        list[index] = { ...old, thread: empty ? undefined : thread };
        this.emit({ messages: [list[index]!] });
        return {} as R;
      }
      case HomeOps.search:
        return { hits: [] } as R;
      case HomeOps.attachmentSupport:
        return { local: true, cloud: false } as R;
      case HomeOps.attachmentUpload: {
        // The steps of an upload; the mock keeps no bytes.
        if (params.op === "begin") {
          const upload = `upload-${this.uploads.size + 1}`;
          const needs = ["original", ...(params.poster ? ["poster"] : []), ...(params.preview ? ["preview"] : [])];
          this.uploads.set(upload, params);
          return { upload, needs, stored: null } as R;
        }
        if (params.op === "chunk") return { received: Number(params.offset ?? 0) } as R;
        const begun = this.uploads.get(String(params.upload ?? "")) ?? {};
        return {
          stored: { hash: begun.sha256, mime_type: begun.mime_type, byte_count: begun.byte_count },
        } as R;
      }
      case HomeOps.attachmentRead: {
        const data = await picture(String(params.hash ?? ""));
        return { mimeType: "image/png", byteCount: data.length, offset: 0, data, eof: true } as R;
      }
      case HomeOps.attachmentUrl:
        // No video bytes in the mock: the player shows its poster.
        throw pageError("cmux.page.unavailable", "the mock serves no video");
      case HomeOps.runs: {
        const turns = (params.turns as string[] | undefined) ?? [];
        const all = [...this.runs.values()].filter((entry) => entry.run.conversation === id);
        const runs = (turns.length ? all.filter((entry) => turns.includes(entry.run.turn ?? "")) : all).map(
          (entry) => entry.run,
        );
        return { runs, hasMore: false } as R;
      }
      case HomeOps.live:
        return (this.liveSnapshot?.conversation === id ? this.liveSnapshot : null) as R;
      case HomeOps.run: {
        const entry = this.runs.get(String(params.run ?? ""));
        if (!entry) throw pageError("cmux.home.run_rejected", "unknown_run");
        const after = Number(params.afterRev ?? 0);
        return { run: entry.run, steps: entry.steps.filter((step) => step.rev > after), hasMore: false } as R;
      }
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
    this.playRun();
    return () => void this.listeners.delete(listener);
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => undefined;
  }

  /** Who has `conversation` open, as the owner's `conversation-presence` says (gallery `teammates`). */
  viewing(conversation: string, participants: readonly string[]): void {
    this.emit({
      presence: [{ conversation, participants: participants.map((participant) => ({ participant, viewing: true })) }],
    });
  }

  /** A participant starts or stops typing (gallery `teammates`). */
  typing(conversation: string, participant: string, on: boolean): void {
    this.emit({ typing: [{ conversation, participant, on }] });
  }

  private emit(batch: HomeEventBatch): void {
    queueMicrotask(() => {
      for (const listener of this.listeners) listener(batch, ++this.seq);
    });
  }
}
