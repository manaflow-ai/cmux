// l10n-allow-file: gallery fixtures (sample prompts, replies and commands), not shipped UI.
// A chat followed at its bottom holds still while it ticks (Leo, 2026-11-18, with a recording of his
// NIGHTLY: "did we fix this scroll bounce at the bottom yet?"). His chat sat at the bottom with a
// running command ("cmux-ci submit … 8m 3s"), a background command in the composer's tray and
// a line over the composer saying how long acpmux had kept it waiting, every clock
// counting up each second while acpmux was slow, and the transcript jumped 30–70 px up and down every
// second or so while he did not scroll. Each play step waits 10 s at the bottom; the second re-sends
// the same chat every 1.2 s, as a slow acpmux's snapshots arrive. The shift matrix measures each
// step (gallery/shift.ts), and the play judges the same frames with the held-bottom detector
// (`startHeldTracker`): no transcript row may move from where it was by more than half a pixel, and
// Jump to latest never shows.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { GALLERY_NOW, minutesAgo } from "../../gallery/clock";
import { activity, assistant, chat, tool, user } from "../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../gallery/play";
import { startHeldTracker } from "../../gallery/shift";
import type { AcpmuxRow, AcpmuxSnapshot } from "./model";
import { JUMP_LATEST_SHOWN, TRANSCRIPT_ROW } from "./transcriptSelectors";

const SUBMIT = "cmux-ci submit --kind cmux --label macos-26 --request-key kit-macos-build-43360-31";
const BACKGROUND = "wt new cmux leo/checkout --topic build";

/// The chat, the same rows (ids included) on every call: a re-sent copy is the same chat.
function tickingChat(): AcpmuxSnapshot {
  const rows: AcpmuxRow[] = [];
  for (let n = 0; n < 24; n++) {
    const at = 90 - n * 3;
    rows.push(user(`Question ${n + 1}: is the build on the merged head green yet?`, at, { id: `ticking-user-${n}` }));
    rows.push(
      assistant(
        `Answer ${n + 1}: the checks on the merged head are green. The macOS build job ran on the fleet and its receipt is attached to the pull request, with the test summary under it.`,
        at - 1,
        { id: `ticking-reply-${n}` },
      ),
    );
  }
  rows.push(user("Read why the macOS build job failed, then rerun it.", 12, { id: "ticking-user-last" }));
  rows.push(
    activity(
      [
        tool("Read why the macOS build job failed", "read", "completed", { id: "ticking-read" }),
        tool(SUBMIT, "execute", "in_progress", {
          id: "ticking-submit",
          command: SUBMIT,
          inputSummary: JSON.stringify({ command: SUBMIT }),
          startedAt: GALLERY_NOW - (8 * 60 + 3) * 1000,
        }),
        tool(BACKGROUND, "execute", "completed", {
          id: "ticking-background",
          command: BACKGROUND,
          inputSummary: JSON.stringify({ command: BACKGROUND, run_in_background: true }),
          startedAt: minutesAgo(11),
          background: { state: "running" },
        }),
      ],
      11,
      { id: "ticking-run" },
    ),
  );
  return chat(rows, {
    title: "Ticking bottom",
    isWorking: true,
    // acpmux slow for 1:48; `holdStill` puts the quiet Reconnecting… chip over the composer.
    daemonWaitingSince: GALLERY_NOW - 108_000,
  });
}

/// Holds 10 s at the bottom, re-sending the chat every `resendMs` when given, and throws when a
/// transcript row drifts or Jump to latest shows.
async function holdStill(ctx: PlayContext, resendMs?: number) {
  const doc = ctx.document;
  // The chip shows only while a connect attempt has failed for real (App.tsx `linkDown`), which no
  // snapshot field can set, so put ConnectionChip's markup (HostError.tsx) in the dock's host slot as
  // agent-pane-ticking-bottom-still.test.ts does.
  await ctx.waitFor(() => doc.querySelector(".acpmux-dock [data-host-slot]"), { capMs: 10_000 });
  if (!doc.querySelector("[data-host-recovering=reconnecting]")) {
    const chip = doc.createElement("output");
    chip.className = "acpmux-host-chip";
    chip.dataset.hostRecovering = "reconnecting";
    chip.dataset.chip = "chip";
    chip.innerHTML =
      '<span class="acpmux-host-chip-dot" aria-hidden="true"></span><span class="acpmux-host-chip-words">Reconnecting…</span>';
    doc.querySelector(".acpmux-dock [data-host-slot]")!.append(chip);
  }
  await ctx.waitFor(() => doc.querySelectorAll(TRANSCRIPT_ROW).length > 4, { capMs: 10_000 });
  const win = doc.defaultView!;
  const bridge = (win as unknown as { cmuxAcpmuxBridge?: { receive(snapshot: AcpmuxSnapshot): void } })
    .cmuxAcpmuxBridge;
  const snapshot = tickingChat();
  const resend = resendMs ? win.setInterval(() => bridge?.receive(structuredClone(snapshot)), resendMs) : undefined;
  const held = startHeldTracker(doc);
  let jump = false;
  const start = win.performance.now();
  try {
    await ctx.waitFor(
      () => {
        if (doc.querySelector(JUMP_LATEST_SHOWN)) jump = true;
        return win.performance.now() - start >= 10_000;
      },
      { capMs: 12_000 },
    );
  } finally {
    if (resend !== undefined) win.clearInterval(resend);
  }
  const drift = held.stop();
  if (drift.worst > 0)
    throw new Error(
      `the transcript moved ${drift.worst} px at the bottom (${drift.label}, frame ${drift.frame}; ${drift.driftFrames} frames off)`,
    );
  if (jump) throw new Error("Jump to latest showed while the chat ticked at its bottom");
}

const variant = (resendMs?: number): AgentPaneVariant => ({
  note: resendMs
    ? "Play: 10 s at the bottom while the same chat is re-sent every 1.2 s, as a slow acpmux's snapshots arrive. No row moves."
    : "Play: 10 s at the bottom while the waiting line, the running command and the tray count up. No row moves.",
  snapshot: tickingChat(),
  play: (ctx) => holdStill(ctx, resendMs),
});

export default agentPaneEntry({
  id: "agent-pane.ticking-bottom-still",
  title: "Ticking chat holds still at the bottom",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 420, normal: 760, wide: 900 },
  anchors: [{ selector: ".acpmux-composer-box" }],
  covers: ["agent-session/acpmux/VirtualTranscript.tsx"],
  variants: {
    ticking: variant(),
    "ticking-resent": variant(1200),
  },
});
