// l10n-allow-file: debug fixture prompts, thoughts, commands and replies, not shipped UI.
// A turn organized as Claude Code desktop draws one, for `debug.agent_pane seed_rows` with
// `fixture: "organization"`, so a capture shows it in the real app (Leo, 2026-10-29: "we want to
// have that capabilitiy of rendering like claude code desktop has stuff organized."): a paragraph,
// a question asked and answered (the answered QuestionCard), a checklist of three steps, then a
// thought and five shell steps under "Ran 5 commands", and the prose after them. The same turn as
// the gallery's `agent-pane.claude-desktop-organization`; every name and path in it is made up.
import type { AcpmuxActivity, AcpmuxPlanEntry, AcpmuxRow } from "./model";
import type { AgentQuestion } from "./question/model";
import { QUESTION_RECORD } from "./question/record";

const SECOND = 1_000;

/// An answered question, as the shared CmuxAgentQuestion `answered-collapsed.json` fixture holds it
/// (copied, not imported: a shipped bundle imports nothing from outside webviews/ for a debug seed).
const ANSWERED: AgentQuestion = {
  id: "perm_toolu_single",
  source: {
    harness: "claude",
    session: "sess_claude_1",
    permission: "perm_toolu_single",
    agentName: "Claude Code",
    answerOption: "allow_once",
    rejectOption: "reject_once",
    toolCall: "toolu_single",
  },
  items: [
    {
      id: "q0",
      header: "Auth method",
      prompt: "Which auth method should the API use?",
      options: [
        {
          id: "OAuth 2.0",
          label: "OAuth 2.0",
          detail: "Delegated sign-in through the identity provider; best for third-party clients.",
        },
        {
          id: "API keys",
          label: "API keys",
          detail: "One static key per integration. Simple, but keys must be rotated by hand.",
        },
        {
          id: "Passkeys",
          label: "Passkeys",
          detail: "WebAuthn credentials bound to the device. No shared secret on the server.",
        },
      ],
      multiSelect: false,
      allowsOther: true,
    },
  ],
  state: {
    kind: "answered",
    answer: {
      selections: { q0: { optionIDs: ["Passkeys"] } },
      respondent: { participant: "user_local", displayName: "Lawrence", device: "MacBook Pro", isRemote: false },
      answeredAtMs: 1791331200000,
    },
  },
};

const LEAD =
  "The fetch helper retries every failure the same way, so a 404 waits through three backoffs before it fails. " +
  "I should read how the helper decides to retry, find who calls it, and check whether the tests already cover a client error.\n\n" +
  "If the retry loop has no status check, the fix belongs there rather than in each caller.";

const todo = (content: string, status: AcpmuxPlanEntry["status"]): AcpmuxPlanEntry => ({ content, status });

export function organizationRows(at: number): AcpmuxRow[] {
  /// A finished shell step with Claude's Bash description, its command and what it printed.
  const step = (n: number, description: string, command: string, output: string): AcpmuxActivity => ({
    kind: "tool",
    text: command,
    tool: {
      id: `organization-step-${n}`,
      title: command,
      kind: "execute",
      status: "completed",
      description,
      command,
      output,
      exitCode: 0,
      startedAt: at + (20 + n * 4) * SECOND,
      endedAt: at + (21 + n * 4) * SECOND,
    },
  });
  const thought = (text: string, start: number, seconds: number): AcpmuxActivity => ({
    kind: "thought",
    text,
    startedAt: at + start * SECOND,
    endedAt: at + (start + seconds) * SECOND,
  });
  return [
    {
      id: "organization-user",
      version: 1,
      at,
      kind: "user",
      text: "Make the fetch helper stop retrying client errors",
    },
    {
      id: "organization-intro",
      version: 1,
      at: at + 2 * SECOND,
      kind: "assistant",
      text:
        "The helper lives in `src/net/fetchWithRetry.ts` and every network call in the app goes through it. " +
        "Before I change how it retries, one question about authentication, since the retry rules differ for it.",
    },
    {
      id: "organization-question",
      version: 1,
      at: at + 4 * SECOND,
      kind: QUESTION_RECORD,
      question: ANSWERED,
    },
    {
      id: "organization-plan",
      version: 1,
      at: at + 10 * SECOND,
      kind: "plan",
      plan: [
        todo("Find where the helper decides to retry", "completed"),
        todo("Stop retrying 4xx responses", "in_progress"),
        todo("Cover it with a test", "pending"),
      ],
    },
    {
      id: "organization-run",
      version: 1,
      at: at + 12 * SECOND,
      kind: "activity",
      toolCount: 5,
      items: [
        thought(LEAD, 12, 6),
        step(
          1,
          "Found the retry loop and its status check",
          "rg -n 'retry' src/net/fetchWithRetry.ts",
          "12:export async function fetchWithRetry(url, options = {}) {\n18:  for (let attempt = 0; attempt < retries; attempt++) {\n24:    if (!response.ok) await delay(backoff(attempt));\n",
        ),
        step(
          2,
          "Listed every caller of fetchWithRetry",
          "rg -l fetchWithRetry src",
          "src/net/fetchWithRetry.ts\nsrc/api/orders.ts\nsrc/api/profile.ts\nsrc/api/search.ts\n",
        ),
        thought(
          "None of the callers handle a 404 themselves, so a client error waiting through every backoff is what the reader sees as a slow page. The check belongs in the loop.",
          30,
          3,
        ),
        step(
          3,
          "Read the retry tests",
          "sed -n '1,60p' src/net/fetchWithRetry.test.ts",
          "describe('fetchWithRetry', () => {\n  it('retries a 503 three times', async () => {\n",
        ),
        step(4, "Ran the retry tests before the change", "bun test src/net", "3 pass\n0 fail\n"),
        step(5, "Checked the branch is clean", "git status --short", ""),
      ],
    },
    {
      id: "organization-reply",
      version: 1,
      at: at + 44 * SECOND,
      kind: "assistant",
      text: "The loop retries any response that isn't ok. I'll stop it at 4xx statuses other than 408 and 429, which are worth another try, then add a test for a 404.",
    },
    {
      id: "organization-summary",
      version: 1,
      at: at + 46 * SECOND,
      kind: "turnSummary",
      durationMs: 46_000,
      toolCount: 5,
    },
  ] as AcpmuxRow[];
}
