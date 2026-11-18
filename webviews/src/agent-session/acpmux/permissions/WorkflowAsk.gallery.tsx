// l10n-allow-file: gallery fixtures (sample workflow and phase names), not shipped UI.
// A Claude Workflow call's permission ask drawn as the workflow's approval card (Labs
// `workflowLabs`, permissions/WorkflowAsk.tsx): its name, what it does, its phases in order, a
// caution that it can use a lot of tokens, then Claude's own answers as Deny, Always run and Run
// once. The answers go to Claude's permission request, so the workflow starts only on an allow.
// `phaseStyle` draws gallery-only alternatives for the phase list over the shipped numbered well.
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxPermission } from "../model";
import { PermissionCard } from "../PermissionCard";
import { SHORTCUT_ACTIONS, ShortcutsContext } from "../shortcuts";
import { configureWorkflowLabs } from "../summary/workflowCardModel";

/// "numbered" (shipped: a numbered list in a quiet well), "chips" (the phases as one wrapped row of
/// pills joined by arrows) or "steps" (a vertical rail of dots, no well).
type PhaseStyle = "numbered" | "chips" | "steps";
type Props = { permission: AcpmuxPermission; labs?: boolean; phaseStyle?: PhaseStyle };

const phaseStyles: Record<Exclude<PhaseStyle, "numbered">, string> = {
  chips: `
    [data-phase-style="chips"] .acpmux-permission-workflow-phases { display: flex; flex-wrap: wrap; gap: 4px 6px;
      padding: 0; background: none; max-height: none; }
    [data-phase-style="chips"] .acpmux-permission-workflow-phases li { padding: 1px 8px; border-radius: 999px;
      border: 1px solid color-mix(in srgb, currentColor 18%, transparent); }
    [data-phase-style="chips"] .acpmux-permission-workflow-index { display: none; }`,
  steps: `
    [data-phase-style="steps"] .acpmux-permission-workflow-phases { padding: 0 0 0 4px; background: none; }
    [data-phase-style="steps"] .acpmux-permission-workflow-phases li { position: relative; padding-left: 14px; }
    [data-phase-style="steps"] .acpmux-permission-workflow-phases li::before { content: ""; position: absolute;
      left: 0; top: 0.6em; width: 6px; height: 6px; border-radius: 50%; background: var(--agent-muted); }
    [data-phase-style="steps"] .acpmux-permission-workflow-index { display: none; }`,
};

const labels = {
  [SHORTCUT_ACTIONS.permissionAllowOnce]: "⌥⌘1",
  [SHORTCUT_ACTIONS.permissionAllowChat]: "⌥⌘2",
  [SHORTCUT_ACTIONS.permissionDeny]: "⌥⌘3",
};

/// Claude's ask for a Workflow call, as acpmux sends it with the run read from its script
/// (claude_stdio/workflow_ask.rs): Allow, Allow for this session with Claude's rule, and Reject.
const review: AcpmuxPermission = {
  permissionId: "gallery-workflow-review",
  kind: "other",
  title: "Workflow",
  rule: "Allow Workflow for this session",
  pending: true,
  workflow: {
    name: "review-changes",
    description: "Review the changed files across four dimensions, then verify each finding",
    phases: ["Review", "Verify", "Report"],
  },
  options: [
    { id: "allow_once", name: "Allow", kind: "allow_once", allow: true },
    { id: "allow_always", name: "Allow for this session", kind: "allow_always", allow: true },
    { id: "reject_once", name: "Reject", kind: "reject_once", allow: false },
  ],
};

/// No rule Claude can keep: no Always run (acpmux offers only what Claude can hold to).
const onceOnly: AcpmuxPermission = {
  ...review,
  permissionId: "gallery-workflow-once",
  rule: undefined,
  options: review.options.filter((option) => option.kind !== "allow_always"),
};

/// A long script: past 24 phases acpmux sends a count of the rest.
const longRun: AcpmuxPermission = {
  ...review,
  permissionId: "gallery-workflow-long",
  workflow: {
    name: "migrate-every-package-to-the-new-settings-schema-and-regenerate-docs",
    description: "Port each package, run its tests, regenerate the docs, then open one PR per area",
    phases: [
      "Inventory packages",
      "Plan the port per package",
      "Port settings readers",
      "Port settings writers",
      "Run package tests",
      "Fix failures",
      "Regenerate docs",
      "Review the diff",
      "Open pull requests",
    ],
    morePhases: 15,
  },
};

/// A built-in workflow named only (no script found), resuming an earlier run.
const resumed: AcpmuxPermission = {
  ...review,
  permissionId: "gallery-workflow-resume",
  workflow: { name: "deep-review", phases: [], resume: "wf_4fe91c" },
};

function GalleryWorkflowAsk({ permission, labs = true, phaseStyle }: Props) {
  configureWorkflowLabs(labs);
  return (
    <div className="acpmux-shell" data-phase-style={phaseStyle} style={{ paddingTop: 12 }}>
      {phaseStyle && phaseStyle !== "numbered" && <style>{phaseStyles[phaseStyle]}</style>}
      <div className="acpmux-main">
        <div className="acpmux-permission acpmux-asks-stack">
          <ShortcutsContext value={labels}>
            <PermissionCard permission={permission} harness="claude" onAnswer={() => undefined} />
          </ShortcutsContext>
        </div>
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.workflow-approval",
  title: "Workflow approval card",
  area: "Agent pane",
  pane: true,
  height: 340,
  widths: { narrow: 420, normal: 760 },
  covers: [
    "agent-session/acpmux/permissions/WorkflowAsk.tsx",
    "agent-session/acpmux/permissions/WorkflowAsk.css",
    "agent-session/acpmux/permissions/workflowAskModel.ts",
  ],
  load: async () => GalleryWorkflowAsk,
  variants: {
    numbered: {
      note: "Shipped (Labs): Claude's Workflow ask as the workflow's approval card. Run workflow review-changes?, what it does, its three phases numbered in a quiet well, the token caution, then Deny, Always run and Run once. Before: a generic 'Workflow' tool ask with no phases. The answers are Claude's own ask's, so nothing starts before an allow.",
      props: { permission: review, phaseStyle: "numbered" },
    },
    chips: {
      note: "Gallery alternative A: the phases as one wrapped row of pills. Shortest card; loses the order numbers.",
      props: { permission: review, phaseStyle: "chips" },
    },
    steps: {
      note: "Gallery alternative B: a vertical rail of dots with no well, as a step list. Lighter, but the list no longer reads as one block.",
      props: { permission: review, phaseStyle: "steps" },
    },
    "once-only": {
      note: "Claude offered no rule it can keep: Run once and Deny only, never an Always run that would act as Run once.",
      props: { permission: onceOnly },
    },
    "long-run": {
      note: "A long workflow name and 24 phases: the name ellipsizes in the title, the well scrolls past 220px, and '+15 more' counts what acpmux did not send.",
      props: { permission: longRun },
    },
    resume: {
      note: "A built-in workflow with no script to read, resuming a run: the name, 'Continues run wf_4fe91c' and the caution.",
      props: { permission: resumed },
    },
    "labs-off": {
      note: "Labs workflowLabs off: the same ask draws as any tool's permission card, as before this change.",
      props: { permission: review, labs: false },
    },
  },
});
