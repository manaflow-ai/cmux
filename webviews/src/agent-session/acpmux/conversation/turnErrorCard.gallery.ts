// l10n-allow-file: gallery fixtures (sample prompts and agent errors), not shipped UI.
// A failed turn's error card (TurnRows.tsx TurnFailure; Leo 2026-10-22: "we need to have prettier
// errors" and "we also wanna make sure we have good recoverable/informative disk errors tailscale
// erros for acpmux"): the cause in one human line, the way out first, the agent's own words under
// Details with Copy. Compare arms shows the three surfaces of the `turn-error-card` experiment.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, CATALOG, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { turnErrorCard } from "./turnErrorCard.experiment";

const prompt = "Run the sidebar tests and fix what fails";

const failed = (error: string, errorCode?: string, fields: Parameters<typeof chat>[1] = {}) =>
  chat(
    [
      user(prompt, 6),
      assistant("Running the sidebar tests first.", 5.8),
      summary(5.5, { status: "failed", durationMs: 662_000, error, ...(errorCode ? { errorCode } : {}) }),
    ],
    fields,
  );

/// Claude Code's own /compact, as its `available_commands_update` lists it.
const compactCommand = { name: "compact", description: "Clear conversation history but keep a summary in context" };
const contextFull =
  'API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 212043 tokens > 200000 maximum"}}';

const cloudFailed = (error: string) => {
  const snapshot = chat([
    user(prompt, 6, { id: "cloud-request" }),
    summary(5.5, { status: "failed", error, prompt, retryRowId: "cloud-request" }),
  ]);
  if (snapshot.summary) {
    delete snapshot.summary.host;
    delete snapshot.summary.hostKind;
  }
  return snapshot;
};

/// The harnesses' logins as the catalog names them, so the chat has a login to run (Sign in again).
const LOGINS: Record<string, string> = { claude: "claude /login", codex: "codex login" };
const signedOutCatalog = CATALOG.map((entry) =>
  LOGINS[entry.id] ? { ...entry, auth: { login: LOGINS[entry.id]! } } : entry,
);
const notLoggedIn = "Not logged in · Please run /login";
const signedOut = (fields: Parameters<typeof chat>[1] = {}) =>
  failed(notLoggedIn, undefined, { catalog: signedOutCatalog, ...fields });

export default agentPaneEntry({
  id: "agent-pane.turn-error-card",
  title: "Turn error card",
  area: "Agent pane",
  height: 300,
  covers: ["agent-session/acpmux/conversation/TurnRows.tsx#TurnFooter", "agent-session/acpmux/failureCopy.ts"],
  keywords: ["error", "failure", "disk full", "tailscale", "agent process closed", "context window", "compact"],
  variants: {
    "cloud-missing": {
      note: "Owner VM without a Claude login: explains the missing credential and offers confirmed setup. Compare the three existing surfaces; keep the glass card.",
      ready: { cloudMachineID: "gallery-vm", cloudCredentialRecoveryAvailable: true },
      snapshot: cloudFailed("Claude failed to authenticate: credential is missing"),
    },
    "cloud-expired": {
      note: "Expired login: the cause and the same setup action, with no provider output in the sentence.",
      ready: { cloudMachineID: "gallery-vm", cloudCredentialRecoveryAvailable: true },
      snapshot: cloudFailed("OAuth token expired (HTTP 401)"),
    },
    "cloud-rejected": {
      note: "Rejected login: preserves the HTTP status and offers setup on this Cloud machine.",
      ready: { cloudMachineID: "gallery-vm", cloudCredentialRecoveryAvailable: true },
      snapshot: cloudFailed("HTTP 403 Forbidden"),
    },
    "agent-closed": {
      note: 'Leo\'s screenshot: "agent process closed" reads as the agent quitting, with Retry and the raw words under Details.',
      snapshot: failed("agent process closed"),
    },
    "disk-full": {
      note: "A full disk names the disk and what to do, not the write that failed.",
      snapshot: failed(
        "agent process closed\nstderr: Error: ENOSPC: no space left on device, write '/Users/me/.claude/projects/x.jsonl'",
      ),
    },
    tailscale: {
      note: "A chat on another machine that the tailnet no longer reaches.",
      snapshot: failed("peer build-box unreachable: dial tcp build-box.tail0e5a.ts.net:4717: i/o timeout"),
    },
    typed: {
      note: "acpmux's typed reason (`errorCode`) wins over the words: a disk error whose text says only that it could not write.",
      snapshot: failed("could not write the session journal", "disk.full"),
    },
    "spawn-failed": {
      note: "The agent's command is missing.",
      snapshot: failed("failed to spawn agent: spawn claude-code-acp ENOENT"),
    },
    "rate-limited": {
      note: "Capacity after the turn did work (Lawrence 2026-10-29): Continue leads and resumes the turn with its context (Return on the focused card), Switch model beside it.",
      snapshot: failed("API Error: 529 overloaded_error"),
    },
    "rate-limited-before-work": {
      note: "Capacity before anything ran: Retry leads and sends the prompt again, Switch model beside it.",
      snapshot: chat([
        user(prompt, 6),
        summary(5.9, { status: "failed", durationMs: 4_000, error: "API Error: 529 overloaded_error" }),
      ]),
    },
    "context-full": {
      note: "A long chat that outgrew the model's context window: Compact (the agent's /compact) first, Retry after it. Before, it read as an unknown failure whose Retry failed the same way.",
      snapshot: failed(contextFull, undefined, { commands: [compactCommand] }),
    },
    "context-full-no-compact": {
      note: "The same failure from an agent that lists no /compact: Retry stays the way out.",
      snapshot: failed(contextFull),
    },
    "sign-in": {
      note: "Claude Code's login expired mid-chat: Sign in again leads (filled) and runs the login, Continue follows for once it is done, then Switch model.",
      snapshot: signedOut(),
    },
    "sign-in-cannot-send": {
      note: "The same expired login in a chat this pane cannot send to (a Codex chat seen over a remote connection): Sign in again leads, Switch model after it, and no Continue or Retry.",
      snapshot: signedOut({ harness: "codex", model: "gpt-6-astra", origin: "remote" }),
    },
    unknown: {
      note: "An error nothing names still reads human; its words are under Details.",
      snapshot: failed("RpcError(-32603): internal error: unexpected end of frame (state=Streaming, seq=4417)"),
    },
    details: {
      note: "Details open: the agent's own words and Copy error.",
      snapshot: failed("agent process closed"),
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-turn-error__details summary" });
      },
    },
  },
  experiment: {
    definition: turnErrorCard,
    script: [
      {
        name: "open Details",
        run: async (ctx) => {
          await ctx.click({ selector: ".cv-turn-error__details summary" });
        },
      },
    ],
  },
});
