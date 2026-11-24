// l10n-allow-file: gallery and test fixtures, not shipped UI.
// The integrations hub provider for the gallery and tests: the `cmux.settings.hub.*` ops Chief's
// Feed page reads (SettingsIntegrationsHub), with cards the way the CLI shapes them (cmux-tui
// cli/hub.rs `approval_cards`, `call_outcome`; hub_tests.rs pins the same words). An answer here
// lands like the app's: the card stays with its outcome until the next refresh.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { HubOps, type HubAnswer, type HubApprovalCard } from "./hubApprovals";

export const MOCK_HUB_REFUND: HubApprovalCard = {
  approvalId: "apr_000000000000000000000001",
  callId: "hcall_1",
  agentText: "agent support-bot",
  integrationText: "Stripe · Acme",
  actionText: "Refund",
  amountText: "12.00 USD",
  line: "Refund 12.00 USD of 25.00 USD on Stripe charge ch_3PqK2x",
  ruleText: "Team rule: Ask before Stripe refunds over 10.00 USD",
  expiresText: "Expires 2026-11-24 09:30 UTC",
};

export const MOCK_HUB_CARDS: HubApprovalCard[] = [
  MOCK_HUB_REFUND,
  {
    approvalId: "apr_000000000000000000000002",
    callId: "hcall_2",
    agentText: "agent billing-triage",
    integrationText: "Stripe · Acme",
    actionText: "Refund",
    amountText: "80.00 USD",
    line: "Refund 80.00 USD on Stripe charge ch_3PqL9a",
    ruleText:
      "Your rule: Allow Stripe refunds; at most 100.00 USD a day, then ask; over the limit of 100.00 USD a day (40.00 USD so far)",
    expiresText: "Expires 2026-11-24 10:00 UTC",
  },
  {
    approvalId: "apr_000000000000000000000003",
    callId: "hcall_3",
    agentText: "agent release",
    integrationText: "GitHub · manaflow-ai",
    actionText: "comment",
    amountText: null,
    line: "Comment on manaflow-ai/cmux#4",
    ruleText: "Rule: no rule for github.issues.comment; send-external actions ask a person by default",
    expiresText: "Expires 2026-11-24 10:00 UTC",
  },
];

export interface MockHubOptions {
  cards?: HubApprovalCard[];
  lastAnswer?: HubAnswer | null;
  /** An answer is refused with this message. */
  refuse?: string;
}

export class MockHubProvider implements PageClient {
  cards: HubApprovalCard[];
  lastAnswer: HubAnswer | null;
  readonly calls: { op: string; params: unknown }[] = [];
  private readonly listeners = new Set<() => void>();

  constructor(private readonly options: MockHubOptions = {}) {
    this.cards = [...(options.cards ?? MOCK_HUB_CARDS)];
    this.lastAnswer = options.lastAnswer ?? null;
  }

  async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params });
    switch (op) {
      case HubOps.state:
        return {
          loading: false,
          problem: null,
          overview: { ok: true, available: true, approvalCards: this.cards },
          error: null,
          lastCall: null,
          lastAnswer: this.lastAnswer,
        } as R;
      case HubOps.run: {
        const { action, id } = params as { action: string; id?: string };
        const card = this.cards.find((c) => c.approvalId === id);
        if (action === "refresh") this.lastAnswer = null;
        else if (card && (action === "approve" || action === "deny")) {
          this.lastAnswer = this.options.refuse
            ? {
                approvalId: card.approvalId,
                decision: action,
                card,
                refused: { code: "hub.forbidden", message: this.options.refuse },
              }
            : {
                approvalId: card.approvalId,
                decision: action,
                card,
                call:
                  action === "approve"
                    ? { outcomeText: "Approved. It ran (re_3PqK2x).", outcomeTone: "done" }
                    : { outcomeText: "Denied. Nothing ran.", outcomeTone: "denied" },
              };
          if (!this.options.refuse) this.cards = this.cards.filter((c) => c !== card);
        }
        for (const listener of this.listeners) listener();
        return { ok: !this.options.refuse } as R;
      }
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (stream !== HubOps.changed) throw pageError("cmux.protocol.unknown_op", stream);
    const listener = () => onEvent({} as E, 0);
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => undefined;
  }
}
