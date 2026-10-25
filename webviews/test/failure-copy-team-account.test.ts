// Codex on a team Cloud machine whose team has no Codex account: CodeRouter answers a terminal 403
// `no_account_configured` (web/services/coderouter/noAccountMessage.ts), and Codex shows only the
// body's `error.message`. The failed turn's note said the CodeRouter host refused the request, and a
// 503 from the same machine said "rate limited ... or switch model". Neither helps: a team machine
// refuses own sign-ins, so the note now says Codex needs a team account and names the command that
// adds one. A real rate limit still reads as one.
import { expect, test } from "bun:test";
import { failureCopy, failureKind, isAuthenticationFailure } from "../src/agent-session/acpmux/failureCopy";
import { translatorFor } from "../src/agent-session/acpmux/i18n";

const t = translatorFor("en");
const codex = { name: "Codex", harness: "codex" };
const url = ", url: https://coderouter.cmux.dev/v1/responses, request id: req-1";
// The refusal as Codex prints it, from the current server and from the one before it.
const teamMachine =
  "unexpected status 403 Forbidden: Codex needs a team account on this machine. To add one for the team, run `cr add codex` in this machine's terminal. If someone added one as private, they can choose Share with team at coderouter.dev." +
  url;
const teamMachineBefore =
  "unexpected status 403 Forbidden: No Codex account is shared with this Cloud machine's team. If one was added as private, the person who added it can choose Share with team at coderouter.dev, or add one here with `cr add codex` (accounts added on a Cloud machine are shared with its team). Or use your own Codex sign-in on this machine: run `cr use own codex`, then `codex login` (on older machines, start Codex with `codex -c model_provider=openai` after `codex login`)." +
  url;

test("a team machine with no Codex account says so and names the command that adds one", () => {
  for (const message of [teamMachine, teamMachineBefore]) {
    expect(failureKind(message, codex)).toBe("no-team-account");
    expect(failureCopy(t, message, codex)).toBe(
      "Codex needs a team account on this machine. To add one for the team, run cr add codex in this machine’s terminal.",
    );
    // Not a sign-in problem: the pane offers no Sign in again.
    expect(isAuthenticationFailure(message)).toBe(false);
  }
});

test("the command follows the agent the refusal names", () => {
  const claude =
    'API Error: 403 {"type":"error","error":{"type":"permission_error","message":"Claude needs a team account on this machine. To add one for the team, run `cr add claude` in this machine\'s terminal."}}';
  expect(failureKind(claude)).toBe("no-team-account");
  expect(failureCopy(t, claude, { name: "Claude", harness: "claude" })).toContain("run cr add claude in");
});

test("a real rate limit or capacity answer still says rate limited", () => {
  const limits = [
    "exceeded retry limit, last status: 503 Service Unavailable, request id: req-2",
    "unexpected status 429 Too Many Requests: Rate limit reached for gpt-5.5" + url,
    "API Error: 429 rate_limit_error: This request would exceed your account's rate limit.",
  ];
  for (const message of limits) {
    expect(failureKind(message, codex)).toBe("rate-limited");
    expect(failureCopy(t, message, codex)).toBe(t("turn.failure.rateLimited", { harness: "Codex" }));
  }
});

test("a personal machine's no-account refusal is not the team machine's", () => {
  // A personal machine can still use the owner's own sign-in, so it keeps the route's copy.
  const personal =
    "unexpected status 403 Forbidden: No Codex account is configured for this team or shared with this caller. Add one with `cr add codex` or at coderouter.dev." +
    url;
  expect(failureKind(personal, codex)).not.toBe("no-team-account");
});
