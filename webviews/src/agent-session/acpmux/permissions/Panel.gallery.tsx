// l10n-allow-file: gallery fixtures (sample tool requests and paths), not shipped UI.
import { useState, type ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { PermissionPanel } from "./Panel";
import type { PermissionClientState, PermissionGroup } from "./protocol";

// askStyle: answer-button layouts for a design comparison (cx-ncc.92), drawn by gallery-only rules
// over the shipped row; "current" is the shipped one.
type AskStyle = "current" | "under" | "segmented" | "text";
type Props = ComponentProps<typeof PermissionPanel> & { askStyle?: AskStyle };

const askStyles: Record<Exclude<AskStyle, "current">, string> = {
  // The answers on a line of their own, under the command, from its text's start.
  under: `
    [data-ask-style="under"] .acpmux-ask-row { flex-wrap: wrap; row-gap: 2px; }
    [data-ask-style="under"] .acpmux-ask-toggle { flex-basis: 100%; }
    [data-ask-style="under"] .acpmux-ask-actions { margin-inline-start: 18px; padding-block-end: 4px; }`,
  // One joined control at the row's end: equal segments on one rim, Allow filled.
  segmented: `
    [data-ask-style="segmented"] .acpmux-ask-actions { gap: 0; border-radius: 6px; overflow: hidden;
      box-shadow: inset 0 0 0 var(--cmux-hairline, .5px) var(--cv-card-ring); }
    [data-ask-style="segmented"] .acpmux-ask-action { min-width: 58px; border-radius: 0; text-align: center; }
    [data-ask-style="segmented"] .acpmux-ask-action.is-secondary,
    [data-ask-style="segmented"] .acpmux-ask-action + .acpmux-ask-action { box-shadow: inset var(--cmux-hairline, .5px) 0 0 var(--cv-card-ring); }`,
  // Quiet text answers at the row's end: Allow in the accent, the others dim, no fills or rims.
  text: `
    [data-ask-style="text"] .acpmux-ask-actions { gap: 2px; }
    [data-ask-style="text"] .acpmux-ask-action { padding: 0 6px; color: var(--cv-text-dim); }
    [data-ask-style="text"] .acpmux-ask-action.is-primary { background: transparent; color: var(--agent-accent);
      font-weight: 500; }
    [data-ask-style="text"] .acpmux-ask-action.is-secondary { box-shadow: none; }`,
};

const request = (title: string, command: string, path: string) => ({
  toolCall: {
    title,
    kind: "execute",
    locations: [{ path }],
    rawInput: { command, cwd: "/Users/you/src/cmux" },
  },
});

const pendingGroup: PermissionGroup = {
  groupId: "group-gallery-build",
  sessionId: "session-gallery",
  turnId: "turn-gallery-1",
  revision: 3,
  state: "pending",
  decisions: ["allow_once", "allow_chat", "deny"],
  decision: null,
  items: [
    {
      permissionId: "permission-gallery-build",
      state: "pending",
      request: request("Run the web test suite", "bun test webviews/test/gallery-coverage.test.ts", "webviews/test"),
    },
    {
      permissionId: "permission-gallery-format",
      state: "pending",
      request: request("Format changed files", "bun run fmt", "webviews/src/agent-session/acpmux"),
    },
  ],
};

const baseState: PermissionClientState = {
  supported: true,
  ready: true,
  groups: [pendingGroup],
  chatAllowance: false,
  loading: false,
  busy: false,
};

const resolvedState: PermissionClientState = {
  ...baseState,
  groups: [
    {
      ...pendingGroup,
      state: "resolved",
      decision: "allow_once",
      items: pendingGroup.items.map((item) => ({ ...item, state: "resolved" })),
    },
  ],
};

const collectingState: PermissionClientState = {
  ...baseState,
  groups: [{ ...pendingGroup, state: "collecting" }],
};

const allowanceState: PermissionClientState = {
  ...baseState,
  groups: [],
  chatAllowance: true,
};

const refreshErrorState: PermissionClientState = {
  ...baseState,
  groups: [],
  error: "Permission service is temporarily unavailable.",
};

// A chat on another machine whose acpmux allows only from its own app (Leo 2026-10-21: "this
// literally doesn't work"): only Deny, which counts, and where to approve.
const allowRefusedState: PermissionClientState = {
  ...baseState,
  groups: [{ ...pendingGroup, items: pendingGroup.items.slice(0, 1) }],
  allowRefused: "permission.person_required",
};

const uncertainState: PermissionClientState = {
  ...baseState,
  groups: [],
  error: "The last permission response may not have reached the host.",
  uncertain: true,
};

function GalleryPermissionPanel({ state, working, onRespond, onRetry, onRevoke, onRefresh, askStyle }: Props) {
  const [action, setAction] = useState<string>();
  return (
    // Inside the shell and the pane's asks stack, as in the pane: the shell defines the card's edge
    // color (styles.css), and the stack's column sets its width. Straight in the shell's row, the
    // panel took its command's whole width and ran past a narrow frame (cx-ncc.111).
    <div className="acpmux-shell" data-permission-gallery data-ask-style={askStyle}>
      {askStyle && askStyle !== "current" && <style>{askStyles[askStyle]}</style>}
      <div className="acpmux-main">
        <div className="acpmux-permission acpmux-asks-stack">
          <PermissionPanel
            state={state}
            working={working}
            onRespond={(groupId, revision, decision) => {
              setAction(decision);
              onRespond(groupId, revision, decision);
            }}
            onRetry={() => {
              setAction("retry");
              onRetry();
            }}
            onRevoke={() => {
              setAction("revoke");
              onRevoke();
            }}
            onRefresh={() => {
              setAction("refresh");
              onRefresh();
            }}
          />
        </div>
        <output aria-live="polite" data-permission-action={action}>
          {action ?? ""}
        </output>
      </div>
    </div>
  );
}

const expandDetails: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-ask-toggle" });
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(".acpmux-ask-details")));
};

const allowOnce: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Allow" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-permission-action="allow_once"]'));
};

const openReceipt: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-permission-receipt > summary" });
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(".acpmux-permission-receipt[open]")));
};

/// A chat-wide allowance alone draws no card: its remove lives in the composer's access menu
/// (ComposerPickers.gallery `access-grants`). The panel still answers the Revoke menu action, which
/// the app relays as `cmux-acpmux-permissionRevoke`.
const revokeAllowance: Play = async (ctx) => {
  if (ctx.document.querySelector(".acpmux-permission-panel")) throw new Error("An allowance alone drew a card");
  window.dispatchEvent(new CustomEvent("cmux-acpmux-permissionRevoke"));
  await ctx.waitFor(() => ctx.document.querySelector('[data-permission-action="revoke"]'));
};

const refreshError: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Refresh" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-permission-action="refresh"]'));
};

const retryUncertain: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Check and retry" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-permission-action="retry"]'));
};

// Each state is drawn during the turn that asked: an answered group's receipt leaves with its turn.
const callbacks: Pick<Props, "working" | "onRespond" | "onRetry" | "onRevoke" | "onRefresh"> = {
  working: true,
  onRespond: () => undefined,
  onRetry: () => undefined,
  onRevoke: () => undefined,
  onRefresh: () => undefined,
};

export default componentEntry<Props>({
  id: "agent-pane.permission-panel",
  title: "Permission panel",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/permissions/Panel.tsx#PermissionPanel"],
  load: async () => GalleryPermissionPanel,
  // The app loads these together (dev.tsx); the card's edge and fill live in composerLocation.css, the
  // ask row in conversation.css.
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../composerStates.css"),
      import("../composerLocation.css"),
      import("../conversation/conversation.css"),
    ]),
  widths: { narrow: 360, normal: 540, wide: 760 },
  height: 420,
  checks: {
    layoutShiftMax: {
      value: 0.05,
      reason: "Opening a row's details moves the rows below it; the answers stay on the row.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Permission expansion and decisions should remain responsive on the gallery host.",
    },
    settleMaxMs: {
      value: 300,
      reason: "Permission actions should settle within 300 ms after the person chooses a path.",
    },
  },
  variants: {
    "buttons-current": {
      note: "cx-ncc.92 comparison, A (shipped): one ask, Allow / Always / Deny at the row's right end.",
      props: {
        state: { ...baseState, groups: [{ ...pendingGroup, items: pendingGroup.items.slice(0, 1) }] },
        ...callbacks,
      },
    },
    "buttons-under": {
      note: "cx-ncc.92 comparison, B: the answers on their own line under the command, from its text's start.",
      props: {
        state: { ...baseState, groups: [{ ...pendingGroup, items: pendingGroup.items.slice(0, 1) }] },
        ...callbacks,
        askStyle: "under",
      },
    },
    "buttons-segmented": {
      note: "cx-ncc.92 comparison, C: one joined Allow | Always | Deny control at the row's end.",
      props: {
        state: { ...baseState, groups: [{ ...pendingGroup, items: pendingGroup.items.slice(0, 1) }] },
        ...callbacks,
        askStyle: "segmented",
      },
    },
    "buttons-text": {
      note: "cx-ncc.92 comparison, D: quiet text answers at the row's end, Allow in the accent.",
      props: {
        state: { ...baseState, groups: [{ ...pendingGroup, items: pendingGroup.items.slice(0, 1) }] },
        ...callbacks,
        askStyle: "text",
      },
    },
    pending: {
      note: "Two grouped commands wait: one quiet row each, the verb and command once, Allow / Always / Deny at the first row's end.",
      props: { state: baseState, ...callbacks },
    },
    expanded: {
      note: "A click on a row opens its full command, folder and scope in plain words; the answers stay on the row.",
      props: { state: baseState, ...callbacks },
      play: expandDetails,
    },
    "allow-once": {
      note: "Allow records the selected decision while the host owns the eventual state update.",
      props: { state: baseState, ...callbacks },
      play: allowOnce,
    },
    "allow-refused": {
      note: "A chat on another machine that allows only from its own app: no Allow or Always that could not count, only Deny, and where to approve instead.",
      props: { state: allowRefusedState, ...callbacks },
    },
    collecting: {
      note: "A batching group announces that requests are still being collected.",
      props: { state: collectingState, ...callbacks },
    },
    receipt: {
      note: "A resolved group remains available as a compact, expandable receipt.",
      props: { state: resolvedState, ...callbacks },
      play: openReceipt,
    },
    allowance: {
      note: "A chat-wide allowance draws no card (its remove is in the composer's access menu); the Revoke menu action still revokes it.",
      props: { state: allowanceState, ...callbacks },
      play: revokeAllowance,
    },
    error: {
      note: "A refreshable permission error keeps recovery beside the failure message.",
      props: { state: refreshErrorState, ...callbacks },
      play: refreshError,
    },
    uncertain: {
      note: "An indeterminate response uses Check and retry so the host can reconcile before another action.",
      props: { state: uncertainState, ...callbacks },
      play: retryUncertain,
    },
  },
});
