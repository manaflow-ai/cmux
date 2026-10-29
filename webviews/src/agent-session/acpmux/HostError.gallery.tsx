// l10n-allow-file: gallery fixtures, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { HostError, HostUnavailableLine } from "./HostError";

type Props = {
  message: string;
  /// The pane says the failure (hostRetry.ts `hostErrorShows`); false: it is still recovering.
  shown?: boolean;
  /// The folder harness card (a chat acpmux would not start) in place of the host line.
  harness?: { hint: string; action: string };
  initialRetrying: boolean;
  withRetry: boolean;
  withRestart?: boolean;
};

function GalleryHostError({ message, shown = true, harness, initialRetrying, withRetry, withRestart }: Props) {
  const [retrying, setRetrying] = useState(initialRetrying);
  const [restarting, setRestarting] = useState(false);
  return (
    <div className="acpmux-shell" data-host-error-fixture>
      {harness ? (
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
