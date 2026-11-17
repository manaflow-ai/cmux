// l10n-allow-file: fixture prompts, host words and agent errors, never shown in the app.
//
// Every Cloud error, blocked and waiting state the agent pane draws for a Cloud chat that this measurement
// covers, each rendered as App.tsx renders it: the same component with the handlers App passes (a connected
// Cloud chat on the person's own machine, at its best: acpmux's turn retry, the agent's sign-in on the machine,
// credential setup). Each handler records where its click goes (classify.ts `Effect`), so the measurement reads
// what a click does, never what a button is called.
//
// Sources: Cloud start failures are the host's answers (CloudStartChat.swift, AgentPaneCloudStart.swift,
// CloudStrings.swift, the pane's own refusals in cloudStartProgress.ts REFUSED_HERE), ended through the pane's
// own reducer (`cloudStartEnded`); Cloud start waits are CloudStartView.gallery's starting variants; turn
// failures are one per `FailureKind` on a Cloud route (failureCopy.ts), plus the error card gallery's Cloud rows;
// repository recovery is RepoRecoveryCard.gallery's variants. A new gallery variant or failure kind is measured
// on the next run.
import type { ReactElement } from "react";
import { summary } from "../../../gallery/fixtures/acpmux";
import type { CloudSignIn } from "../cloudAgentLogin";
import cloudStartGallery from "../CloudStartView.gallery";
import { CloudStartView } from "../CloudStartView";
import { cloudStartEnded, type CloudStartProgress } from "../cloudStartProgress";
import type { FailureKind, FailureRoute } from "../failureCopy";
import repoRecoveryGallery from "../conversation/RepoRecoveryCard.gallery";
import { RepoRecoveryCard } from "../conversation/RepoRecoveryCard";
import { TurnFooter } from "../conversation/TurnRows";
import { TurnActionsContext, type TurnActions } from "../conversation/turnActions";
import type { Effect } from "./classify";

export type Recorder = (effect: Effect) => void;

export type ErgoState = {
  /// Stable and readable: `cloud-start.not_signed_in.timed-out`, `turn-failure.rate-limited`.
  id: string;
  type: "error" | "wait";
  surface: "cloud-start" | "turn-failure" | "repo-recovery";
  /// The element(s) that are this state's own: the card, the failure, the quiet line.
  region: string;
  /// The failure kind the fixture must read as (turn failures): a fixture that drifts fails its test.
  kind?: FailureKind;
  render(record: Recorder): ReactElement;
};

/// A handler's answer that never settles: the measurement reads the click, not what follows.
const NEVER: Promise<never> = new Promise<never>(() => {});
const inPlace =
  (record: Recorder, what: string) =>
  (..._args: unknown[]): Promise<never> => {
    record({ kind: "in-place", what });
    return NEVER;
  };

// ---- Cloud start (CloudStartView), as App.tsx's two call sites wire it ----

function cloudStartHandlers(record: Recorder) {
  return {
    onAnswer: inPlace(record, "answer the start's question"),
    onRetry: inPlace(record, "retry the start"),
    // cloudSignInRetry: the browser sign-in, then the same start goes again by itself.
    onSignIn: inPlace(record, "sign in, then the start goes again"),
    // access.addCredits: the app's paid-plan path (palette.pro.upgrade).
    onUpgrade: () => record({ kind: "out-of-app", what: "upgrade the plan" }),
    onRunHere: inPlace(record, "run the prompt on this Mac"),
    onDismiss: () => record({ kind: "dismiss", what: "not now" }),
    // The plan card's Switch to <team>: the team picker's switch, then the same start goes again.
    onSwitchTeam: inPlace(record, "switch to the person's own team, then the start goes again"),
  };
}

const startVariants = cloudStartGallery.variants as { [name: string]: { props: { start: CloudStartProgress } } };
const galleryStart = (name: string): CloudStartProgress => {
  const variant = startVariants[name];
  if (!variant) throw new Error(`CloudStartView.gallery has no variant ${name}`);
  return variant.props.start;
};

/// A host answer to a Cloud start: its code, its words, whether the host marked it retryable, and the
/// start it ended (a gallery variant's progress).
type HostAnswer = {
  id: string;
  code: string;
  message?: string;
  retryable?: boolean;
  from?: string;
  details?: unknown;
};
const HOST_ANSWERS: readonly HostAnswer[] = [
  // CloudStartChat.refusal: CloudStrings.startRefusal("not_signed_in").
  {
    id: "not_signed_in.refusal",
    code: "not_signed_in",
    message: "Sign in to use Cloud machines: run Sign In from the command palette, or `cmux cloud sign-in`.",
  },
  // AgentPaneCloudStart: the start that waited on its browser sign-in.
  { id: "not_signed_in.sign-in", code: "not_signed_in", message: "Sign in to continue" },
  { id: "not_signed_in.timed-out", code: "not_signed_in", message: "Sign-in timed out. Sign in again to continue." },
  // CloudStartChat: services gone, or Cloud off by policy (its words are the code).
  { id: "cloud_disabled", code: "cloud_disabled", message: "cloud_disabled" },
  // CloudStartChat: the tab is not a chat (CloudMoveStrings.notAChat).
  { id: "unavailable", code: "unavailable", message: "Move to Cloud works on a chat tab." },
  // CloudStartChat: a CloudMove.Failure with `retry` (the machine didn't connect, a copy timed out).
  {
    id: "cloud_start_failed.retryable",
    code: "cloud_start_failed",
    message: "Couldn't copy paint to paint-dev: the machine stopped answering.",
    retryable: true,
    from: "copying",
  },
  // CloudStartChat: any other error (CloudMoveStrings.moveFailed).
  {
    id: "cloud_start_failed.other",
    code: "cloud_start_failed",
    message:
      "Couldn't move the chat. Try again; if it keeps failing, run `cmux cloud diagnostics`. Reason: the machine stopped answering",
    from: "copying",
  },
  {
    id: "cloud_start_failed.setup",
    code: "cloud_start_failed",
    message: "The setup script failed.",
    from: "checklist-setup-running",
  },
  {
    id: "cloud_start_failed.harness",
    code: "cloud_start_failed",
    message: "Claude Code did not start on paint-dev.",
    from: "checklist-harness",
  },
  // CloudStartChat: a Pro refusal keeps its own code (CloudStartView's Upgrade, This Mac, Not now).
  { id: "cloud_plan_required", code: "cloud_plan_required", message: "Cloud machines need a Pro plan." },
  // The same refusal in a team that is not the person's own (CloudStartChat `teams`): "This team has no Cloud plan".
  {
    id: "cloud_plan_required.team",
    code: "cloud_plan_required",
    message: "Cloud machines need a Pro plan.",
    details: {
      team: "t-cmux",
      teams: [
        { id: "team_0123456789abcdef0123", name: "Personal" },
        { id: "t-cmux", name: "cmux" },
      ],
      canSwitch: true,
    },
  },
  // CloudStartChat: a create the team's spending cap or the member's budget refused (cmux-platform SpendCap.ts),
  // in the backend's words; the pane words it itself (cloudStartProgress `spendRefusal`) with Run on This Mac.
  {
    id: "cloud_spend_cap",
    code: "cloud_start_failed",
    message: "this team has spent 503.10 USD of its 500.00 USD spending cap; an admin can raise it",
  },
  {
    id: "cloud_member_budget",
    code: "cloud_start_failed",
    message: "you have spent 50.20 USD of your 50.00 USD monthly budget; a team admin can raise it",
  },
  // The pane's own refusals (cloudStartProgress.ts REFUSED_HERE and `transport.*`), worded by cloudRefusalText.
  { id: "cloud_attachments", code: "cloud_attachments", message: "Attachments can't go to a Cloud machine yet." },
  { id: "unsupported", code: "unsupported" },
  { id: "unavailable_now", code: "unavailable_now" },
  { id: "sandbox_busy", code: "sandbox_busy" },
  { id: "sandbox_spent", code: "sandbox_spent" },
  { id: "cloud_folder_missing", code: "cloud_folder_missing" },
  { id: "cloud_folder_home", code: "cloud_folder_home" },
  { id: "cloud_folder_secret", code: "cloud_folder_secret", message: "~/.ssh" },
  { id: "transport.path_outside_roots", code: "transport.path_outside_roots" },
  { id: "transport.gesture_required", code: "transport.gesture_required" },
];

function hostFailure(answer: HostAnswer): CloudStartProgress {
  const from = galleryStart(answer.from ?? "machine");
  const ended = cloudStartEnded(from, from.key, {
    ok: false,
    code: answer.code,
    ...(answer.message !== undefined ? { message: answer.message } : {}),
    ...(answer.retryable ? { retryable: true } : {}),
    ...(answer.details !== undefined ? { details: answer.details } : {}),
  } as Parameters<typeof cloudStartEnded>[2]);
  if (!ended) throw new Error(`cloudStartEnded dropped ${answer.id}`);
  return ended;
}

const CLOUD_START_ERRORS: ErgoState[] = HOST_ANSWERS.map((answer) => ({
  id: `cloud-start.${answer.id}`,
  type: "error",
  surface: "cloud-start",
  region:
    ".acpmux-cloud-start__failure, .acpmux-cloud-ask__actions, .acpmux-cloud-start__card, .acpmux-cloud-plan-team",
  render: (record) => <CloudStartView start={hostFailure(answer)} {...cloudStartHandlers(record)} />,
}));

/// Every gallery start that is on its way, as App draws it: the quiet line (App passes no `showSteps`).
const CLOUD_START_WAITS: ErgoState[] = Object.entries(startVariants)
  .filter(([, variant]) => variant.props.start.state === "starting")
  .map(([name, variant]) => ({
    id: `cloud-start-wait.${name}`,
    type: "wait",
    surface: "cloud-start",
    region: ".acpmux-cloud-start",
    render: (record) => <CloudStartView start={variant.props.start} {...cloudStartHandlers(record)} />,
  }));

// ---- A failed turn on a Cloud chat (TurnRows.tsx TurnFailure), with App.tsx's turn actions ----

const PROMPT = "Run the sidebar tests and fix what fails";
const CLOUD_ROUTE: FailureRoute = { harness: "claude", name: "Claude Code", hostKind: "cloud" };

function cloudSignIn(record: Recorder): CloudSignIn {
  return {
    agent: "claude",
    start: inPlace(record, "start the agent's sign-in on the machine"),
    open: () => record({ kind: "out-of-app", what: "open the sign-in page" }),
    openOnMachine: () => NEVER,
    finish: () => NEVER,
    apiKey: inPlace(record, "save an API key on the machine"),
    gateway: inPlace(record, "run the agent on cmux's gateway"),
    cancel: () => {},
    reserve: () => Promise.resolve(undefined),
    resend: () => NEVER,
  };
}

/// What App.tsx's `turnActions` holds for a connected Cloud chat on the person's own machine whose acpmux
/// retries turns and signs agents in (`agent_login`), whose agent lists /compact, with credential setup on.
function cloudChatActions(record: Recorder, route: FailureRoute): TurnActions {
  return {
    retry: inPlace(record, "send the prompt again"),
    retryFailed: inPlace(record, "retry the turn"),
    resume: inPlace(record, "continue the turn"),
    compact: inPlace(record, "compact the chat"),
    transferCloudCredentials: inPlace(record, "set up credentials on the machine"),
    cloudSignIn: cloudSignIn(record),
    switchModel: () => record({ kind: "in-place", what: "open the model picker" }),
    access: { addCredits: () => record({ kind: "out-of-app", what: "add credits" }) },
    route,
  };
}

type TurnFailureFixture = { id: string; kind: FailureKind; error: string; code?: string; teamMachine?: true };

/// One per kind (failureCopy.ts `FailureKind`; KINDS below makes a new kind fail typecheck until it has one).
const TURN_FAILURES: readonly TurnFailureFixture[] = [
  {
    id: "trust-pending",
    kind: "trust-pending",
    error: "trust.pending: answer the trust question for the folder first",
  },
  { id: "trust-untrusted", kind: "trust-untrusted", error: "trust.untrusted: the folder is not trusted" },
  {
    id: "no-team-account",
    kind: "no-team-account",
    error: "Codex needs a team account on this machine: run cr add codex to add one",
  },
  {
    id: "needs-credits",
    kind: "needs-credits",
    error: "AI models need cmux credits, your own API key, or a paid plan",
  },
  {
    id: "team-cap",
    kind: "team-cap",
    error:
      'API Error: 402 {"error":{"code":"team.cap_reached","message":"Your team reached its spending cap for this billing period. A team admin can raise it.","type":"insufficient_quota"}}',
  },
  {
    id: "no-credit",
    kind: "no-credit",
    error:
      "Your credit balance is too low to access the API. Please go to Plans & Billing to upgrade or purchase credits.",
  },
  {
    id: "cloud-auth-expired",
    kind: "cloud-auth-expired",
    error: "Error loading SSO Token: The SSO session associated with this profile has expired or is otherwise invalid.",
  },
  { id: "rate-limited", kind: "rate-limited", error: "API Error: 529 overloaded_error" },
  { id: "unreachable", kind: "unreachable", error: "API Error: Connection error." },
  { id: "invalid-key", kind: "invalid-key", error: "invalid x-api-key" },
  { id: "subscription-login", kind: "subscription-login", error: "Not logged in · Please run /login" },
  { id: "auth", kind: "auth", error: "401 Unauthorized: stream disconnected" },
  {
    id: "auth-team-machine",
    kind: "subscription-login",
    error: "Not logged in · Please run /login",
    teamMachine: true,
  },
  {
    id: "disk-full",
    kind: "disk-full",
    error:
      "agent process closed\nstderr: Error: ENOSPC: no space left on device, write '/root/.claude/projects/x.jsonl'",
  },
  {
    id: "context-full",
    kind: "context-full",
    error:
      'API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 212043 tokens > 200000 maximum"}}',
  },
  {
    id: "codex-config",
    kind: "codex-config",
    error: "failed to load workspace requirements: invalid input parameter",
  },
  {
    id: "tailscale",
    kind: "tailscale",
    error: "peer build-box unreachable: dial tcp build-box.tail0e5a.ts.net:4717: i/o timeout",
  },
  { id: "agent-exited", kind: "agent-exited", error: "agent process closed" },
  { id: "spawn-failed", kind: "spawn-failed", error: "failed to spawn agent: spawn claude-code-acp ENOENT" },
  {
    id: "other",
    kind: "other",
    error: "RpcError(-32603): internal error: unexpected end of frame (state=Streaming, seq=4417)",
  },
  // turnErrorCard.gallery's Cloud login rows (an owner machine with no, an expired, a refused Claude login).
  { id: "cloud-login-missing", kind: "auth", error: "Claude failed to authenticate: credential is missing" },
  { id: "cloud-login-expired", kind: "subscription-login", error: "OAuth token expired (HTTP 401)" },
  { id: "cloud-login-rejected", kind: "auth", error: "HTTP 403 Forbidden" },
  // The card's three ways in: the machine's team has cmux's gateway (acpmux names it).
  {
    id: "cloud-login-gateway",
    kind: "subscription-login",
    error:
      "Claude is not signed in here. Click Set up Claude Code credentials on this message to sign it in from your Mac; the message is sent again. Or click Use cmux's gateway: this machine's team has an account there. (Claude said: Not logged in · Please run /login)",
  },
];

/// Every failure kind, so a kind added to failureCopy.ts is a typecheck error here until it has a fixture.
export const KINDS: { [kind in FailureKind]: true } = {
  "trust-pending": true,
  "trust-untrusted": true,
  "no-team-account": true,
  "needs-credits": true,
  "team-cap": true,
  "no-credit": true,
  "cloud-auth-expired": true,
  "rate-limited": true,
  unreachable: true,
  "invalid-key": true,
  "subscription-login": true,
  "proxy-auth": true,
  auth: true,
  "disk-full": true,
  "context-full": true,
  "codex-config": true,
  tailscale: true,
  "agent-exited": true,
  "spawn-failed": true,
  other: true,
};
/// Kinds a Cloud chat cannot fail with: a proxy (`claude-sr`, `claude-cr`) is never a Cloud machine's route.
export const NOT_ON_CLOUD: ReadonlySet<FailureKind> = new Set(["proxy-auth"]);

export function turnFailureRoute(fixture: Pick<TurnFailureFixture, "teamMachine">): FailureRoute {
  return fixture.teamMachine ? { ...CLOUD_ROUTE, teamMachine: true } : CLOUD_ROUTE;
}

const TURN_FAILURE_STATES: ErgoState[] = TURN_FAILURES.map((fixture) => {
  const route = turnFailureRoute(fixture);
  const row = summary(1, {
    id: `failed-${fixture.id}`,
    status: "failed",
    error: fixture.error,
    ...(fixture.code ? { errorCode: fixture.code } : {}),
    prompt: PROMPT,
    retryRowId: "prompt-1",
    retryable: true,
  });
  return {
    id: `turn-failure.${fixture.id}`,
    type: "error",
    surface: "turn-failure",
    kind: fixture.kind,
    // The card, and the footer's Set up credentials beside it. Not the footer's Retry icon, which every failed
    // turn draws whatever its cause: it is not a way out the error names.
    region: ".cv-turn-error, .cv-turn-actions .cv-turn-auth-action",
    render: (record) => (
      <TurnActionsContext.Provider value={cloudChatActions(record, route)}>
        <TurnFooter row={row} />
      </TurnActionsContext.Provider>
    ),
  };
});

export const TURN_FAILURE_FIXTURES = TURN_FAILURES;

// ---- A repository the machine cannot reach (RepoRecoveryCard under a failed tool row) ----

type RecoveryProps = { recovery: Parameters<typeof RepoRecoveryCard>[0]["recovery"]; outcomes?: boolean };
const REPO_RECOVERY: ErgoState[] = Object.entries(
  repoRecoveryGallery.variants as { [name: string]: { props: RecoveryProps } },
)
  // `outcomes` draws the card's later lines beside it for the gallery: not a state of its own.
  .filter(([, variant]) => !variant.props.outcomes)
  .map(([name, variant]) => ({
    id: `repo-recovery.${name}`,
    type: "error",
    surface: "repo-recovery",
    region: ".cv-repo-recovery",
    render: () => <RepoRecoveryCard recovery={variant.props.recovery} />,
  }));

export function cloudErgonomicsStates(): ErgoState[] {
  return [...CLOUD_START_ERRORS, ...TURN_FAILURE_STATES, ...REPO_RECOVERY, ...CLOUD_START_WAITS];
}

/// What this measurement does not reach yet, said in the report so a zero is never read as "none".
export const UNCOVERED: readonly { surface: string; why: string }[] = [
  {
    surface: "CloudSignIn step failures (bad code, expired, busy, CLI missing, shared machine)",
    why: "drawn only after clicks through the sign-in card; not driven yet",
  },
  {
    surface: "RepoRecoveryCard after a click (Connecting GitHub, Couldn't recover)",
    why: "drawn only after a click; not driven yet",
  },
  { surface: "CloudStartAsk (first login, login copy, Codex device code)", why: "asks, not errors; not counted" },
  { surface: "HarnessHealthNotice, failed prompt delivery on a Cloud chat", why: "not in the catalog yet" },
  { surface: "Cloud move, resume and desktop progress", why: "not in the catalog yet" },
  {
    surface: "start-to-working-chat steps",
    why: "the pane's in-page mock serves no Cloud start, so steps are not measured on Linux",
  },
];
