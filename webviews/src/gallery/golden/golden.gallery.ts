// l10n-allow-file: gallery fixtures (sample prompts, replies, paths and code), not shipped UI.
// The golden screen (Leo, 2026-11-18: "and also probably be able to see/visualize a "golden" example"):
// one chat that holds every part a look changes, drawn under each look (looks.json) so looks compare
// side by side. A prompt bubble; a reply with headings, a list, inline code, a code block and a link;
// tool rows done, failed and running; the edited-files card; a permission prompt with its diff; the
// composer with its model, effort and access chips and a draft. In the mock app (mock-app.html, which
// `bun run golden:looks` captures) the window around it adds the sidebar's two projects with a
// selected, an unread, a working, a waiting and a failed chat, and a tab strip of four tabs.
// Each variant is one look; the stage's light or dark scheme picks the look's theme file.
import looks from "virtual:cmux-gallery/looks";
import { agentPaneEntry, type AgentPaneVariant } from "../format";
import type { Play } from "../play";
import { minutesAgo } from "../clock";
import { activity, assistant, chat, session, SESSION_ID, summary, tool, user } from "../fixtures/acpmux";

const ATLAS = "/Users/you/src/atlas-web";
const BILLING = "/Users/you/src/billing-api";

const RETRY_BEFORE = `export async function fetchJSON(url: string, init?: RequestInit) {
  const response = await fetch(url, init);
  if (!response.ok) throw new HttpError(response);
  return response.json();
}
`;
const RETRY_AFTER = `export async function fetchJSON(url: string, init?: RequestInit, policy?: RetryPolicy) {
  const retry = policy ?? (isIdempotent(init?.method) ? DEFAULT_RETRY_POLICY : NO_RETRY);
  return withRetry(async () => {
    const response = await fetch(url, init);
    if (!response.ok) throw new HttpError(response);
    return response.json();
  }, retry);
}
`;
const POLICY = `export const DEFAULT_RETRY_POLICY = { attempts: 5, baseDelayMs: 200, maxDelayMs: 8_000 };
export const NO_RETRY = { attempts: 1, baseDelayMs: 0, maxDelayMs: 0 };
`;
const DOCS_BEFORE = `## Errors

\`fetchJSON\` throws an \`HttpError\` for any status outside 200-299.
`;
const DOCS_AFTER = `## Errors and retries

\`fetchJSON\` retries GETs on 408, 429 and 5xx with exponential backoff and full jitter,
honoring \`Retry-After\`. POSTs retry only with an explicit \`policy\`.
Each retry logs \`retrying GET /sync after 412 ms (attempt 2 of 5)\`.
`;

const REPLY = [
  "## Retries for the fetch helper",
  "",
  "The helper now retries transient failures with exponential backoff and full jitter, so a burst of `429`s from the billing API no longer fails the whole sync.",
  "",
  "- **GETs** retry `408`, `429` and gateway `5xx` errors, honoring `Retry-After`.",
  "- **POSTs** retry only when the caller passes `retry: { attempts: 5 }`.",
  "- The first test run failed on a fake timer that never advanced; `retry.test.ts` now ticks it.",
  "",
  "### The policy",
  "",
  "```ts",
  "export async function withRetry<T>(run: (attempt: number) => Promise<T>, policy = DEFAULT_RETRY_POLICY): Promise<T> {",
  "  for (let attempt = 1; ; attempt += 1) {",
  "    try {",
  "      return await run(attempt);",
  "    } catch (error) {",
  "      if (attempt >= policy.attempts || !isTransient(error)) throw error;",
  "      await sleep(Math.min(policy.maxDelayMs, policy.baseDelayMs * 2 ** (attempt - 1)) * Math.random());",
  "    }",
  "  }",
  "}",
  "```",
  "",
  "`Retry-After` is read as [RFC 9110 defines it](https://www.rfc-editor.org/rfc/rfc9110#field.retry-after): seconds or an HTTP date.",
].join("\n");

const rows = chat(
  [
    user(
      "The nightly sync keeps failing on 429s from the billing API. Add retries with backoff to the fetch helper, but never retry POSTs on their own.",
      14,
    ),
    activity(
      [
        tool("Read src/net/client.ts", "read", "completed", { locations: [{ path: `${ATLAS}/src/net/client.ts` }] }),
        tool("Search for fetchJSON(", "search", "completed"),
      ],
      13.8,
    ),
    assistant("The existing retry test hangs; running the suite first to see it fail.", 13.7, {
      assistantPhase: "commentary",
    }),
    // A lone call: its failure reads on its own line (a group's steps read plain).
    activity(
      [
        tool("bun test src/net", "execute", "failed", {
          command: "bun test src/net",
          output:
            "retry.test.ts:\n✗ waits between attempts [5002ms]\n  timed out: the fake timer never advanced\n\n40 pass\n1 fail",
          exitCode: 1,
          startedAt: minutesAgo(12.6),
          endedAt: minutesAgo(12.5),
        }),
      ],
      13.6,
    ),
    activity(
      [
        tool("Edit src/net/client.ts", "edit", "completed", {
          diffs: [{ path: "src/net/client.ts", oldText: RETRY_BEFORE, newText: RETRY_AFTER }],
        }),
        tool("Edit src/net/retry.ts", "edit", "completed", { diffs: [{ path: "src/net/retry.ts", newText: POLICY }] }),
        tool("Edit test/net/retry.test.ts", "edit", "completed", {
          diffs: [
            {
              path: "test/net/retry.test.ts",
              oldText: "await withRetry(run);\n",
              newText: "const done = withRetry(run);\nawait clock.tickAsync(8_000);\nawait done;\n",
            },
          ],
        }),
        tool("bun test src/net", "execute", "completed", {
          command: "bun test src/net",
          output: "41 pass\n0 fail\nRan 41 tests across 6 files. [1.84s]",
          exitCode: 0,
          startedAt: minutesAgo(12.1),
          endedAt: minutesAgo(12),
        }),
      ],
      13.5,
    ),
    assistant(REPLY, 11.8),
    summary(11.8, { status: "completed", durationMs: 132_000, toolCount: 7 }),
    user("Great. Log each retry with its attempt number, and update the networking docs.", 1.5),
    activity(
      [tool("Read docs/networking.md", "read", "completed", { locations: [{ path: `${ATLAS}/docs/networking.md` }] })],
      1.2,
    ),
    assistant("Lint runs while the docs change waits for you.", 0.5, { assistantPhase: "commentary" }),
    activity(
      [
        tool("bun run lint", "execute", "in_progress", {
          command: "bun run lint",
          output: "Checking 214 files…",
          startedAt: minutesAgo(0.4),
        }),
      ],
      0.45,
    ),
  ],
  {
    title: "Add retries to the fetch helper",
    isWorking: true,
    permission: {
      permissionId: "golden-docs-edit",
      title: "Edit docs/networking.md",
      kind: "edit",
      pending: true,
      diffs: [{ path: "docs/networking.md", oldText: DOCS_BEFORE, newText: DOCS_AFTER }],
      options: [
        { id: "allow_once", name: "Allow", kind: "allow_once", allow: true },
        { id: "allow_always", name: "Always allow edits", kind: "allow_always", allow: true },
        { id: "reject_once", name: "Reject", kind: "reject_once", allow: false },
      ],
    },
    sessions: [
      session({
        sessionId: SESSION_ID,
        title: "Add retries to the fetch helper",
        cwd: ATLAS,
        status: "running",
        pendingPermissions: 1,
        updatedAt: minutesAgo(0.4),
      }),
      session({
        sessionId: "golden-flaky",
        title: "Fix the flaky sidebar drag test",
        cwd: ATLAS,
        status: "running",
        indicator: "working",
        updatedAt: minutesAgo(3),
      }),
      session({
        sessionId: "golden-notes",
        title: "Draft the release notes for 0.42",
        cwd: ATLAS,
        unread: true,
        updatedAt: minutesAgo(26),
      }),
      session({
        sessionId: "golden-scroll",
        title: "Profile the transcript scroll jank",
        cwd: ATLAS,
        updatedAt: minutesAgo(60 * 5),
      }),
      session({
        sessionId: "golden-webhooks",
        title: "Review the billing webhook retries",
        cwd: BILLING,
        unread: true,
        updatedAt: minutesAgo(48),
      }),
      session({
        sessionId: "golden-migrate",
        title: "Migrate invoices to the new ledger",
        cwd: BILLING,
        indicator: "failed",
        updatedAt: minutesAgo(60 * 3),
      }),
      session({
        sessionId: "golden-cache",
        title: "Why does the build cache miss on CI?",
        cwd: BILLING,
        updatedAt: minutesAgo(60 * 26),
      }),
    ],
  },
);

const effort = {
  id: "effort",
  name: "Reasoning",
  category: "thought_level",
  currentValue: "high",
  options: [
    { value: "low", name: "Low" },
    { value: "medium", name: "Medium" },
    { value: "high", name: "High" },
  ],
};
const modes = {
  currentModeId: "auto",
  availableModes: [
    { id: "ask", name: "Supervised", description: "Ask before changing files or running commands" },
    { id: "auto", name: "Auto", description: "Choose the safest approval level for each action" },
    { id: "bypassPermissions", name: "Bypass permissions", description: "Run actions without approval" },
  ],
};
const snapshot = { ...rows, summary: { ...rows.summary!, configOptions: [effort], modes } };

/** Every fold open (the turn's "Worked for", each tool group; not each edit's diff), so each tool row shows: done, failed
 * and running. Then the chat's top, so the first prompt leads (the capture grows the window to the end). */
const CLOSED = 'button.cv-worked[aria-expanded="false"], button.cv-tool.is-run[aria-expanded="false"]';
const openFolds: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-user__bubble"));
  await ctx.scroll({ selector: ".acpmux-scroll" }, "top");
  // Opening a turn's fold shows its closed tool groups: open each closed one by name until none is left.
  for (let round = 0; round < 12; round += 1) {
    const next = ctx.document.querySelector<HTMLElement>(CLOSED);
    if (!next) break;
    next.dataset.goldenFold = String(round);
    const named = `[data-golden-fold="${round}"]`;
    await ctx.click({ selector: named });
    await ctx.waitFor(() => ctx.document.querySelector(named)?.getAttribute("aria-expanded") !== "false");
  }
  await ctx.scroll({ selector: ".acpmux-scroll" }, "top");
};

const golden = (look: (typeof looks.looks)[number]): AgentPaneVariant => ({
  note: `${look.title}: ${look.note} (${look.source})`,
  look,
  snapshot,
  ready: { draft: "Also add a test that a POST without a policy never retries" },
  play: openFolds,
  windowTabs: ["Review the billing webhook retries", "zsh: ~/src/atlas-web", "networking.md"],
});

export default agentPaneEntry({
  id: "looks.golden",
  title: "Golden screen (every look)",
  area: "Agent pane",
  height: 1100,
  covers: ["agent-session/acpmux/App.tsx", "gallery/golden/look.ts"],
  variants: Object.fromEntries(looks.looks.map((look) => [look.id, golden(look)])),
});
