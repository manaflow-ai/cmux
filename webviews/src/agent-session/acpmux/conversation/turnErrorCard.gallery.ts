// l10n-allow-file: gallery fixtures (sample prompts and agent errors), not shipped UI.
// A failed turn's error card (TurnRows.tsx TurnFailure; Leo 2026-10-22: "we need to have prettier
// errors" and "we also wanna make sure we have good recoverable/informative disk errors tailscale
// erros for acpmux"): the cause in one human line, the way out first, the agent's own words under
// Details with Copy. Compare arms shows the three surfaces of the `turn-error-card` experiment.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { turnErrorCard } from "./turnErrorCard.experiment";

const prompt = "Run the sidebar tests and fix what fails";

const failed = (error: string, errorCode?: string) =>
  chat([
    user(prompt, 6),
    assistant("Running the sidebar tests first.", 5.8),
    summary(5.5, { status: "failed", durationMs: 662_000, error, ...(errorCode ? { errorCode } : {}) }),
  ]);

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

export default agentPaneEntry({
  id: "agent-pane.turn-error-card",
  title: "Turn error card",
  area: "Agent pane",
  height: 300,
  covers: ["agent-session/acpmux/conversation/TurnRows.tsx#TurnFooter", "agent-session/acpmux/failureCopy.ts"],
  keywords: ["error", "failure", "disk full", "tailscale", "agent process closed"],
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
      note: "Capacity: Switch model is the way out, Retry beside it.",
      snapshot: failed("API Error: 529 overloaded_error"),
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
