// l10n-allow-file: deterministic gallery fixtures, not shipped UI.
// Back to before this turn in a chat on this machine (LocalRewind.tsx): the ask that opens from a
// prompt's Rewind, in each of the three looks of its experiment (localRewind.experiment.ts), and in
// each state: the dry run counting files, files available, files blocked (another live chat uses the
// folder), the rewind running, the line after it with Undo, and a refused rewind. The `*-live`
// variants are the real button on a real prompt: their play clicks Rewind and the ask runs its dry
// run against a fixture answer. The pane runs the experiment's default arm (`checks`); set
// `cmux.experiments` to `{"local-rewind-confirm":"segmented"}` (or `inline`) to run another.
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";
import { LocalRewindButton, LocalRewindNotice, LocalRewindPanel, type RewindPhase } from "./LocalRewind";
import { localRewindConfirm, type LocalRewindLook } from "./localRewind.experiment";
import { parseDryRun, type RewindChoice, type RewindDryRun } from "./localRewindModel";
import { TurnActionsContext, type TurnActions } from "./turnActions";
import { UserBubble } from "./UserBubble";

type State = "checking" | "available" | "blocked" | "running" | "done" | "failed" | "live";
type Props = { look: LocalRewindLook; state: State };

const AVAILABLE = parseDryRun({
  conversation: "fork",
  files: {
    checkpointId: "cp-gallery",
    total: 3,
    paths: ["src/pager.ts", "src/pager.test.ts", "README.md"],
    baseChanged: false,
    complete: true,
  },
});
const SHARED = parseDryRun({
  conversation: "fork",
  files: null,
  filesBlocked: {
    reason: "shared",
    message: "another live chat uses this folder",
    sharedWith: [{ sessionId: "s-other", title: "Fix the pager" }],
  },
});

const PROMPT: AcpmuxRow = {
  id: "user-4",
  version: 1,
  kind: "user",
  at: Date.UTC(2026, 10, 18, 10, 12),
  text: "Now cover the pager's last page with a test",
};

/// The panel as each state draws it, without a running acpmux.
const STATIC: Record<
  Exclude<State, "live" | "done">,
  { phase: RewindPhase; dry?: RewindDryRun; choice: RewindChoice; error?: string }
> = {
  checking: { phase: "checking", choice: { conversation: true, files: false } },
  available: { phase: "ready", dry: AVAILABLE, choice: { conversation: true, files: false } },
  blocked: { phase: "ready", dry: SHARED, choice: { conversation: true, files: false } },
  running: { phase: "running", dry: AVAILABLE, choice: { conversation: true, files: true } },
  failed: {
    phase: "failed",
    dry: AVAILABLE,
    choice: { conversation: true, files: false },
    error: "Couldn’t rewind: This agent can’t rewind its conversation",
  },
};

const liveActions: TurnActions = {
  localRewind: {
    ready: new Set([PROMPT.id]),
    dryRun: () => new Promise((resolve) => setTimeout(() => resolve(AVAILABLE), 300)),
    // The gallery never rewinds: the ask stays on Rewinding….
    apply: () => new Promise(() => {}),
  },
};

function LocalRewindGallery({ look, state }: Props) {
  const noop = () => {};
  if (state === "live")
    return (
      <TurnActionsContext.Provider value={liveActions}>
        <div className="acpmux-shell" style={{ padding: 16 }}>
          <UserBubble row={PROMPT} text={PROMPT.text!} />
          {/* The button the pane draws in the prompt's row, here always in view for the play. */}
          <div style={{ display: "flex", justifyContent: "flex-end" }}>
            <LocalRewindButton rowId={PROMPT.id} look={look} />
          </div>
        </div>
      </TurnActionsContext.Provider>
    );
  if (state === "done")
    return (
      <div className="acpmux-shell" style={{ padding: 16, display: "grid", gap: 8 }}>
        <LocalRewindNotice
          undo={{ original: "chat-1", rewound: "fork-2", conversation: true, files: 3 }}
          undoing={false}
          onUndo={noop}
          onDismiss={noop}
        />
        <LocalRewindNotice
          undo={{ original: "chat-1", safetyCheckpointId: "safe", conversation: false, files: 3 }}
          undoing={false}
          onUndo={noop}
          onDismiss={noop}
        />
        <LocalRewindNotice
          undo={{ original: "chat-1", rewound: "fork-2", conversation: true, files: 0 }}
          undoing
          onUndo={noop}
          onDismiss={noop}
        />
      </div>
    );
  const fixture = STATIC[state];
  const panel = (
    <LocalRewindPanel
      look={look}
      phase={fixture.phase}
      dry={fixture.dry}
      choice={fixture.choice}
      error={fixture.error}
      onChoice={noop}
      onConfirm={noop}
      onCancel={noop}
    />
  );
  return (
    <div className="acpmux-shell" style={{ padding: 16 }}>
      <UserBubble row={PROMPT} text={PROMPT.text!} />
      {look === "inline" ? (
        <div className="cv-rewind-inline">{panel}</div>
      ) : (
        <div style={{ display: "flex", justifyContent: "flex-end" }}>
          {/* The popover's surface, drawn in place so every state shows without a click. */}
          <div className="ui-popup ui-glass ui-popover cv-rewind-popover">{panel}</div>
        </div>
      )}
    </div>
  );
}

const STATE_NOTES: Record<State, string> = {
  checking: "The ask just opened: the dry run counts the files; Rewind waits for it.",
  available: "The default: the conversation only, and Also reset files (3 files) offered from the dry run.",
  blocked: "Another live chat works in this folder: the files choice is disabled, with the reason under it.",
  running: "Both parts chosen and Rewind pressed: the button turns to a spinner and Rewinding….",
  done: "The line over the composer after a rewind, with Undo: conversation, files only, and while Undo runs.",
  failed: "acpmux refused (the agent can't fork): the reason shows, and Rewind can be pressed again.",
  live: "The real button on a real prompt: the play clicks Rewind, and the ask runs its dry run.",
};

const clickRewind = async (ctx: PlayContext) => {
  await ctx.click({ selector: "[data-rewind-local]:not(.cv-user__actions *)" });
  await ctx.waitFor(() => ctx.document.querySelector('.cv-rewind-ask[data-phase="ready"]'));
};

const LOOKS: LocalRewindLook[] = ["checks", "segmented", "inline"];
const STATES: State[] = ["checking", "available", "blocked", "running", "failed", "live"];

const variants = Object.fromEntries([
  ...LOOKS.flatMap((look) =>
    STATES.map((state) => [
      `${look}-${state}`,
      {
        note: `${localRewindConfirm.arms[look].label}${look === localRewindConfirm.defaultArm ? " (default)" : ""}. ${STATE_NOTES[state]}`,
        props: { look, state },
        ...(state === "live" ? { play: clickRewind } : {}),
      },
    ]),
  ),
  ["done", { note: STATE_NOTES.done, props: { look: localRewindConfirm.defaultArm, state: "done" as State } }],
]);

export default componentEntry<Props>({
  id: "agent-pane.local-rewind",
  title: "Back to before this turn (this machine)",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 360,
  widths: { narrow: 420, normal: 680, wide: 960 },
  covers: [
    "agent-session/acpmux/conversation/LocalRewind.tsx",
    "agent-session/acpmux/conversation/localRewind.experiment.ts",
  ],
  keywords: ["rewind", "undo turn", "back to before this turn", "checkpoint", "reset files"],
  styles: () => import("../styles.css"),
  load: async () => LocalRewindGallery,
  variants,
});
