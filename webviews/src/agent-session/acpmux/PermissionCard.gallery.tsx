// l10n-allow-file: gallery fixtures (sample commands, paths and option names), not shipped UI.
// The single permission card's answer row (PermissionCard.tsx). Leo 2026-10-25, on a card whose
// "Always allow" was a wide row holding the whole rule, repeated as a line under Deny: "the allow
// button, like this, it shouldn't be encompassing so much ... this other, like, thing shouldn't be
// the same thing." Then, on equal-width buttons stretched across the card: "but there's literally
// no point having it be the same size? just make it good? incl. the symbol hints". The buttons are
// sized to their labels with a light key hint; the scope is one muted line. scopeStyle and rowStyle
// draw gallery-only alternatives over the shipped card; "under" and "light" are the shipped ones.
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { AcpmuxPermission } from "./model";
import { PermissionCard } from "./PermissionCard";
import { SHORTCUT_ACTIONS, ShortcutsContext } from "./shortcuts";

type ScopeStyle = "under" | "labelled" | "front";
type RowStyle = "light" | "keycap" | "hover" | "trailing";
/// How the one-time line of an ask the chat's highest mode does not answer reads: "line" (shipped,
/// a muted line under the title), "callout" (an inset tinted box) or "pill" (a small pill).
type OneTimeStyle = "line" | "callout" | "pill";
type Props = Pick<ComponentProps<typeof PermissionCard>, "permission" | "harness" | "fullAccessMode"> & {
  scopeStyle?: ScopeStyle;
  rowStyle?: RowStyle;
  oneTimeStyle?: OneTimeStyle;
};

const oneTimeStyles: Record<Exclude<OneTimeStyle, "line">, string> = {
  callout: `
    [data-one-time-style="callout"] .acpmux-permission-one-time { padding: 6px 8px; border-radius: 6px;
      background: color-mix(in srgb, var(--agent-text) 6%, transparent); color: var(--agent-soft); }`,
  pill: `
    [data-one-time-style="pill"] .acpmux-permission-one-time { align-self: flex-start; padding: 2px 8px;
      border-radius: 999px; border: 1px solid color-mix(in srgb, currentColor 25%, transparent); }`,
};

const rowStyles: Record<Exclude<RowStyle, "light">, string> = {
  // The hint as a small keycap: a faint rounded box around it, Claude desktop's menu style.
  keycap: `
    [data-row-style="keycap"] .acpmux-permission-ask .acpmux-permission-action-shortcut { padding: 1px 4px;
      border-radius: 4px; background: color-mix(in srgb, currentColor 12%, transparent); }`,
  // The hint only on hover or focus: the resting row reads as three words.
  hover: `
    [data-row-style="hover"] .acpmux-permission-ask .acpmux-permission-action-shortcut { opacity: 0; }
    [data-row-style="hover"] .acpmux-permission-ask button:is(:hover, :focus-visible) .acpmux-permission-action-shortcut { opacity: 1; }`,
  // The light hint, the row grouped at the trailing edge, as a macOS dialog's buttons.
  trailing: `
    [data-row-style="trailing"] .acpmux-permission-ask .acpmux-permission-buttons { justify-content: flex-end; }
    [data-row-style="trailing"] .acpmux-permission-ask .acpmux-permission-scope { text-align: end; }`,
};

const scopeStyles: Record<Exclude<ScopeStyle, "under">, string> = {
  // The line under the buttons, named: "Scope: …".
  labelled: `
    [data-scope-style="labelled"] .acpmux-permission-scope::before { content: "Scope: "; color: var(--agent-soft); }`,
  // The line in front of the buttons, between the command and the row.
  front: `
    [data-scope-style="front"] .acpmux-permission-ask { display: flex; flex-direction: column; }
    [data-scope-style="front"] .acpmux-permission-scope { order: 1; margin: 8px 0 0; }
    [data-scope-style="front"] .acpmux-permission-buttons { order: 2; align-self: flex-start; margin-top: 6px; }`,
};

const labels = {
  [SHORTCUT_ACTIONS.permissionAllowOnce]: "⌥⌘1",
  [SHORTCUT_ACTIONS.permissionAllowChat]: "⌥⌘2",
  [SHORTCUT_ACTIONS.permissionDeny]: "⌥⌘3",
};

const FFMPEG =
  "ffmpeg -y -i /Users/you/media/launch-reel/raw/take-03.mov -vf scale=1280:-2 -c:v libx264 -crf 20 /Users/you/media/launch-reel/out/take-03.mp4 && rm -f /Users/you/media/launch-reel/raw/*.tmp";

/// A Claude Bash ask whose Always allow carries a long session rule (Claude's suggestions).
const longRule: AcpmuxPermission = {
  permissionId: "gallery-long-rule",
  kind: "execute",
  title: "`ffmpeg -y -i …`",
  command: FFMPEG,
  description: "Encode the launch reel take and clear its temp files",
  scope: { kind: "directory", value: "/Users/you/media/launch-reel" },
  rule: "Allow Read(//Users/you/media/launch-reel/**), Bash(rm -f /Users/you/media/launch-reel/raw/*.tmp), Bash(ffmpeg -y -i:*) for this session",
  pending: true,
  options: [
    { id: "allow_always", name: "Always Allow", kind: "allow_always", allow: true },
    { id: "allow", name: "Allow", kind: "allow_once", allow: true },
    { id: "reject", name: "Reject", kind: "reject_once", allow: false },
  ],
};

/// A short rule: one command prefix, no folder.
const shortRule: AcpmuxPermission = {
  permissionId: "gallery-short-rule",
  kind: "execute",
  title: "`git push`",
  command: "git push origin feature/reel-export",
  description: "Push the branch",
  rule: "Allow git push:* for this session",
  pending: true,
  options: longRule.options,
};

/// What Claude Code still asks in Bypass permissions: an ask it marks as needing the person
/// (`requires_user_interaction`), here a browser tool opening a page; acpmux offers Allow and Reject.
const stillAsks: AcpmuxPermission = {
  permissionId: "gallery-still-asks",
  kind: "fetch",
  title: "Open developer.apple.com/account in the browser",
  pending: true,
  options: [
    { id: "allow_once", name: "Answer", kind: "allow_once", allow: true },
    { id: "reject_once", name: "Reject", kind: "reject_once", allow: false },
  ],
};

/// Four options, Codex style: the Always allow says its scope in its own long name, and a second
/// deny stays a button of its own.
const fourOptions: AcpmuxPermission = {
  permissionId: "gallery-four-options",
  kind: "execute",
  title: "Run npm run build",
  command: "npm run build",
  scope: { kind: "directory", value: "/Users/you/src/atlas-web" },
  pending: true,
  options: [
    { id: "approved", name: "Yes", kind: "allow_once", allow: true },
    {
      id: "approved_for_session",
      name: "Yes, and don't ask again for commands that start with `npm run`",
      kind: "allow_always",
      allow: true,
    },
    { id: "abort", name: "No, and tell Codex what to do differently", kind: "reject_once", allow: false },
    { id: "denied", name: "No, continue without running it", kind: "reject_always", allow: false },
  ],
};

const PLAN = `## Retry failed uploads

Uploads that fail on a dropped connection are lost today. Retry them with backoff.

1. Add \`withRetry\` to \`src/net/retry.ts\`: three attempts, 250 ms doubling, only on network errors.
2. Wrap \`uploadChunk\` in \`src/upload/client.ts\` with it.
3. Show "Retrying…" on the upload row while an attempt waits.

### Tests

- \`retry.test.ts\`: gives up after three attempts; never retries a 4xx.
- \`client.test.ts\`: a dropped chunk uploads on the second attempt.`;

/// Claude Code's ExitPlanMode: the plan as its input, Allow and Reject as acpmux offers them.
const claudePlan: AcpmuxPermission = {
  permissionId: "gallery-claude-plan",
  kind: "other",
  title: "Approve plan",
  plan: PLAN,
  pending: true,
  options: [
    { id: "allow_once", name: "Allow", kind: "allow_once", allow: true },
    { id: "reject_once", name: "Reject", kind: "reject_once", allow: false },
  ],
};

/// Grok's plan approval as acpmux builds it (hub xai.rs): "Ready to code?" with the plan.
const grokPlan: AcpmuxPermission = {
  permissionId: "gallery-grok-plan",
  kind: "switch_mode",
  title: "Ready to code?",
  plan: PLAN,
  pending: true,
  options: [
    { id: "approve_plan", name: "Yes, start coding", kind: "allow_once", allow: true },
    { id: "keep_planning", name: "No, keep planning", kind: "reject_once", allow: false },
  ],
};

function GalleryPermissionCard({ permission, harness, fullAccessMode, scopeStyle, rowStyle, oneTimeStyle }: Props) {
  return (
    <div
      className="acpmux-shell"
      data-scope-style={scopeStyle}
      data-row-style={rowStyle}
      data-one-time-style={oneTimeStyle}
      style={{ paddingTop: 12 }}
    >
      {scopeStyle && scopeStyle !== "under" && <style>{scopeStyles[scopeStyle]}</style>}
      {rowStyle && rowStyle !== "light" && <style>{rowStyles[rowStyle]}</style>}
      {oneTimeStyle && oneTimeStyle !== "line" && <style>{oneTimeStyles[oneTimeStyle]}</style>}
      <div className="acpmux-main">
        <div className="acpmux-permission acpmux-asks-stack">
          <ShortcutsContext value={labels}>
            <PermissionCard
              permission={permission}
              harness={harness}
              fullAccessMode={fullAccessMode}
              onAnswer={() => undefined}
            />
          </ShortcutsContext>
        </div>
      </div>
    </div>
  );
}

/// The scope shows once, never inside a button.
const scopeOnce: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-permission-scope"));
  const scope = ctx.document.querySelector(".acpmux-permission-scope")!.textContent ?? "";
  const buttons = [...ctx.document.querySelectorAll(".acpmux-permission-buttons button")];
  if (buttons.some((button) => scope && (button.textContent ?? "").includes(scope.split(" · ").at(-1)!)))
    throw new Error("A button repeats the scope line");
  if (ctx.document.querySelectorAll(".acpmux-permission-scope").length !== 1)
    throw new Error("The scope is drawn more than once");
};

export default componentEntry<Props>({
  id: "agent-pane.permission-card",
  title: "Permission card answers",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/PermissionCard.tsx#PermissionCard"],
  load: async () => GalleryPermissionCard,
  styles: () =>
    Promise.all([
      import("../../ui/glass/glass.css"),
      import("./styles.css"),
      import("./conversation/conversation.css"),
      import("./keys.css"),
    ]),
  widths: { narrow: 360, normal: 540, wide: 760 },
  height: 260,
  variants: {
    "grid-pending": {
      note: "Grid measurement: pending permission without a play that answers it.",
      props: { permission: shortRule, harness: "claude" },
    },
    "long-rule": {
      note: "Leo 2026-10-25: a long Claude session rule. Compact buttons sized to their labels, grouped at the leading edge, each with a light ⌥⌘ hint; the rule is one muted line under them, cut, whole on hover.",
      props: { permission: longRule, harness: "claude" },
      play: scopeOnce,
    },
    "short-rule": {
      note: "A short rule (git push:*): the same row, the rule whole on its line.",
      props: { permission: shortRule, harness: "claude" },
      play: scopeOnce,
    },
    "four-options": {
      note: "Four Codex options: each a short button in the request's kinds; the Always allow's own long name moves to the scope line.",
      props: { permission: fourOptions, harness: "codex" },
      play: scopeOnce,
    },
    "plan-claude": {
      note: 'Leo 2026-11-05: "i like these plans too... i want us to be able to render it in ours". Claude Code\'s ExitPlanMode: the plan renders as Markdown in the card, with Approve plan and Keep planning (which opens a field for what to change).',
      props: { permission: claudePlan, harness: "claude" },
    },
    "plan-grok": {
      note: "Grok's plan approval (x.ai/exit_plan_mode): the same plan card.",
      props: { permission: grokPlan, harness: "grok" },
    },
    "bypass-still-asks": {
      note: "Leo 2026-11-04: \"a temporary one-time sort of ask for, like if for whatever reason there's the bypass permissions, it doesn't bypass every single thing\". Shipped: in Bypass permissions an ask Claude Code still raises says under its title that the mode doesn't cover it and Allow once lets it run this time only.",
      props: { permission: stillAsks, harness: "claude", fullAccessMode: "Bypass permissions" },
    },
    "bypass-still-asks-callout": {
      note: "One-time line variant B: the line in an inset tinted box.",
      props: {
        permission: stillAsks,
        harness: "claude",
        fullAccessMode: "Bypass permissions",
        oneTimeStyle: "callout",
      },
    },
    "bypass-still-asks-pill": {
      note: "One-time line variant C: the line as a small outlined pill.",
      props: { permission: stillAsks, harness: "claude", fullAccessMode: "Bypass permissions", oneTimeStyle: "pill" },
    },
    "full-access-four-options": {
      note: "Codex in Full access with an ask it still raises: the same line over Codex's four options.",
      props: { permission: fourOptions, harness: "codex", fullAccessMode: "Full access" },
      play: scopeOnce,
    },
    "scope-labelled": {
      note: 'Scope line variant B: under the buttons, named "Scope: …".',
      props: { permission: longRule, harness: "claude", scopeStyle: "labelled" },
    },
    "scope-front": {
      note: "Scope line variant C: in front of the buttons, between the command and the row.",
      props: { permission: longRule, harness: "claude", scopeStyle: "front" },
    },
    "keycap-long-rule": {
      note: "Key hint variant B: each hint in a faint keycap box.",
      props: { permission: longRule, harness: "claude", rowStyle: "keycap" },
    },
    "keycap-four-options": {
      note: "Key hint variant B with four options.",
      props: { permission: fourOptions, harness: "codex", rowStyle: "keycap" },
    },
    "hover-long-rule": {
      note: "Key hint variant C: hints only on hover or focus.",
      props: { permission: longRule, harness: "claude", rowStyle: "hover" },
    },
    "hover-four-options": {
      note: "Key hint variant C with four options.",
      props: { permission: fourOptions, harness: "codex", rowStyle: "hover" },
    },
    "trailing-long-rule": {
      note: "Row variant D: the light hints, the row grouped at the trailing edge.",
      props: { permission: longRule, harness: "claude", rowStyle: "trailing" },
    },
    "trailing-four-options": {
      note: "Row variant D with four options.",
      props: { permission: fourOptions, harness: "codex", rowStyle: "trailing" },
    },
  },
});
