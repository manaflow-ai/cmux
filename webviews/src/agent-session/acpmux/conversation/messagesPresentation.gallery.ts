// l10n-allow-file: synthetic gallery conversations, not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import pendingQuestion from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-single.json";
import type { AgentQuestion } from "../question/model";

const snapshot = chat([
  user("Can you check why the retry test fails?", 3),
  assistant("I'll check the helper and its test.", 2.8),
  activity(
    [
      thought("The assertion may run before the retry delay finishes. I'll compare the test with the helper."),
      tool("Read src/retry.ts", "read", "completed"),
      tool("bun test src/retry.test.ts", "execute", "completed", { output: "12 tests passed" }),
    ],
    2.5,
  ),
  assistant("The test uses real timers. **Fake timers** make the retry deterministic; all 12 tests now pass.", 2),
  summary(2, { status: "completed", toolCount: 2, durationMs: 32_000 }),
]);

async function selectMessages(ctx: PlayContext) {
  await ctx.click({ role: "button", name: "Chat actions" });
  await ctx.click({ role: "menuitem", name: "Transcript view" });
  await ctx.click({ role: "menuitemradio", name: "Messages" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-assistant-bubble"));
  if (ctx.document.querySelector(".acpmux-activity, .acpmux-worked, .acpmux-turnSummary, .cv-thought"))
    throw new Error("Messages still draws transcript work");
}

export default agentPaneEntry({
  id: "agent-pane.messages-presentation",
  title: "One session: Transcript and Messages",
  area: "Agent pane",
  height: 680,
  covers: ["agent-session/acpmux/conversation/messagesRows.ts", "agent-session/acpmux/header/presentationRow.ts"],
  variants: {
    transcript: { note: "The default transcript, with its usual disclosure choices.", snapshot },
    messages: {
      note: "Choose Messages through the real menu: left agent bubbles, right user bubbles.",
      snapshot,
      play: selectMessages,
    },
    "messages-default": {
      note: "A chat without an override follows the global Messages default.",
      snapshot,
      display: { "agentPane.display.presentation": "messages" },
    },
    "pending-question": {
      note: "The pending question stays actionable above the composer while tools are hidden.",
      snapshot: {
        ...snapshot,
        permission: {
          permissionId: pendingQuestion.id,
          pending: true,
          options: [],
          question: {
            ...pendingQuestion,
            source: { ...pendingQuestion.source, session: snapshot.sessionId! },
          } as unknown as AgentQuestion,
        },
        isWorking: true,
      },
      display: { "agentPane.display.presentation": "messages" },
    },
    "pending-permission": {
      note: "Permission decisions stay visible while the tool transcript is hidden.",
      snapshot: {
        ...snapshot,
        isWorking: true,
        permission: {
          permissionId: "messages-permission",
          title: "Run tests",
          command: "bun test src/retry.test.ts",
          kind: "execute",
          pending: true,
          options: [
            { id: "allow_once", name: "Allow", kind: "allow_once", allow: true },
            { id: "reject_once", name: "Reject", kind: "reject_once", allow: false },
          ],
        },
      },
      display: { "agentPane.display.presentation": "messages" },
    },
  },
});
