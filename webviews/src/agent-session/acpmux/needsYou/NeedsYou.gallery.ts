// l10n-allow-file: gallery fixtures (sample asks, chat names and commands), not shipped UI.
// Needs you (needsYou/NeedsYou.tsx): the header badge counts every open ask, from this chat, the
// Chief, its subagents and the other agent chats; a press opens the pinned list with one-click
// answers, Go to source and Ask about this. While asks are open, Jump to latest is the Needs your
// input pill (JumpPill.tsx), for this chat's asks and its started chats' only. Both are Debug
// Settings toggles; `before` is the pane with both off, as it drew before. Light and dark come from
// the gallery's appearance control.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { activity, assistant, chat, session, SESSION_ID, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxPermission, AcpmuxSnapshot } from "../model";
import type { AgentQuestion } from "../question/model";
import type { WatchedAsk } from "./model";

const ago = (minutes: number) => Date.now() - minutes * 60_000;
const yesNo: AcpmuxPermission["options"] = [
  { id: "allow_once", name: "Allow", kind: "allow_once", allow: true },
  { id: "allow_always", name: "Always allow", kind: "allow_always", allow: true },
  { id: "reject_once", name: "Deny", kind: "reject_once", allow: false },
];

const here: AcpmuxPermission = {
  permissionId: "ask-here",
  title: "Run the checks",
  kind: "execute",
  command: "bun run check",
  pending: true,
  options: yesNo,
};
const login: AgentQuestion = {
  id: "ask-decision",
  source: { harness: "codex", session: "s-codex", permission: "ask-decision", answerOption: "allow_once" },
  items: [
    {
      id: "q0",
      header: "Auth",
      prompt: "Which sign-in should the settings page use?",
      options: [
        { id: "OAuth", label: "OAuth" },
        { id: "Passkeys", label: "Passkeys" },
        { id: "Both", label: "Both" },
      ],
      multiSelect: false,
      allowsOther: true,
    },
  ],
  state: { kind: "pending" },
};
const asks: WatchedAsk[] = [
  { sessionId: SESSION_ID, at: ago(1), permission: here },
  {
    sessionId: "s-chief",
    at: ago(3),
    permission: {
      permissionId: "ask-chief",
      title: "Merge #22410 into feat-cmux-next?",
      pending: true,
      options: yesNo,
    },
  },
  {
    sessionId: "s-codex",
    at: ago(6),
    permission: { permissionId: "ask-decision", pending: true, options: yesNo, question: login },
  },
  {
    sessionId: "s-verify",
    at: ago(14),
    permission: {
      permissionId: "ask-verify",
      title: "Verify the sidebar dot reads in light mode",
      description: "Open a chat that waits on you and look at its row in the sidebar.",
      pending: true,
      options: yesNo,
    },
  },
];
const sessions = [
  session({ sessionId: "s-chief", title: "Chief", harness: "chief", pendingPermissions: 1, updatedAt: ago(3) }),
  session({
    sessionId: "s-codex",
    title: "Port settings to React Aria",
    harness: "codex",
    spawnedBy: "s-chief",
    pendingPermissions: 1,
    indicator: "input",
    updatedAt: ago(6),
  }),
  session({
    sessionId: "s-verify",
    title: "Sidebar dot polish",
    pendingPermissions: 1,
    indicator: "input",
    updatedAt: ago(14),
  }),
  // Its ask lives on the other computer: the row reads the question acpmux names
  // (`waitingPrompt`), never the agent's last message (`preview`).
  session({
    sessionId: "s-remote",
    title: "Release notes on build box",
    host: "build-box",
    hostKind: "cloud",
    peer: "build-box",
    indicator: "input",
    pendingPermissions: 1,
    // Its ask lives on the build box: the row says the question its summary names, never this reply.
    waitingOn: { on: "question", prompt: "Which tag should the notes start from?" },
    preview: "I drafted the notes from the merged PRs since the last nightly.",
    updatedAt: ago(32),
  }),
  // A permission whose tool is not read here reads as a permission, not a question.
  session({
    sessionId: "s-grouped",
    title: "Clean the build cache",
    pendingPermissions: 1,
    indicator: "input",
    waitingOn: { on: "permission" },
    preview: "The cache holds 14 GB of old builds.",
    updatedAt: ago(45),
  }),
];

// A sub-session this chat's agent started (acpmux `startedBy`): its ask is this chat's work, so the
// pill counts it.
const started = session({
  sessionId: "s-tests",
  title: "Run the integration tests",
  startedBy: SESSION_ID,
  shortName: "tests",
  pendingPermissions: 1,
  indicator: "input",
  updatedAt: ago(2),
});
const startedAsk: AcpmuxPermission = {
  permissionId: "ask-tests",
  title: "Start the test database",
  kind: "execute",
  command: "docker compose up -d db",
  pending: true,
  options: yesNo,
};

const rows = [
  user("Make the retry helper back off exponentially", 4),
  activity([tool("Edit src/fetch.ts", "edit", "completed"), tool("bun test fetch", "execute", "completed")], 3),
  assistant("The helper now waits 200 ms, then doubles up to 5 s, with jitter. I want to run the full checks next.", 2),
];

function snapshot(fields: Partial<AcpmuxSnapshot> = {}): AcpmuxSnapshot {
  const base = chat(rows, { permission: here, ...fields });
  return {
    ...base,
    sessions: [{ ...base.sessions[0]!, pendingPermissions: 1, indicator: "input" }, ...sessions],
    asks,
    ...fields,
  };
}

const openList = async (ctx: PlayContext) => {
  await ctx.click({ selector: ".acpmux-needs-you-button" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-needs-you-panel"));
};

export default agentPaneEntry({
  id: "agent-pane.needs-you",
  title: "Needs you",
  area: "Agent pane",
  height: 640,
  keywords: ["needs you", "asks", "approvals", "pending", "inbox", "needs your input"],
  covers: ["agent-session/acpmux/needsYou/NeedsYou.tsx", "agent-session/acpmux/needsYou/JumpPill.tsx#NeedsYouPill"],
  variants: {
    list: {
      note: "The list open: this chat's command, the Chief's merge, a subagent's choice, a verify ask, a question on another computer (its prompt, not the last message) and a permission not read here.",
      snapshot: snapshot(),
      play: openList,
    },
    "badge-and-pill": {
      note: "Closed: the badge counts six asks. Only this chat's is the pill's, and its card waits at the latest message, so Jump to latest stays hidden there.",
      snapshot: snapshot(),
    },
    "pill-one-ask": {
      note: "One ask, in a chat this one did not start (Leo's screenshot: a Codex audit on another computer): nothing here waits, so there is no pill, only the header's count.",
      snapshot: {
        ...chat(rows),
        sessions: [chat(rows).sessions[0]!, sessions[0]!],
        asks: [asks[1]!],
      },
    },
    "pill-started-chat": {
      note: "One ask, in a chat this one started (acpmux startedBy): the pill reads Needs your input at the latest message and goes there.",
      snapshot: {
        ...chat(rows),
        sessions: [chat(rows).sessions[0]!, started],
        asks: [{ sessionId: started.sessionId, at: ago(2), permission: startedAsk }],
      },
    },
    "ask-about-this": {
      note: "Ask about this opens a side session about the asking chat, seeded with What is going on here?",
      snapshot: snapshot(),
      play: async (ctx) => {
        await openList(ctx);
        // The third ask sits below the list's fold (the popover is at most 75vh tall) and the
        // matrix clicks with a real pointer at the button's centre, so bring it into view first,
        // as a person scrolls the list to it.
        const askAbout = ".acpmux-needs-you-item:nth-child(3) .acpmux-needs-you-ask-about";
        ctx.find({ selector: askAbout }).scrollIntoView({ block: "center" });
        await ctx.click({ selector: askAbout });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-needs-you-side-field"));
      },
    },
    compact: {
      note: "Debug Settings Needs you: Compact: one line per ask, no answers.",
      snapshot: snapshot(),
      documentAttributes: { "needs-you": "compact" },
      play: openList,
    },
    empty: {
      note: "Nothing waits: the badge has no count and the list says so.",
      snapshot: chat(rows),
      play: openList,
    },
    "not-installed": {
      note: "The App Store's Needs You item not installed (agentPane.needsYou.enabled off, the default): the header has no inbox and the other tools keep their pitch; `empty` is the same chat with it installed.",
      snapshot: chat(rows),
      documentAttributes: { "needs-you": "off" },
    },
    before: {
      note: "Both Debug toggles off: the pane as it drew before, with no badge and the plain Jump to latest.",
      snapshot: snapshot(),
      documentAttributes: { "needs-you": "off", "needs-you-pill": "off" },
    },
  },
});
