// l10n-allow-file: gallery fixtures (sample chats, prompts and replies), not shipped UI.
// The font study's screen (candidates.ts): one chat as a person has it, with the sidebar full of
// groups and long names, a long reply with a code block, a table, a list, CJK and emoji, and the
// composer. Open it in the mock app with each pairing, dark and light:
//   mock-app.html?fixture=font-study.screen/long-chat&fontStudy=hanken-newsreader&colorScheme=light
import { agentPaneEntry } from "../format";
import { minutesAgo } from "../clock";
import { activity, assistant, chat, CWD, SESSION_ID, session, summary, thought, tool, user } from "../fixtures/acpmux";

const REPLY = `The retry test fails on CI because it used **real timers**: on a loaded runner the third attempt landed after the assertion. Locally the machine is idle, so the 800 ms backoff always finished first.

Here is what changed:

1. \`retry()\` takes a \`sleep\` it can be given, so the test passes fake timers.
2. The backoff is 200 ms, 400 ms, 800 ms, with jitter held within ±10%.
3. The webhook relay keeps its own timeout; I left it on the plain helper.

\`\`\`ts
export async function retry<T>(run: () => Promise<T>, { tries = 3, delayMs = 200, sleep = wait } = {}): Promise<T> {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await run();
    } catch (error) {
      if (attempt >= tries || !isRetryable(error)) throw error;
      await sleep(delayMs * 2 ** (attempt - 1) * (0.9 + Math.random() * 0.2));
    }
  }
}
\`\`\`

| Runner | Before | After | Runs |
| --- | --- | --- | --- |
| Local (M4 Pro) | 12/12 pass | 12/12 pass | 30 |
| CI, light load | 11/12 pass | 12/12 pass | 30 |
| CI, saturated | 7/12 pass | 12/12 pass | 30 |

All 12 tests pass three times in a row (0.4 s each) 🎉. One note for the Tokyo team: エラーメッセージは日本語のままです。中文的错误信息也保持不变。 The illegible-glyph check reads Il1|O0 rn/m cl/d the same at every size.

Next I'd add a test for a request that never recovers, so the third failure surfaces instead of hanging. Want me to do that now?`;

const TITLES: [string, string][] = [
  ["Fix the retry test that only fails on CI under load", CWD],
  ["Sidebar: group headers keep a dragged row's drop where the pointer is", CWD],
  ["Why does the WebKit capture draw the composer two pixels lower?", CWD],
  ["Release notes", CWD],
  ["Migrate the settings schema generator to the new section JSON format", "/Users/you/src/cmux-platform"],
  ["Billing: entitlements for teams with more than fifty seats", "/Users/you/src/cmux-platform"],
  ["Investigate p95 latency regression in the relay after the iroh upgrade", "/Users/you/src/cmux-platform"],
  ["Draft the onboarding email", "/Users/you/Documents/notes"],
  ["日本語のローカライズを確認する", "/Users/you/Documents/notes"],
  ["Trip planning 🏔️ Yosemite in March", "/Users/you/Documents/notes"],
];

const sessions = TITLES.map(([title, cwd], index) =>
  session({
    sessionId: index === 0 ? SESSION_ID : `font-study-${index}`,
    title,
    harness: index % 3 === 1 ? "codex" : "claude",
    model: index % 3 === 1 ? "gpt-6-astra" : "claude-opus-5-5",
    status: index === 1 ? "running" : index === 5 ? "waiting" : "idle",
    pendingPermissions: index === 5 ? 1 : 0,
    unread: index === 2 || index === 7,
    indicator: index === 1 ? "working" : index === 5 ? "input" : "done",
    updatedAt: minutesAgo(2 + index * 37),
    cwd,
    branch: index % 2 ? `feat-${index}` : "main",
    preview: "Updated the tests and the docs; all checks pass.",
  }),
);

const snapshot = chat(
  [
    user("Why does the retry test fail on CI but pass locally? It's been flaky for a week.", 12),
    activity(
      [
        thought("The assertion may run before the retry delay ends. Compare the test with the helper."),
        tool("Read src/fetch/retry.ts", "read", "completed"),
        tool("Search for sleep( in src/fetch", "search", "completed"),
        tool("bun test src/fetch/retry.test.ts", "execute", "completed", { output: "12 tests passed" }),
      ],
      11,
    ),
    assistant(REPLY, 10),
    summary(10, { status: "completed", toolCount: 3, durationMs: 94_000 }),
  ],
  { title: TITLES[0][0], branch: "fix/retry-timers", sessions },
);

export default agentPaneEntry({
  id: "font-study.screen",
  title: "Font study screen",
  area: "Agent pane",
  covers: ["gallery/fontStudy/apply.ts"],
  keywords: ["font", "typeface", "typography", "study", "serif", "sidebar"],
  variants: {
    "long-chat": {
      note: "One chat with a long reply (code, a table, CJK, emoji) and a sidebar of long names; pick a pairing with fontStudy=.",
      snapshot,
    },
  },
});
