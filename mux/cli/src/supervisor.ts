import { AcpmuxClient, retryAgentStart, type Notification, type SessionSummary } from "@mux/acpmux";

/** Tag on every agent the mux started; its events go back to that mux. */
export const PARENT_TAG = "mux.parent";
/** Prefix of prompts the supervisor sends; hooks log them as events, not user messages. */
export const EVENT_PREFIX = "[mux-event]";

export interface PermissionOption {
  optionId: string;
  name?: string;
  kind?: string;
}

/** What the mux is told when one of its agents ends a turn or asks for a permission. */
export function turnEndedPrompt(agent: SessionSummary, reply: string): string {
  return `${EVENT_PREFIX} Agent ${agent.name} (${agent.harness}, ${agent.cwd}) finished a turn.\nIts reply:\n${reply || "(empty)"}\n\nTell the user what matters, briefly, and take the next step yourself if there is one.`;
}

export function permissionPrompt(agent: SessionSummary, request: Record<string, unknown>): string {
  const toolCall = (request.toolCall ?? {}) as { title?: string; rawInput?: unknown };
  const options = ((request.options ?? []) as PermissionOption[]).map(
    (o) => `${o.optionId} (${o.name ?? o.kind ?? ""})`,
  );
  const detail =
    toolCall.rawInput === undefined
      ? ""
      : `\nInput: ${JSON.stringify(toolCall.rawInput).slice(0, 600)}`;
  return `${EVENT_PREFIX} Agent ${agent.name} asks permission: ${toolCall.title ?? "a tool call"}${detail}\nOptions: ${options.join(", ") || "(none)"}\nAnswer with \`mux agents allow ${agent.name} OPTION_ID\` or \`mux agents deny ${agent.name}\`. Ask the user first if it is destructive or outward-facing.`;
}

/**
 * Watches acpmux and forwards child-agent events to their mux as queued
 * prompts. Only status transitions count: a turn ended when a child leaves
 * `running` for `ready` or `idle`.
 */
export class Supervisor {
  private status = new Map<string, SessionSummary["status"]>();
  private readonly client: AcpmuxClient;
  private readonly lastReply: (sessionId: string) => Promise<string>;
  private readonly log: (line: string) => void;

  constructor(
    client: AcpmuxClient,
    lastReply: (sessionId: string) => Promise<string>,
    log: (line: string) => void = () => {},
  ) {
    this.client = client;
    this.lastReply = lastReply;
    this.log = log;
  }

  async start(): Promise<void> {
    for (const s of await this.client.sessions()) this.status.set(s.sessionId, s.status);
    this.client.onNotification(
      (n) => void this.handle(n).catch((e) => this.log(`event failed: ${String(e)}`)),
    );
    await this.client.watch(true);
  }

  async handle(n: Notification): Promise<void> {
    if (n.method === "_acpmux/session_changed") {
      const session = n.params.session as SessionSummary | undefined;
      if (!session) return;
      const before = this.status.get(session.sessionId);
      this.status.set(session.sessionId, session.status);
      const parent = session.tags?.[PARENT_TAG];
      if (
        !parent ||
        before !== "running" ||
        (session.status !== "ready" && session.status !== "idle")
      )
        return;
      this.log(`turn ended: ${session.name} -> ${parent}`);
      await this.send(parent, turnEndedPrompt(session, await this.lastReply(session.sessionId)));
      return;
    }
    if (n.method === "_acpmux/permission_pending") {
      const sessionId = String(n.params.sessionId);
      const session = (await this.client.sessions()).find((s) => s.sessionId === sessionId);
      const parent = session?.tags?.[PARENT_TAG];
      if (!session || !parent) return;
      this.log(`permission: ${session.name} -> ${parent}`);
      await this.send(
        parent,
        permissionPrompt(session, (n.params.request ?? {}) as Record<string, unknown>),
      );
    }
  }

  /** Queues a prompt on the mux; acpmux delivers it after the mux's current turn. */
  private async send(parent: string, text: string): Promise<void> {
    void retryAgentStart(() => this.client.prompt(parent, text)).catch((e) =>
      this.log(`prompt to ${parent} failed: ${String(e)}`),
    );
  }
}
