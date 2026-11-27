// l10n-allow-file: gallery fixtures (sample commands and option names), not shipped UI.
// Hold to approve (holdToApprove.experiment.ts, off by default; Taste Board #176, "Hold to unlock ring
// progress"): the permission card's allows answer only after a press-and-hold, with a ring at the
// button's leading edge and a quiet wash that fill together. Each variant draws the real card with a
// `hold` prop in place of the experiment; a play drives the real pointer handlers to the state named.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { AcpmuxPermission } from "../model";
import { PermissionCard } from "../PermissionCard";
import { SHORTCUT_ACTIONS, ShortcutsContext } from "../shortcuts";
import type { HoldScope } from "./holdToApprove.experiment";

type Props = {
  permission: AcpmuxPermission;
  scope: HoldScope;
  durationMs: number;
  reduced?: boolean;
};

const labels = {
  [SHORTCUT_ACTIONS.permissionAllowOnce]: "⌥⌘1",
  [SHORTCUT_ACTIONS.permissionAllowChat]: "⌥⌘2",
  [SHORTCUT_ACTIONS.permissionDeny]: "⌥⌘3",
};

const options: AcpmuxPermission["options"] = [
  { id: "allow_always", name: "Always Allow", kind: "allow_always", allow: true },
  { id: "allow", name: "Allow", kind: "allow_once", allow: true },
  { id: "reject", name: "Reject", kind: "reject_once", allow: false },
];

const destructive: AcpmuxPermission = {
  permissionId: "gallery-hold-destructive",
  kind: "execute",
  title: "`rm -rf …`",
  command: "rm -rf /Users/you/src/atlas-web/dist /Users/you/src/atlas-web/.cache",
  description: "Clear the build output before a clean build",
  scope: { kind: "directory", value: "/Users/you/src/atlas-web" },
  pending: true,
  options,
};

const benign: AcpmuxPermission = {
  permissionId: "gallery-hold-benign",
  kind: "execute",
  title: "`npm test`",
  command: "npm test",
  description: "Run the test suite",
  scope: { kind: "directory", value: "/Users/you/src/atlas-web" },
  pending: true,
  options,
};

function GalleryHoldCard({ permission, scope, durationMs, reduced }: Props) {
  return (
    <div className="acpmux-shell" style={{ paddingTop: 12 }}>
      <div className="acpmux-main">
        <div className="acpmux-permission acpmux-asks-stack">
          <ShortcutsContext value={labels}>
            <PermissionCard
              permission={permission}
              harness="claude"
              hold={{ scope, durationMs, reduced }}
              onAnswer={() => new Promise(() => undefined)}
            />
          </ShortcutsContext>
        </div>
      </div>
    </div>
  );
}

const ALLOW = ".acpmux-permission-buttons button.acpmux-permission-primary";

/// Holds Return on the focused Allow, the keyboard path a person takes (the card's own key handlers,
/// not a synthetic pointer): focus moves to Allow as a key would, then Return goes down and stays down.
async function holdReturn(ctx: Parameters<Play>[0]) {
  await ctx.waitFor(() => ctx.document.querySelector(ALLOW));
  await ctx.focus({ selector: ALLOW });
  const button = ctx.document.querySelector<HTMLButtonElement>(ALLOW)!;
  const view = ctx.document.defaultView!;
  button.dispatchEvent(
    new view.KeyboardEvent("keydown", { key: "Enter", code: "Enter", bubbles: true, cancelable: true }),
  );
  await ctx.waitFor(() => button.getAttribute("data-hold") !== "idle");
  return button;
}

/// Return held on Allow and kept down: the hold is long, so the still frame shows the ring part-filled.
const pressAndHold: Play = async (ctx) => {
  await holdReturn(ctx);
  await new Promise((resolve) => setTimeout(resolve, 1500));
};

/// Return held on Allow through the hold: the ring is full and the answer went out.
const holdThrough: Play = async (ctx) => {
  const button = await holdReturn(ctx);
  await ctx.waitFor(() => button.getAttribute("data-hold") === "done");
};

export default componentEntry<Props>({
  id: "agent-pane.hold-to-approve",
  title: "Hold to approve",
  area: "Agent pane",
  experimental: true,
  pane: true,
  keywords: ["hold", "approve", "press", "ring", "permission", "confirm"],
  covers: ["agent-session/acpmux/permissions/HoldButton.tsx"],
  load: async () => GalleryHoldCard,
  styles: () =>
    Promise.all([
      import("../../../ui/glass/glass.css"),
      import("../styles.css"),
      import("../conversation/conversation.css"),
    ]),
  widths: { narrow: 360, normal: 540, wide: 760 },
  height: 260,
  variants: {
    idle: {
      note: "Every allow holds (`hold-to-approve`: all). Allow and Always allow carry an empty ring at their leading edge; Deny is today's button and answers at once.",
      props: { permission: destructive, scope: "all", durationMs: 600 },
    },
    "mid-hold": {
      note: "Allow held partway: the ring and a faint wash from the leading edge fill together. Letting go here answers nothing and empties both. Drawn with a 4 s hold so the still frame catches it.",
      props: { permission: destructive, scope: "all", durationMs: 4000 },
      play: pressAndHold,
    },
    completed: {
      note: "Held through the 600 ms default: the ring is full and the allow went out.",
      props: { permission: destructive, scope: "all", durationMs: 600 },
      play: holdThrough,
    },
    "reduced-motion": {
      note: "Under Reduce Motion the ring and wash step a quarter at a time with no sweep or easing. Held partway on a 4 s hold.",
      props: { permission: destructive, scope: "all", durationMs: 4000, reduced: true },
      play: pressAndHold,
    },
    "destructive-only-benign": {
      note: "`hold-to-approve`: destructive, on `npm test`: no ring, Allow answers on a click as today.",
      props: { permission: benign, scope: "destructive", durationMs: 600 },
    },
    "destructive-only-rm": {
      note: "`hold-to-approve`: destructive, on `rm -rf`: the allows hold.",
      props: { permission: destructive, scope: "destructive", durationMs: 600 },
    },
    off: {
      note: "The default (`hold-to-approve`: off): today's card, unchanged.",
      props: { permission: destructive, scope: "off", durationMs: 600 },
    },
  },
});
