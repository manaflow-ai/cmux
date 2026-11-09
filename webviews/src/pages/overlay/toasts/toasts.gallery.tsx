// l10n-allow-file: gallery fixtures, not shipped UI.
// The app's toast stack (overlay page route /toasts, ToastStack.tsx): the states the app sends
// (`cmux.overlay.toasts.state`), drawn by the real stack over a pane. Light and dark are the gallery's
// theme axis. Compared beside cmux/live/sidebar-workspace-close-race-toasts and
// cmux/live/composer-empty-checklist-toast (cmux-design-references) in three looks: one row with a bold
// text action (kept: it is the live toast's shape), a roomier card, and a capsule row with a filled
// action chip (a second surface inside the toast, which the toast rules refuse).
import { useMemo, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { createStrings } from "../../shared/i18n";
import table from "./generated/strings.json";
import { ToastStack } from "./ToastStack";
import type { ToastState } from "./types";

type Props = { toasts: ToastState[]; floor?: number };

const toast = (serial: number, message: string, more: Partial<ToastState> = {}): ToastState => ({
  serial,
  id: `t${serial}`,
  message,
  closable: true,
  showsDetails: false,
  showsUndoKey: false,
  ...more,
});
const undo = { title: "Undo", isUndo: true, revealsDetails: false };
const details = { title: "Details", isUndo: false, revealsDetails: true };
const moving = "Moving this chat to Cloud…";
const back = "Bringing this chat back to this Mac…";
const copying = "Copying the folder (1,204 files) · about 45 s left";
const sentence = "Moving this chat to Cloud: copying the folder (1,204 files), about 45 s left.";
const noSpace = "cannot copy the build to the machine: fs.no_space: no space left on the device";

function ToastsGallery({ toasts, floor = 16 }: Props) {
  const words = useMemo(() => createStrings(table), []);
  // Details opens and closes in place, as the app answers the button.
  const [open, setOpen] = useState(
    () => new Set(toasts.filter((item) => item.showsDetails).map((item) => item.serial)),
  );
  const [closed, setClosed] = useState(() => new Set<number>());
  const shown = toasts
    .filter((item) => !closed.has(item.serial))
    .map((item) => ({ ...item, showsDetails: open.has(item.serial) }));
  return (
    <div className="cmux-toasts-gallery">
      <ToastStack
        toasts={shown}
        floor={floor}
        words={words}
        onAction={(serial) => {
          const item = toasts.find((candidate) => candidate.serial === serial);
          if (!item?.action?.revealsDetails) return setClosed((now) => new Set(now).add(serial));
          setOpen((now) => {
            const next = new Set(now);
            if (!next.delete(serial)) next.add(serial);
            return next;
          });
        }}
        onClose={(serial) => setClosed((now) => new Set(now).add(serial))}
        onHover={() => undefined}
        onLayout={() => undefined}
      />
    </div>
  );
}

const three = [
  toast(1, "The workspace could not be closed."),
  toast(2, "Moved this chat to Cloud machine dev."),
  toast(3, "Closed 8 workspaces", { action: undo, showsUndoKey: true }),
];

export default componentEntry<Props>({
  id: "overlay.toasts",
  title: "Toasts",
  area: "Overlays",
  height: 360,
  widths: { narrow: 360, normal: 720, wide: 1100 },
  covers: ["pages/overlay/toasts/ToastStack.tsx", "pages/overlay/toasts/useToastMotion.ts"],
  load: async () => ToastsGallery,
  styles: async () => {
    await import("../../shared/pageBase.css");
    await import("./toasts.gallery.css");
  },
  variants: {
    one: { note: "One toast: the message and its close button.", props: { toasts: [toast(1, "Copied the link.")] } },
    "three-stacked": { note: "Three toasts, newest at the bottom; only its Undo shows ⌘Z.", props: { toasts: three } },
    undo: {
      note: "An undo toast: Undo runs the inverse once; Cmd-Z runs it too.",
      props: { toasts: [toast(1, "Closed “zsh”", { action: undo, showsUndoKey: true })] },
    },
    "details-closed": {
      note: "A failure with Details: the reason stays out of the toast until asked for.",
      props: { toasts: [toast(1, "Couldn't update fs-lane-3", { action: details, detail: noSpace })] },
    },
    "details-open": {
      note: "Details on: the reason in plain words, the code under it, Hide Details a quiet link.",
      props: {
        toasts: [toast(1, "Couldn't update fs-lane-3", { action: details, detail: noSpace, showsDetails: true })],
      },
    },
    "details-open-stacked": {
      note: "Details on under two other toasts: the toasts above stack on its real height.",
      props: {
        toasts: [
          toast(1, "Copied the link."),
          toast(2, "Closed 8 workspaces", { action: undo, showsUndoKey: true }),
          toast(3, "Couldn't update 3 machines", {
            action: details,
            detail:
              "lab-mini: the SSH connection timed out\nfs-lane-3: fs.no_space\ndev: cmux too old to update in place",
            showsDetails: true,
          }),
        ],
      },
    },
    "long-text": {
      note: "A long message wraps at three lines; its whole text is the toast's label.",
      props: {
        toasts: [
          toast(1, "Restart cmux-tui to use new features", {
            action: { title: "Restart cmux-tui", isUndo: false, revealsDetails: false },
          }),
          toast(
            2,
            "Stopped all agents: a1 and a3. 1 could not be stopped: a2 refused because it is still starting; it stops as soon as it starts, and its subagents stop with it.",
          ),
        ],
      },
    },
    // Move to Cloud's working toast (CloudMove.swift; the line is Rust's moves::progress). Leo,
    // 2026-11-09: "the ergonomic part is super big for us." Four ways to say the step and the time
    // left, then the pick (two lines: the headline as before, then step, why and about how long)
    // through the move's stages.
    "move-before": {
      note: "Before: the headline alone until the move ends, with no step and no time.",
      props: { toasts: [toast(1, moving)] },
    },
    "move-a-one-sentence": {
      note: "A: one sentence. The step hides mid-sentence and the wrap moves as it changes.",
      props: { toasts: [toast(1, sentence)] },
    },
    "move-b-two-lines": {
      note: "B (picked): the headline stays put; the line under it says the step, why and how long.",
      props: { toasts: [toast(1, `${moving}\n2 of 4 · ${copying}`)] },
    },
    "move-c-terse": {
      note: "C: the step only, terse. One line, but it drops what moves and reads like a log.",
      props: { toasts: [toast(1, "2/4 Copying the folder (1,204 files) ~45 s")] },
    },
    "move-d-time-only": {
      note: "D: the time in the message, the step in the tooltip: the reason is off screen.",
      props: {
        toasts: [
          toast(1, "Moving this chat to Cloud, about 45 s left", {
            detail: "Copying the folder (1,204 files)",
          }),
        ],
      },
    },
    "move-b-stages": {
      note: "B through a move to a new machine: each step replaces the line in place.",
      props: {
        toasts: [
          toast(1, `${moving}\n1 of 4 · Starting a new Cloud machine · about 1 min left`),
          toast(2, `${moving}\n3 of 4 · Handing the agent to dev · about 15 s left`),
          toast(3, `${moving}\n4 of 4 · Opening its tab · a few seconds left`),
        ],
      },
    },
    "move-b-slow-and-back": {
      note: "B when a step runs long (no made-up time), and Bring Back Local.",
      props: {
        toasts: [
          toast(
            1,
            `${moving}\n1 of 4 · Resuming dev · taking longer than usual (usually about 30 s)`,
          ),
          toast(2, `${back}\n2 of 4 · Copying the folder back (38 files) · about 20 s left`),
        ],
      },
    },
    "above-composer": {
      note: "The stack rests above the message box (the app's floor), never over it.",
      props: { toasts: three, floor: 120 },
    },
  },
});
