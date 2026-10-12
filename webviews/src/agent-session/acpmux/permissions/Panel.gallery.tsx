// l10n-allow-file: gallery fixtures (sample tool requests and paths), not shipped UI.
import { useState, type ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { PermissionPanel } from "./Panel";
import type { PermissionClientState, PermissionGroup } from "./protocol";

type Props = ComponentProps<typeof PermissionPanel>;

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

const uncertainState: PermissionClientState = {
  ...baseState,
  groups: [],
  error: "The last permission response may not have reached the host.",
  uncertain: true,
};

function GalleryPermissionPanel({ state, onRespond, onRetry, onRevoke, onRefresh }: Props) {
  const [action, setAction] = useState<string>();
  return (
    <div data-permission-gallery>
      <PermissionPanel
        state={state}
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
      <output aria-live="polite" data-permission-action={action}>
        {action ?? ""}
      </output>
    </div>
  );
}

const expandDetails: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Expand details" });
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(".acpmux-permission-items details[open]")));
};

const allowOnce: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Allow once" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-permission-action="allow_once"]'));
};

const openReceipt: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-permission-receipt > summary" });
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(".acpmux-permission-receipt[open]")));
};

const revokeAllowance: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Revoke" });
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

const callbacks: Pick<Props, "onRespond" | "onRetry" | "onRevoke" | "onRefresh"> = {
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
  styles: () => import("../styles.css"),
  widths: { narrow: 360, normal: 540, wide: 760 },
  height: 420,
  checks: {
    layoutShiftMax: {
      value: 0.05,
      reason:
        "Opening an in-flow permission detail intentionally moves the decision controls below the revealed request.",
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
    pending: {
      note: "Two grouped tool requests show the pending approval surface.",
      props: { state: baseState, ...callbacks },
    },
    expanded: {
      note: "Expand details reveals each requested command without losing the decision controls.",
      props: { state: baseState, ...callbacks },
      play: expandDetails,
    },
    "allow-once": {
      note: "Allow once records the selected decision while the host owns the eventual state update.",
      props: { state: baseState, ...callbacks },
      play: allowOnce,
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
      note: "Chat-wide allowance exposes a quiet revoke affordance after approval.",
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
