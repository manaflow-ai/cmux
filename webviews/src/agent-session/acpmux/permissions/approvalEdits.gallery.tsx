// l10n-allow-file: gallery fixture requests and paths, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { permissionFromMessage } from "../direct";
import { PermissionCard } from "../PermissionCard";
import { PermissionPanel } from "./Panel";

// Long enough to pass the inline card's edit cap at the gallery's 640 px height.
const LONG_LINES = 80;

type Props = { grouped: boolean; long?: boolean; multiple?: boolean };

// EditDiff loads Pierre's hunk renderer lazily. The gallery's generic "quiet DOM" readiness can
// fire after the card header but before Pierre has painted its shadow DOM, leaving captures with
// only the file/count row. Wait for every rendered block and for the final edit text before marking
// each approval variant ready (including both blocks of MultiEdit).
const renderedDiffs =
  (multiple = false, long = false): Play =>
  async (ctx) => {
    const expected = [
      ...(multiple ? [["attempt=0", "attempt=1"]] : []),
      [
        "exit 1",
        ...(long ? Array.from({ length: LONG_LINES }, (_, index) => `echo step ${index + 1}`) : ["echo done"]),
        "exit 0",
      ],
    ];
    await ctx.waitFor(() => {
      const containers = [...ctx.document.querySelectorAll<HTMLElement>(".cv-edit-diff__body diffs-container")];
      if (containers.length !== expected.length) return false;
      return containers.every((container, index) => {
        const lines = [...(container.shadowRoot?.querySelectorAll("[data-line]") ?? [])].map((line) =>
          line.textContent?.trimEnd(),
        );
        return expected[index]!.every((line) => lines.includes(line));
      });
    });
  };

function ApprovalEdits({ grouped, long, multiple }: Props) {
  const edits = [
    {
      old_string: "exit 1\n",
      new_string: long
        ? Array.from({ length: LONG_LINES }, (_, index) => `echo step ${index + 1}`).join("\n") + "\nexit 0\n"
        : "echo done\nexit 0\n",
    },
  ];
  if (multiple) edits.unshift({ old_string: "attempt=0\n", new_string: "attempt=1\n" });
  const request = {
    toolCall: {
      toolCallId: "edit-upload",
      title: "Edit upload.sh",
      kind: "edit",
      rawInput: { file_path: "/Users/you/src/uploader/upload.sh", edits },
    },
    options: [
      { optionId: "allow", name: "Allow", kind: "allow_once" },
      { optionId: "deny", name: "Deny", kind: "reject_once" },
    ],
  };
  const permissionId = "approval-edit";
  const sessionId = "approval-session";
  const permission = permissionFromMessage({ sessionId, permissionId, request }, sessionId)!;
  return (
    <div className="acpmux-shell">
      <div className="acpmux-main">
        <div className="acpmux-permission acpmux-asks-stack">
          {grouped ? (
            <PermissionPanel
              state={{
                supported: true,
                ready: true,
                chatAllowance: false,
                loading: false,
                busy: false,
                groups: [
                  {
                    groupId: "approval-group",
                    sessionId,
                    turnId: "approval-turn",
                    revision: 1,
                    state: "pending",
                    items: [{ permissionId, request, state: "pending" }],
                    decisions: ["allow_once", "allow_chat", "deny"],
                    decision: null,
                  },
                ],
              }}
              working
              onRespond={() => {}}
              onRetry={() => {}}
              onRevoke={() => {}}
              onRefresh={() => {}}
            />
          ) : (
            <PermissionCard permission={permission} onAnswer={() => {}} />
          )}
        </div>
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.approval-edits",
  title: "Proposed edits in approvals",
  area: "Agent pane",
  pane: true,
  covers: [
    "agent-session/acpmux/PermissionCard.tsx#PermissionCard",
    "agent-session/acpmux/permissions/Panel.tsx",
    "agent-session/acpmux/permissions/ProposedEdits.tsx",
  ],
  load: async () => ApprovalEdits,
  styles: () => Promise.all([import("../styles.css"), import("../conversation/conversation.css")]),
  widths: { narrow: 360, normal: 540, wide: 760 },
  height: 640,
  variants: {
    single: { props: { grouped: false }, play: renderedDiffs() },
    grouped: { props: { grouped: true }, play: renderedDiffs() },
    "single-multiedit": { props: { grouped: false, multiple: true }, play: renderedDiffs(true) },
    "grouped-multiedit": { props: { grouped: true, multiple: true }, play: renderedDiffs(true) },
    "single-long": { props: { grouped: false, long: true }, play: renderedDiffs(false, true) },
    "grouped-long": { props: { grouped: true, long: true }, play: renderedDiffs(false, true) },
  },
});
