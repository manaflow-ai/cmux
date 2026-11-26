// l10n-allow-file: mock integrations hub data; the real labels come from cmux-tui cli/hub.rs.
// The mock Settings > Integrations: a view model shaped like `cmux hub overview --json` and the
// host's answers to each gesture (SettingsIntegrationsHub), so the card and its gallery run with
// no CLI and no hub. Pure data: the gallery imports these fixtures.
import type { HubCall, HubConnection, HubOverview, HubRule, HubRun, HubState } from "./ops";

export const MOCK_HUB_STRIPE: HubConnection = {
  id: "hubc_mock_stripe",
  provider: "stripe",
  account: "acct_1MockAcme",
  providerLabel: "Stripe",
  title: "Stripe · Acme",
  modeLabel: "Test mode",
  sharingLabel: "Only you",
  statusLabel: "Working",
  healthy: true,
  canRemove: true,
};

export const MOCK_HUB_GITHUB: HubConnection = {
  id: "hubc_mock_github",
  provider: "github",
  account: "acme",
  providerLabel: "GitHub",
  title: "GitHub · acme",
  modeLabel: null,
  sharingLabel: "Your team",
  statusLabel: "Working",
  healthy: true,
  canRemove: true,
};

export const MOCK_HUB_APPROVAL: HubCall = {
  id: "hcall_mock_refund",
  status: "waiting",
  line: "Refund 12.00 USD on ch_3MockCharge (requested_by_customer)",
  statusLabel: "Waiting for you",
  amountText: "12.00 USD",
  actionLabel: "refunding a Stripe charge",
  requestedByText: "Asked by Claude Code in acme-support",
  approvalId: "apr_mock_refund",
  expiresText: "Expires in 14 minutes",
  policyText: "Your rule: Ask before Stripe refunds over 5.00 USD",
};

export const MOCK_HUB_RULES: HubRule[] = [
  {
    id: "hubr_mock_small",
    text: "Allow Stripe refunds up to 5.00 USD",
    ownerLabel: "Yours",
    canRemove: true,
    remembered: false,
  },
  {
    id: "hubr_mock_ask",
    text: "Ask before Stripe refunds over 5.00 USD",
    ownerLabel: "Yours",
    canRemove: true,
    remembered: false,
  },
  {
    id: "hubr_mock_team",
    text: "Block any GitHub action in acme/secret",
    ownerLabel: "Team (an admin's)",
    canRemove: false,
    remembered: false,
  },
];

export function mockHubOverview(patch: Partial<Extract<HubOverview, { ok: true }>> = {}): HubOverview {
  return {
    ok: true,
    available: true,
    paused: false,
    pausedText: "Agents can call linked accounts under your rules.",
    connections: [MOCK_HUB_STRIPE],
    hasStripe: true,
    hasGithub: false,
    approvals: [MOCK_HUB_APPROVAL],
    rules: MOCK_HUB_RULES,
    audit: [
      {
        seq: 3,
        eventLabel: "Waiting",
        line: "Refund 12.00 USD on ch_3MockCharge waits for you",
        whenText: "2 minutes ago",
        tone: "warn",
      },
      {
        seq: 2,
        eventLabel: "Allowed",
        line: "Refunded 4.00 USD on ch_3MockOther (your rule)",
        whenText: "1 hour ago",
        tone: "good",
      },
      {
        seq: 1,
        eventLabel: "Linked",
        line: "Linked Stripe · Acme (test mode)",
        whenText: "Yesterday",
        tone: "plain",
      },
    ],
    next: null,
    ...patch,
  };
}

export function mockHubState(overview: HubOverview | null = mockHubOverview()): HubState {
  return { loading: false, problem: null, overview, error: null, lastCall: null };
}

/** The host's answer to one gesture, on the mock state. */
export function runMockHub(state: HubState, run: HubRun): HubState {
  const overview = state.overview;
  if (run.action === "refresh" || !overview || !overview.ok) return state;
  const next = { ...state, error: null, lastCall: null };
  switch (run.action) {
    case "link":
      if (run.provider === "stripe" && run.key.startsWith("rk_live_"))
        return {
          ...next,
          error: {
            action: "link",
            code: "stripe.live_not_yet",
            message: "Live Stripe keys are not supported yet. Paste a test key (rk_test_).",
          },
        };
      if (run.provider === "stripe" && !run.key.startsWith("rk_test_"))
        return {
          ...next,
          error: { action: "link", code: "cli.bad_key", message: "That is not a Stripe restricted key (rk_test_...)." },
        };
      return {
        ...next,
        overview:
          run.provider === "stripe"
            ? { ...overview, hasStripe: true, connections: [...overview.connections, MOCK_HUB_STRIPE] }
            : { ...overview, hasGithub: true, connections: [...overview.connections, MOCK_HUB_GITHUB] },
      };
    case "remove": {
      const connections = overview.connections.filter((row) => row.id !== run.id);
      return {
        ...next,
        overview: {
          ...overview,
          connections,
          hasStripe: connections.some((row) => row.provider === "stripe"),
          hasGithub: connections.some((row) => row.provider === "github"),
        },
      };
    }
    case "approve":
    case "deny": {
      const call = overview.approvals.find((row) => row.approvalId === run.id);
      if (!call)
        return { ...next, error: { action: run.action, code: "hub.not_found", message: "That approval is gone." } };
      const allowed = run.action === "approve";
      const remembered: HubRule[] =
        allowed && run.remember
          ? [
              {
                id: "hubr_mock_remembered",
                text: "Allow Stripe refunds up to 12.00 USD",
                ownerLabel: "Yours",
                canRemove: true,
                remembered: true,
              },
            ]
          : [];
      return {
        ...next,
        lastCall: {
          ...call,
          approvalId: null,
          expiresText: null,
          status: allowed ? "succeeded" : "denied",
          statusLabel: allowed ? "Done" : "Denied",
        },
        overview: {
          ...overview,
          approvals: overview.approvals.filter((row) => row.approvalId !== run.id),
          rules: [...overview.rules, ...remembered],
        },
      };
    }
    case "pause":
      return {
        ...next,
        overview: {
          ...overview,
          paused: run.paused,
          pausedText: run.paused
            ? "Paused: every agent call is refused until you turn this off."
            : "Agents can call linked accounts under your rules.",
        },
      };
    case "removeRule":
      return { ...next, overview: { ...overview, rules: overview.rules.filter((rule) => rule.id !== run.id) } };
    case "addRule":
      return {
        ...next,
        overview: {
          ...overview,
          rules: [
            ...overview.rules,
            {
              id: `hubr_mock_${overview.rules.length + 1}`,
              text: `${run.effect} ${run.ruleAction}`,
              ownerLabel: "Yours",
              canRemove: true,
              remembered: false,
            },
          ],
        },
      };
  }
}
