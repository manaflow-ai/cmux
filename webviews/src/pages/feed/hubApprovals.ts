// The integrations hub's approvals in Chief's pinned Needs you section. The app's hub provider
// (CmuxNextAgentIntegrations SettingsIntegrationsHub, routed on `cmux.settings.hub.` only in Chief)
// owns everything: the CLI shapes each card (cmux-tui cli/hub.rs `approval_cards`), an answer goes
// out on the person's click, and the answered card stays with its outcome until the next refresh.
// This only reads the state on open and on `cmux.settings.hub.changed`, and sends the click. A page
// with no hub route (the Feed anywhere else) reads nothing and draws no card.
import { isPageError, type PageClient } from "../shared/pageClient";

export const HubOps = {
  state: "cmux.settings.hub.state",
  run: "cmux.settings.hub.run",
  changed: "cmux.settings.hub.changed",
} as const;

/** One card, as the CLI shaped it (`approvalCards`). */
export interface HubApprovalCard {
  approvalId: string;
  callId: string;
  /** "agent support-bot". */
  agentText: string;
  /** "Stripe · Acme", or the provider when the account is not listed. */
  integrationText: string;
  /** "Refund". */
  actionText: string;
  amountText?: string | null;
  /** The hub's pinned summary, which names the target: "Refund 12.00 USD of 25.00 USD on Stripe charge ch_1". */
  line: string;
  /** "Team rule: Ask before Stripe refunds over 10.00 USD". */
  ruleText: string;
  expiresText?: string | null;
}

/** The card a click answered: what it ran (`call`) or the refusal. */
export interface HubAnswer {
  approvalId: string;
  decision: "approve" | "deny";
  card: HubApprovalCard;
  call?: { outcomeText?: string | null; outcomeTone?: "done" | "denied" | "failed" | null } | null;
  refused?: { code: string; message: string } | null;
}

interface HubState {
  overview?: { ok?: boolean; approvalCards?: HubApprovalCard[] } | null;
  lastAnswer?: HubAnswer | null;
}

/** What Chief draws: each card with its answer, if it has one. */
export interface HubCardRow {
  card: HubApprovalCard;
  answer?: HubAnswer;
  /** A click on this card is out and not settled. */
  sending: boolean;
}

export interface HubSnapshot {
  rows: readonly HubCardRow[];
}

const EMPTY: HubSnapshot = { rows: [] };

/** The rows from the provider's state: the waiting cards, the answered one in its place (or first,
 *  once the hub no longer lists it). */
export function hubRows(state: HubState | null | undefined, sending?: string): HubCardRow[] {
  const cards = state?.overview?.ok ? (state.overview.approvalCards ?? []) : [];
  const answer = state?.lastAnswer ?? undefined;
  const rows = cards.map((card) => ({
    card,
    answer: answer?.approvalId === card.approvalId ? answer : undefined,
    sending: card.approvalId === sending,
  }));
  if (answer && !cards.some((card) => card.approvalId === answer.approvalId)) {
    rows.unshift({ card: answer.card, answer, sending: false });
  }
  return rows;
}

export class HubApprovals {
  private snapshot: HubSnapshot = EMPTY;
  private state: HubState | null = null;
  private sending?: string;
  private readonly listeners = new Set<() => void>();
  private stopChanges?: () => void;
  private generation = 0;
  private started = false;

  constructor(private readonly client: PageClient | null) {}

  getSnapshot = (): HubSnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    if (!this.started) void this.start();
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stop();
    };
  };

  private async start(): Promise<void> {
    if (!this.client) return;
    this.started = true;
    try {
      const stop = await this.client.subscribe(HubOps.changed, () => void this.read());
      if (this.started) this.stopChanges = stop;
      else stop();
    } catch (error) {
      // A Feed page outside Chief has no hub route: it draws no card.
      if (isPageError(error) && error.code === "cmux.protocol.unknown_op") return;
    }
    await this.read();
  }

  private stop(): void {
    this.started = false;
    this.stopChanges?.();
    this.stopChanges = undefined;
  }

  /** Reads the provider's state; only the newest read writes it. */
  async read(): Promise<void> {
    if (!this.client) return;
    const mine = ++this.generation;
    try {
      const state = await this.client.call<HubState>(HubOps.state, {});
      if (mine !== this.generation) return;
      this.state = state;
    } catch {
      if (mine !== this.generation) return;
      this.state = null;
    }
    this.publish();
  }

  /** The person's click: approve or deny one card. The provider answers, refreshes and says it changed. */
  async answer(approvalId: string, decision: "approve" | "deny"): Promise<void> {
    if (!this.client || this.sending) return;
    this.sending = approvalId;
    this.publish();
    try {
      await this.client.call(HubOps.run, { action: decision, id: approvalId });
    } catch {
      // The provider records a refusal on the card (`lastAnswer.refused`); the read below shows it.
    } finally {
      this.sending = undefined;
      await this.read();
    }
  }

  private publish(): void {
    this.snapshot = { rows: hubRows(this.state, this.sending) };
    for (const listener of this.listeners) listener();
  }
}
