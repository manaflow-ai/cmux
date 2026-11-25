// l10n-allow-file: gallery fixtures, not shipped UI.
import { useState, type ReactNode } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { Spinner } from "./conversation/icons";
import {
  HostError,
  HostUnavailableLine,
  type ConnectionChipVariant,
  HostLineSlot,
  HostRecoveringLine,
} from "./HostError";

type Props = {
  message: string;
  /// The pane says the failure (hostRetry.ts `hostErrorShows`); false: it is still recovering.
  shown?: boolean;
  /// The folder harness card (a chat acpmux would not start) in place of the host line.
  harness?: { hint: string; action: string };
  initialRetrying: boolean;
  withRetry: boolean;
  withRestart?: boolean;
  /// acpmux's own words behind the line's Details (hostLine.ts).
  detail?: string;
  /// An alternate the gallery weighs for a chat whose machine is reconnecting, not shipped: a
  /// muted line (`text`) or a spinner with it (`spinner`). The pane shows nothing (`connecting`).
  connecting?: "text" | "spinner";
  /// The pane asks again by itself (HostUnavailableLine `selfRetrying`); false: a failure asking
  /// again cannot clear (a chat too large to open), which keeps its message and action.
  selfRetrying?: boolean;
  /// Alternates the gallery weighs for a long outage the pane recovers from by itself (the
  /// machine hosting the agent rebooting, Leo 2026-11-12), not shipped: the machine named
  /// (`named`), the time waited (`timed`), or the line before this change (`before`).
  outage?: "named" | "timed" | "before";
  /// The connection chip (HostError.tsx ConnectionChip) as a lost link past the 10 s bound draws it
  /// over a mock transcript and composer: `chip` is shipped, `dot` and `corner` are the alternates;
  /// `restoring` is the host's "Restoring sessions" as a chip.
  chip?: ConnectionChipVariant | "restoring";
};

/// The pane's dock around the host line: three transcript rows above, the composer under. The slot sits
/// between them, so a chip over it shows where the line is drawn and that the rows never move.
function MockDock({ children, slotted }: { children: ReactNode; slotted: boolean }) {
  return (
    <div className="acpmux-dock" style={{ width: "100%" }}>
      {[0.9, 0.7, 0.5].map((width) => (
        <p key={width} style={{ margin: "0 16px 8px", opacity: 0.7, width: `${width * 70}%` }}>
          A line of the chat above the composer
        </p>
      ))}
      {slotted ? <HostLineSlot>{children}</HostLineSlot> : children}
      <div
        style={{
          height: 44,
          margin: "0 16px",
          border: "1px solid color-mix(in srgb, currentColor 18%, transparent)",
          borderRadius: 12,
        }}
      />
    </div>
  );
}

/// The gallery's unshipped long-outage alternates, drawn with the shipped classes.
function AlternateOutage({ kind }: { kind: NonNullable<Props["outage"]> }) {
  if (kind === "before")
    return (
      <div className="acpmux-host-line-group" role="alert">
        <div className="acpmux-host-line">
          <p className="acpmux-host-line-message">Couldn't connect to the agent.</p>
          <button type="button">Retry</button>
        </div>
        <div className="acpmux-host-line">
          <p className="acpmux-host-line-note">
            cmux is still running, and your chats are kept. It keeps retrying on its own.
          </p>
        </div>
      </div>
    );
  return (
    <output className="acpmux-host-line">
      <p className="acpmux-host-line-message">{kind === "named" ? "Reconnecting to box…" : "Reconnecting… 2:41"}</p>
    </output>
  );
}

function GalleryHostError({
  message,
  shown = true,
  harness,
  initialRetrying,
  withRetry,
  withRestart,
  detail,
  connecting,
  selfRetrying,
  outage,
  chip,
}: Props) {
  const [retrying, setRetrying] = useState(initialRetrying);
  const [restarting, setRestarting] = useState(false);
  // What the pane draws out of flow goes in the slot; the alternates and the before lines are rows.
  const slotted = !outage && !connecting && !harness;
  return (
    <div className="acpmux-shell" data-host-error-fixture>
      <MockDock slotted={slotted}>
        {chip ? (
          <HostRecoveringLine
            linkDown
            restoring={chip === "restoring" ? { waitedMs: 12_000, at: 0 } : undefined}
            now={12_000}
            variant={chip === "restoring" ? undefined : chip}
          />
        ) : outage ? (
          <AlternateOutage kind={outage} />
        ) : connecting ? (
          <output className="acpmux-host-line" aria-live="polite">
            {connecting === "spinner" && <Spinner size={14} loading />}
            <span className="acpmux-host-line-message">{message}</span>
          </output>
        ) : harness ? (
          <HostError
            message={message}
            hint={harness.hint}
            action={harness.action}
            retrying={retrying}
            onRetry={() => setRetrying(true)}
          />
        ) : (
          shown && (
            <HostUnavailableLine
              message={message}
              detail={detail}
              retrying={retrying}
              onRetry={withRetry ? () => setRetrying(true) : undefined}
              restarting={restarting}
              onRestart={withRestart ? () => setRestarting(true) : undefined}
              selfRetrying={selfRetrying}
            />
          )
        )}
      </MockDock>
    </div>
  );
}

const retry: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Retry" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Retrying…" }).getAttribute("disabled") !== null);
};

const restart: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Restart agent service" });
  await ctx.waitFor(
    () => ctx.find({ role: "button", name: "Restarting agent service…" }).getAttribute("disabled") !== null,
  );
};

const details: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Details" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Details" }).getAttribute("aria-expanded") === "true");
};

const PEER_WORDS =
  "peer_unreachable: box (reconnecting, last seen 3m ago: connect timed out); the request was not sent; run `acpmux machine ls` and retry after the peer reconnects";

const enable: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Enable Claude Code" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Enable Claude Code" }).getAttribute("disabled") !== null);
};

export default componentEntry<Props>({
  id: "agent-pane.host-error",
  title: "Agent host error",
  area: "Agent pane",
  height: 250,
  widths: { narrow: 360, normal: 520, wide: 720 },
  anchors: [{ selector: "[data-host-error-fixture]" }],
  covers: ["agent-session/acpmux/HostError.tsx#HostError", "agent-session/acpmux/HostError.tsx#HostUnavailableLine"],
  styles: () => Promise.all([import("./styles.css"), import("./conversation/conversation.css")]).then(() => undefined),
  load: async () => GalleryHostError,
  variants: {
    reconnecting: {
      props: {
        message: "acpmux did not answer in time.",
        shown: false,
        initialRetrying: false,
        withRetry: true,
      },
      note: "While acpmux starts, restarts or is handed off by an update, the pane shows nothing: no card, no spinner, no button. The composer stays usable.",
    },
    // Leo, 2026-11-12, after the machine hosting the agent rebooted: "the recovery needs to be a lot
    // better and it shouldn't talk so much bullshit"; "try what? no, it should just automatically
    // do stuff". Picked: "automatic", one quiet line however long the outage, no button.
    // Leo, 2026-11-21: "these messages should not be pushing up the text... a small unobtrusive thing
    // somewhere without needing to block any content ... as a symbol or short thing, not a sentence.
    // stop layout shifting". Picked: "chip".
    chip: {
      props: { message: "", initialRetrying: false, withRetry: false, chip: "chip" },
      note: "Picked. A link down past 10 s: a dot and one word over the composer's top edge, out of flow, so the rows above never move (noLayoutShift.test.tsx). Nothing before 10 s.",
    },
    "chip-dot": {
      props: { message: "", initialRetrying: false, withRetry: false, chip: "dot" },
      note: "Alternate, not shipped: only the dot (its words are the label and tooltip). Least to look at, but a symbol alone is easy to miss and asks to be learned.",
    },
    "chip-corner": {
      props: { message: "", initialRetrying: false, withRetry: false, chip: "corner" },
      note: "Alternate, not shipped: the chip fixed in the pane's top end corner, away from the composer. Never over the text being read, but far from where the person is typing.",
    },
    "chip-restoring": {
      props: { message: "", initialRetrying: false, withRetry: false, chip: "restoring" },
      note: "The host's Restoring sessions, with its clock, as the same chip.",
    },
    automatic: {
      props: {
        message: "Couldn't connect to the agent.",
        initialRetrying: false,
        withRetry: true,
      },
      note: 'Picked. A recovery still failing after 25 s (a machine rebooting, an agent service starting): nothing shows; the pane keeps connecting (Leo, 2026-11-24: "let\'s just keep optimistically connecting"). No chip, no Retry, no Details, no reassurance; a message sent meanwhile waits in the composer and goes once the agent is back.',
    },
    "outage-named": {
      props: { message: "", initialRetrying: false, withRetry: false, outage: "named" },
      note: "Alternate, not shipped: names the machine. Truthful, but a chat's machine is not what the person is waiting on, and the name is long on narrow widths.",
    },
    "outage-timed": {
      props: { message: "", initialRetrying: false, withRetry: false, outage: "timed" },
      note: "Alternate, not shipped: a running clock. Makes a wait the person cannot shorten feel longer.",
    },
    "outage-before": {
      props: { message: "", initialRetrying: false, withRetry: false, outage: "before" },
      note: 'Before, not shipped: the failure in the host\'s words, Retry, and two reassurance sentences under it. Leo: "try what?"',
    },
    retry: {
      props: {
        message: "Update cmux to open this chat, then Retry.",
        initialRetrying: false,
        withRetry: true,
        selfRetrying: false,
      },
      play: retry,
      note: "A failure asking again cannot clear keeps its one small action, which asks again now.",
    },
    retrying: {
      props: {
        message: "Update cmux to open this chat, then Retry.",
        initialRetrying: true,
        withRetry: true,
        selfRetrying: false,
      },
    },
    long: {
      props: {
        message:
          "cmux cannot reach acpmux: it exited before it was ready. Its log is at /Users/someone/Library/Application Support/com.cmuxterm.app.next/acpmux/daemon.log.",
        initialRetrying: false,
        withRetry: true,
        selfRetrying: false,
      },
      note: "A long reason is cut to the one line; the whole text is its tooltip.",
    },
    restart: {
      props: {
        message: "acpmux belongs to cmux NIGHTLY, and this build may not use it. Quit that app, then try again.",
        initialRetrying: false,
        withRetry: true,
        withRestart: true,
      },
      play: restart,
      note: "Another build's acpmux holds this app's socket: a refusal said at once, with Restart acpmux as its one action.",
    },
    "restart-unnamed": {
      props: {
        message: "Another acpmux service is using this socket. It will reconnect when that service is ready.",
        initialRetrying: false,
        withRetry: true,
        withRestart: true,
      },
      note: "A refusal whose holder is no app bundle offers the same Restart acpmux.",
    },
    // A chat whose machine reconnects (Leo, 2026-10-30: "it was literally just loading. Then it gave
    // me that red message ... that's not the fucking right time to be showing that kind of fucking
    // message."). Picked: "peer-connecting", nothing at all, as every loading chat (#27541); the
    // prompt stays in the composer and goes once the machine is back.
    "peer-connecting": {
      props: { message: "Can't reach box.", shown: false, initialRetrying: false, withRetry: true },
      note: "Picked. A chat's machine reconnecting, slow or restarting: nothing shows, however long; the composer stays usable.",
    },
    "peer-connecting-text": {
      props: { message: "Connecting to box…", connecting: "text", initialRetrying: false, withRetry: false },
      note: "Alternate, not shipped: a muted line while the machine reconnects. Narrates routine state (composer.md rule 2).",
    },
    "peer-connecting-spinner": {
      props: { message: "Connecting to box…", connecting: "spinner", initialRetrying: false, withRetry: false },
      note: "Alternate, not shipped: a spinner and a muted line. Draws the eye to a wait the person cannot shorten.",
    },
    // The machine is still unreachable after two minutes (rebooting, Leo 2026-11-12): the pane keeps
    // asking by itself, so nothing shows. Picked: "peer-gone".
    "peer-gone": {
      props: { message: "Can't reach box.", detail: PEER_WORDS, initialRetrying: false, withRetry: true },
      note: "Picked. A machine unreachable for two minutes: nothing shows; acpmux's words and Retry never show, since the pane asks again by itself.",
    },
    "peer-gone-details": {
      props: {
        message: "Can't reach box.",
        detail: PEER_WORDS,
        initialRetrying: false,
        withRetry: true,
        selfRetrying: false,
      },
      play: details,
      note: "Before, not shipped: the plain line with Retry and Details open, acpmux's own words under it.",
    },
    "peer-gone-offline": {
      props: { message: "box is offline.", detail: PEER_WORDS, initialRetrying: false, withRetry: true },
      note: 'Alternate, not shipped: "offline" claims more than the pane knows (the machine may be up, its link down).',
    },
    "peer-gone-kept": {
      props: {
        message: "box isn't answering. Your message is kept.",
        detail: PEER_WORDS,
        initialRetrying: false,
        withRetry: true,
      },
      note: "Alternate, not shipped: says the draft is kept, which the composer already shows.",
    },
    "too-large": {
      props: {
        message: "Update cmux to open this chat, then Retry.",
        initialRetrying: false,
        withRetry: true,
        selfRetrying: false,
      },
      note: 'acpmux refused the chat\'s open as larger than one message (message.too_large, an acpmux before #28754): said at once in plain words, never the byte count, and the pane does not ask again on its own; Retry still asks (Leo, 2026-10-31: "this is completely hardlocked bc of message size").',
    },
    enable: {
      props: {
        message: "Claude Code is not enabled for this folder.",
        harness: { hint: "Enable the harness to continue this chat.", action: "Enable Claude Code" },
        initialRetrying: false,
        withRetry: true,
      },
      play: enable,
      note: "Folder harness setup keeps its card with a concrete action label.",
    },
  },
});
