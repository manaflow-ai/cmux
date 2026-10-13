// l10n-allow-file: gallery regression fixtures, not shipped UI.
import { agentPaneEntry } from "../../gallery/format";
import { activity, chat, CWD, row, tool, user } from "../../gallery/fixtures/acpmux";
import type { Play, PlayContext } from "../../gallery/play";
import type { AcpmuxPermission } from "./model";

const permission: AcpmuxPermission = {
  permissionId: "stack-permission",
  title: "Run the checks",
  pending: true,
  options: [
    { id: "once", name: "Allow", allow: true },
    { id: "chat", name: "Allow for this session", allow: true },
    { id: "deny", name: "Reject", allow: false },
  ],
};
const queue = [{ id: "correction", prompt: "Correction from the coordinator: keep the bottom stack in one column." }];
const rows = [
  user("Check the changes", 1),
  activity([tool("Check formatting", "execute", "running"), tool("Check types", "execute", "running")], 0),
  row("permission", 0, { permission }),
];
const individual = chat(rows, { isWorking: true, permission, queue });
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
    ".acpmux-stage",
    ".acpmux-trust-ask",
    ".acpmux-permission-panel",
    ".acpmux-permission > fieldset",
    ".acpmux-composer-trust-note",
    ".acpmux-composer-queue",
    ".acpmux-composer-box",
  ];
  const layers = selectors.flatMap((selector) =>
    [...ctx.document.querySelectorAll(selector)].map((node) => ({ selector, rect: node.getBoundingClientRect() })),
  );
  for (let i = 0; i < layers.length; i++)
    for (let j = i + 1; j < layers.length; j++) {
      const a = layers[i]!;
      const b = layers[j]!;
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
const trustThenPermission: Play = async (ctx) => {
  await checkTrust(ctx);
  await ctx.click({ role: "button", name: "Trust" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-permission-card"));
  if (ctx.document.querySelectorAll(".acpmux-permission-card").length !== 1)
    throw new Error("More than one tool permission card");
  geometry(ctx);
  await ctx.click({ role: "button", name: "Undo" });
  await checkTrust(ctx);
};
const trusted: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-trust-ask"));
  await ctx.click({ role: "button", name: "Trust" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-permission-card"));
  geometry(ctx);
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
    "trust-permission-queue": { snapshot: grouped, native, play: checkTrust },
    "trust-individual-queue": { snapshot: individual, native, play: checkTrust },
    "trust-then-permission": { snapshot: grouped, native, play: trustThenPermission },
    "trust-then-individual": { snapshot: individual, native, play: trustThenPermission },
    "trusted-permission-queue": { snapshot: grouped, native, play: trusted },
    "trusted-individual-queue": { snapshot: individual, native, play: trusted },
    "compact-trust-queue": { snapshot: grouped, native, height: 420, play: checkTrust },
  },
});
