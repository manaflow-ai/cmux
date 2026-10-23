// l10n-allow-file: gallery regression fixtures, not shipped UI.
import { agentPaneEntry } from "../../gallery/format";
import { activity, chat, CWD, row, tool, user } from "../../gallery/fixtures/acpmux";
import type { Play, PlayContext } from "../../gallery/play";
import type { AcpmuxPermission } from "./model";

const permission: AcpmuxPermission = {
  permissionId: "stack-permission",
  title: "Run the checks",
  command: "git grep -- ':!vendor' -- cmux-tui",
  description: "Search the cmux-tui sources before the agent continues.",
  pending: true,
  options: [
    { id: "allow_once", name: "Yes", kind: "allow_once", allow: true },
    {
      id: "allow_always",
      name: "Yes, and don't ask again this session",
      kind: "allow_always",
      rule: "Allow git grep in cmux-tui for this session",
      allow: true,
    },
    { id: "reject_once", name: "No", kind: "reject_once", allow: false },
  ],
};
const queue = [{ id: "correction", prompt: "Correction from the coordinator: keep the bottom stack in one column." }];
const rows = [
  user("Check the changes", 1),
  activity([tool("Check formatting", "execute", "running"), tool("Check types", "execute", "running")], 0),
  row("permission", 0, { permission }),
];
const individual = chat(rows, { isWorking: true, permission, queue });
// Two more asks wait behind the shown one (a question, a second subagent's command).
const individualWaiting = chat(rows, { isWorking: true, permission, permissionsWaiting: 2, queue });
const prQueue = chat(
  [
    user("Open the pull request", 1),
    activity(
      [
        tool("gh pr create --fill", "execute", "completed", {
          command: "gh pr create --fill",
          output: "https://github.com/acme/atlas-web/pull/128\n",
          exitCode: 0,
        }),
      ],
      0,
    ),
  ],
  { isWorking: true, queue, sessionId: "pr-queue-session" },
);
const grouped = {
  ...individual,
  permissionGroups: {
    supported: true,
    ready: true,
    busy: false,
    loading: false,
    chatAllowance: false,
    groups: [
      {
        groupId: "stack-group",
        sessionId: individual.sessionId!,
        turnId: "stack-turn",
        revision: 1,
        state: "pending" as const,
        decisions: ["allow_once", "allow_chat", "deny"] as ("allow_once" | "allow_chat" | "deny")[],
        decision: null,
        items: [
          {
            permissionId: permission.permissionId,
            state: "pending" as const,
            request: { toolCall: { title: "Run the checks", kind: "execute", rawInput: { command: "bun run check" } } },
          },
        ],
      },
    ],
  },
};
const native = { "acp.trust.get": { cwd: CWD, level: "unknown" }, "acp.trust.set": { cwd: CWD, level: "trusted" } };

// Real rendered accessibility surfaces, not guessed card heights. Includes the transcript viewport:
// a floated queue or a flex-shrunk ask must not paint into a sibling's frame.
function geometry(ctx: PlayContext) {
  const selectors = [
    ".acpmux-pr-dock",
    ".acpmux-trust-ask",
    ".acpmux-permission-panel",
    ".acpmux-composer-queue",
    ".acpmux-composer-box",
  ];
  const layers = selectors.flatMap((selector) =>
    [...ctx.document.querySelectorAll(selector)].map((node) => ({
      selector,
      node,
      rect: node.getBoundingClientRect(),
    })),
  );
  for (let i = 0; i < layers.length; i++)
    for (let j = i + 1; j < layers.length; j++) {
      const a = layers[i]!;
      const b = layers[j]!;
      // Containers intentionally contain their cards and the composer contains its queue. Only
      // peer layers can overlap in the user-visible stack, so ancestor pairs are not geometry
      // failures.
      if (a.node.contains(b.node) || b.node.contains(a.node)) continue;
      const width = Math.min(a.rect.right, b.rect.right) - Math.max(a.rect.left, b.rect.left);
      const height = Math.min(a.rect.bottom, b.rect.bottom) - Math.max(a.rect.top, b.rect.top);
      if (width > 1 && height > 1)
        throw new Error(`Bottom stack overlaps: ${a.selector} / ${b.selector} (${height}px)`);
    }
}
const checkTrust: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-trust-ask"));
  geometry(ctx);
  if (ctx.document.querySelector(".acpmux-permission-card"))
    throw new Error("Tool permission is visible before folder trust");
};
const checkPrQueue: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-pr-dock"));
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-composer-queue"));
  geometry(ctx);
  await ctx.click({ selector: ".acpmux-queued" });
  geometry(ctx);
  // A started chat has no folder/host strip (#20869, locationRow.ts): the queue is the composer's
  // top strip, and no hidden slot for the strip may hold space above it.
  if (ctx.document.querySelector(".acpmux-composer-context, .acpmux-composer-strip-placeholder"))
    throw new Error("A started chat with a queue still draws the folder/host strip");
};
async function samplePinned(ctx: PlayContext, frames = 8) {
  const scroller = ctx.find({ selector: ".acpmux-scroll" }) as HTMLElement;
  const view = ctx.document.defaultView;
  if (!view) return;
  for (let index = 0; index < frames; index += 1) {
    await new Promise<void>((resolve) => view.requestAnimationFrame(() => resolve()));
    const latest = Math.max(0, scroller.scrollHeight - scroller.clientHeight);
    if (Math.abs(scroller.scrollTop - latest) > 1)
      throw new Error(`Follow-bottom moved during stack update (${scroller.scrollTop} vs ${latest})`);
  }
}
const trustThenPermission: Play = async (ctx) => {
  await checkTrust(ctx);
  await ctx.click({ role: "button", name: "Trust folder" });
  await samplePinned(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-permission-card"));
  if (ctx.document.querySelectorAll(".acpmux-permission-card").length !== 1)
    throw new Error("More than one tool permission card");
  if (
    !ctx.document.querySelector(
      ".acpmux-permission-card .acpmux-permission-card-heading, .acpmux-permission-card .acpmux-permission-request-label",
    )
  )
    throw new Error("Permission card is missing its unified request surface");
  const individual = Boolean(ctx.document.querySelector(".acpmux-permission-ask"));
  const allowOnce = "Allow once";
  const allowAlways = individual ? "Always allow" : "Allow for this chat";
  ctx.find({ role: "button", name: allowAlways });
  ctx.find({ role: "button", name: allowOnce });
  geometry(ctx);
  // These chats offer no modes: Access still mounts for the folder grant, so trust stays revocable.
  await ctx.click({ selector: ".acpmux-access-trigger" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-access-grant-remove") !== null);
  await ctx.click({ selector: ".acpmux-access-grant-remove" });
  await checkTrust(ctx);
};
const waitingInLine: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-permission-ask"));
  const note = ctx.document.querySelector(".acpmux-permission-ask .acpmux-permission-waiting")?.textContent;
  if (note !== "2 more waiting") throw new Error(`Expected "2 more waiting" on the card, got ${note}`);
  geometry(ctx);
};
const trusted: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-trust-ask"));
  await ctx.click({ role: "button", name: "Trust folder" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-permission-card"));
  ctx.find({
    role: "button",
    name: ctx.document.querySelector(".acpmux-permission-ask") ? "Always allow" : "Allow for this chat",
  });
  if (ctx.document.querySelector(".acpmux-trust-ask")) throw new Error("Granted trust still renders in transcript");
  geometry(ctx);
};
// The chat's folder is a repository: the pane offers Trust repo first (one answer for every
// worktree of it), and the answer clears the question for the permission card.
const repoNative = {
  "acp.trust.get": { cwd: CWD, level: "unknown", repo: { root: CWD, worktree: false } },
  "acp.trust.set": { cwd: CWD, level: "trusted" },
};
const trustedRepo: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-trust-ask"));
  await ctx.click({ role: "button", name: "Trust repo" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-permission-card"));
  if (ctx.document.querySelector(".acpmux-trust-ask")) throw new Error("Granted trust still renders in transcript");
};
// A short pane (Leo 2026-10-22: "the access to the composer got fucked"): the question, the
// queue and a long draft over the composer still leave the card and the quiet row under it whole,
// inside the pane, and clickable (test/agent-pane-bottom-stack.test.ts).
const shortPane =
  (lines: number): Play =>
  async (ctx) => {
    await checkTrust(ctx);
    const field = ".acpmux-composer-box .ProseMirror";
    for (let line = 0; line < lines; line++) {
      if (line) await ctx.press("Shift+Enter");
      await ctx.type(`draft line ${line + 1}`, line ? undefined : { selector: field });
    }
    const main = ctx.document.querySelector(".acpmux-main")!.getBoundingClientRect();
    const foot = ctx.document.querySelector(".acpmux-composer-foot")?.getBoundingClientRect();
    if (foot && foot.bottom > main.bottom + 0.5)
      throw new Error(`The quiet row ends ${foot.bottom - main.bottom}px under the pane's bottom edge`);
  };
export default agentPaneEntry({
  id: "agent-pane.bottom-stack",
  title: "Trust, permissions and queued prompts",
  area: "Agent pane",
  height: 660,
  widths: { narrow: 400, normal: 760, wide: 760 },
  anchors: [{ selector: ".acpmux-composer-bar" }],
  covers: ["agent-session/acpmux/PermissionCard.tsx", "agent-session/acpmux/TrustAsk.tsx"],
  variants: {
    "pr-queue": { snapshot: prQueue, native: { "acp.trust.get": { cwd: CWD, level: "trusted" } }, play: checkPrQueue },
    "trust-permission-queue": { snapshot: grouped, native, play: checkTrust },
    "trust-individual-queue": { snapshot: individual, native, play: checkTrust },
    "trust-then-permission": { snapshot: grouped, native, play: trustThenPermission },
    "trust-then-individual": { snapshot: individual, native, play: trustThenPermission },
    "trusted-permission-queue": { snapshot: grouped, native, play: trusted },
    "trusted-individual-queue": { snapshot: individual, native, play: trusted },
    "trusted-individual-waiting": {
      snapshot: individualWaiting,
      native: { "acp.trust.get": { cwd: CWD, level: "trusted" } },
      play: waitingInLine,
    },
    "compact-trust-queue": { snapshot: grouped, native, height: 420, play: checkTrust },
    "trust-repo-permission-queue": { snapshot: grouped, native: repoNative, play: trustedRepo },
    "short-320": { snapshot: individual, native, height: 320, play: shortPane(0) },
    "short-320-long-draft": { snapshot: individual, native, height: 320, play: shortPane(12) },
    "short-400-long-draft": { snapshot: individual, native, height: 400, play: shortPane(12) },
    "short-520-long-draft": { snapshot: individual, native, height: 520, play: shortPane(12) },
  },
});
