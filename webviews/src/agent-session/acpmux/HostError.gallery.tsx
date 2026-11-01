// l10n-allow-file: gallery fixtures, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { Spinner } from "./conversation/icons";
import { HostError, HostUnavailableLine, HostWaitingLine } from "./HostError";

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
  /// The waiting line in place of the host line: how long the pane has waited for acpmux, in ms.
  waitedMs?: number;
};

function GalleryHostError({
  message,
  shown = true,
  harness,
  initialRetrying,
  withRetry,
  withRestart,
  detail,
  connecting,
  waitedMs,
}: Props) {
  const [retrying, setRetrying] = useState(initialRetrying);
  const [restarting, setRestarting] = useState(false);
  return (
    <div className="acpmux-shell" data-host-error-fixture>
      {connecting ? (
        <output className="acpmux-host-line" aria-live="polite">
          {connecting === "spinner" && <Spinner size={14} loading />}
          <span className="acpmux-host-line-message">{message}</span>
        </output>
      ) : waitedMs !== undefined ? (
        <HostWaitingLine since={0} now={waitedMs} restarting={restarting} onRestart={() => setRestarting(true)} />
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
          />
        )
      )}
    </div>
  );
}

const retry: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Retry" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Retrying…" }).getAttribute("disabled") !== null);
};

const restart: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Restart acpmux" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Restarting acpmux…" }).getAttribute("disabled") !== null);
};

const details: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Details" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Details" }).getAttribute("aria-expanded") === "true");
};

const PEER_WORDS =
  "peer_unreachable: box (reconnecting, last seen 3m ago: connect timed out); the request was not sent; run `acpmux host ls` and retry after the peer reconnects";

const restartService: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Restart agent service" });
  await ctx.waitFor(
    () => ctx.find({ role: "button", name: "Restarting agent service…" }).getAttribute("disabled") !== null,
  );
};

const enable: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Enable Claude Code" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Enable Claude Code" }).getAttribute("disabled") !== null);
};

export default componentEntry<Props>({
  id: "agent-pane.host-error",
  title: "Agent host error",
  area: "Agent pane",
  height: 210,
  widths: { narrow: 360, normal: 520, wide: 720 },
  anchors: [{ selector: "[data-host-error-fixture]" }],
  covers: [
    "agent-session/acpmux/HostError.tsx#HostError",
    "agent-session/acpmux/HostError.tsx#HostUnavailableLine",
    "agent-session/acpmux/HostError.tsx#HostWaitingLine",
  ],
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
    automatic: {
      props: {
        message: "acpmux did not answer in time.",
        initialRetrying: false,
        withRetry: false,
      },
      note: "A recovery still failing after 25 s: one line in the host's words, no recovery steps.",
    },
    retry: {
      props: {
        message: "acpmux did not answer in time.",
        initialRetrying: false,
        withRetry: true,
      },
      play: retry,
      note: "The late line's one small action asks again now.",
    },
    retrying: {
      props: {
        message: "acpmux did not answer in time.",
        initialRetrying: true,
        withRetry: true,
      },
    },
    long: {
      props: {
        message:
          "cmux cannot reach acpmux: it exited before it was ready. Its log is at /Users/someone/Library/Application Support/com.cmuxterm.app.next/acpmux/daemon.log.",
        initialRetrying: false,
        withRetry: true,
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
    // The machine is still unreachable after two minutes: the person may act. One plain line, Retry,
    // and acpmux's own words only behind Details. Picked: "peer-gone".
    "peer-gone": {
      props: { message: "Can't reach box.", detail: PEER_WORDS, initialRetrying: false, withRetry: true },
      note: "Picked. A machine unreachable for two minutes: one plain line with Retry; acpmux's own words only behind Details.",
    },
    "peer-gone-details": {
      props: { message: "Can't reach box.", detail: PEER_WORDS, initialRetrying: false, withRetry: true },
      play: details,
      note: "The picked line with Details open: acpmux's own words, muted, under the line.",
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
        message: "This chat is too large to open. Update acpmux, then Retry.",
        initialRetrying: false,
        withRetry: true,
      },
      note: 'acpmux refused the chat\'s open as larger than one message (message.too_large, an acpmux before #28754): said at once in plain words, never the byte count, and the pane does not ask again on its own; Retry still asks (Leo, 2026-10-31: "this is completely hardlocked bc of message size").',
    },
    waiting: {
      props: { message: "", initialRetrying: false, withRetry: false, waitedMs: 95_000 },
      play: restartService,
      note: "acpmux is slow to answer (a loaded Mac): the app never restarts it by itself. After 25 s the line says how long the pane has waited, and the person may restart the agent service.",
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
