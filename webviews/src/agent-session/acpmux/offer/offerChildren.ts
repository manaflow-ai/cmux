// The chats started from a chat's offers (cx-lo9yf), while they run: each started task's row
// shows its chat's latest tool call ("Reading CartLineItem.tsx"). The pane attaches to such a chat
// hidden (`visible: false`, so its turn is not marked seen) for those records only, and detaches
// when the chat's turn ends, the chat it was offered in is left, or the connection drops.

type Request = (method: string, params: Record<string, unknown>) => Promise<any>;
type ChildRecord = { sessionId?: string; dir?: string; kind?: string; msg?: any };

/// What a hidden attach to a started chat asks for: its tool calls, and the end of its turn.
export const CHILD_KINDS = ["tool_call", "tool_call_update", "turn_result"];
/// Running chats watched at once, at most; the rest show their status alone.
export const CHILD_WATCH_LIMIT = 5;
/// The newest records an attach to an already running chat reads, for its latest tool call.
const CHILD_PAGE = 20;

const running = (status: string | undefined) => status === "running" || status === "waiting";

export class OfferChildren {
  private readonly attached = new Set<string>();
  /// Chats a Start is prompting: attached for that prompt, whatever their status says.
  private readonly pinned = new Set<string>();
  private readonly ended = new Set<string>();
  private readonly titles = new Map<string, string>();

  constructor(
    private readonly request: Request,
    /// The chat the pane shows: a detach never ends that chat's own attach.
    private readonly shown: () => string | undefined,
    /// A watched chat's tool call or end changed what its row shows.
    private readonly changed: (child: string) => void,
  ) {}

  /// The latest tool call's title of chat `child`, while its turn runs.
  activity(child: string): string | undefined {
    return this.ended.has(child) ? undefined : this.titles.get(child);
  }

  /// Attaches to `children` (each started chat with its status) that run and are not watched yet,
  /// up to the limit; detaches from watched ones that stopped.
  want(children: readonly { child: string; status?: string }[]): void {
    for (const { child, status } of children) {
      if (status === undefined || running(status)) continue;
      // A chat that stopped: a later turn of it is watched again.
      if (this.attached.has(child) && !this.pinned.has(child)) this.finish(child);
      else if (!this.attached.has(child)) this.ended.delete(child);
    }
    for (const { child, status } of children) {
      if (this.attached.size >= CHILD_WATCH_LIMIT) break;
      if (running(status) && !this.attached.has(child) && !this.ended.has(child)) void this.attach(child, CHILD_PAGE);
    }
  }

  /// Sends chat `child` its first prompt through `prompt`, attached hidden meanwhile: acpmux
  /// attaches a prompt's sender as a viewer, which would mark the turn seen. The attach ends
  /// with the prompt's turn.
  async prompting(child: string, prompt: () => Promise<unknown>): Promise<void> {
    this.pinned.add(child);
    try {
      await this.attach(child, 0);
      await prompt();
    } finally {
      this.pinned.delete(child);
      this.finish(child);
    }
  }

  /// A record from a watched chat; false for any other chat's.
  event(record: ChildRecord): boolean {
    const child = record.sessionId;
    if (!child || !this.attached.has(child)) return false;
    this.read(child, record);
    if (record.kind === "turn_result" && !this.pinned.has(child)) this.finish(child);
    return true;
  }

  /// The pane left the chat, or lost its connection (`connected` false): every watch ends.
  reset(connected: boolean): void {
    if (connected) for (const child of this.attached) this.detach(child);
    this.attached.clear();
    this.pinned.clear();
    this.ended.clear();
    this.titles.clear();
  }

  private async attach(child: string, limit: number): Promise<void> {
    this.attached.add(child);
    this.ended.delete(child);
    try {
      const result = await this.request("_acpmux/attach", {
        sessionId: child,
        limit,
        kinds: CHILD_KINDS,
        eventStream: true,
        visible: false,
      });
      const events: ChildRecord[] = Array.isArray(result?.events) ? result.events : [];
      for (const record of events) this.read(child, { ...record, sessionId: child });
    } catch {
      // A chat acpmux would not attach shows its status alone.
      this.attached.delete(child);
    }
  }

  private read(child: string, record: ChildRecord): void {
    if (record.kind === "turn_result") {
      this.ended.add(child);
      this.changed(child);
      return;
    }
    const update = record.msg?.params?.update ?? record.msg?.update;
    const title = typeof update?.title === "string" ? update.title.trim() : "";
    if (record.dir !== "in" || !title) return;
    this.ended.delete(child);
    if (this.titles.get(child) === title) return;
    this.titles.set(child, title);
    this.changed(child);
  }

  private finish(child: string): void {
    if (!this.attached.delete(child)) return;
    this.ended.add(child);
    this.titles.delete(child);
    this.changed(child);
    this.detach(child);
  }

  private detach(child: string): void {
    if (this.shown() === child) return;
    void this.request("_acpmux/detach", { sessionId: child }).catch(() => undefined);
  }
}
