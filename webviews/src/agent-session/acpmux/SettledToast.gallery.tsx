// l10n-allow-file: gallery fixture titles, not shipped UI.
// The toast a chat gets when acpmux settles it while the pane is open (settledToasts.ts): one per
// reason (pull request merged, closed, idle days, by hand), with Undo on a chat the pane holds and
// Open on any other, over the chat's foot above the composer like every pane toast
// (ToastLayer.gallery.tsx). In the pane it leaves after 5 s; the gallery holds it.
import { useMemo } from "react";
import { componentEntry } from "../../gallery/format";
import { minutesAgo } from "../../gallery/clock";
import { session } from "../../gallery/fixtures/acpmux";
import { createNoticeQueue } from "../../ui/NoticeStack";
import type { SettleReason } from "./sessionList";
import { settledToast } from "./settledToasts";
import { ToastLayer } from "./ToastLayer";

/// `held`: the pane holds the chat, so it has Undo (the default); false gives Open.
type Props = { reasons: SettleReason[]; remote?: boolean; held?: boolean };

const TITLES: Record<SettleReason, string> = {
  merged: "Make cache misses visible",
  closed: "Try a second retry policy",
  idle: "Investigate the build cache",
  manual: "Polish the sidebar",
};

const noop = () => undefined;

function SettledToastGallery({ reasons, remote, held = !remote }: Props) {
  const queue = useMemo(() => {
    const made = createNoticeQueue();
    for (const reason of reasons) {
      const entry = session({
        sessionId: `settled-${reason}`,
        title: TITLES[reason],
        archived: true,
        settled: reason,
        activityAt: minutesAgo(3 * 24 * 60 + 20),
        ...(remote && { peer: "build-box", host: "build-box", hostKind: "cloud" as const }),
      });
      // The gallery holds it: nothing times out under a capture.
      const actions = held ? { undo: noop, open: noop } : { open: noop };
      made.show({ ...settledToast(entry, actions), duration: 0 });
    }
    return made;
  }, [reasons, remote, held]);
  return (
    <div className="acpmux-shell toast-gallery">
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage toast-gallery-stage">
          <p className="toast-gallery-row">The pull request merged, and the chat's work is done.</p>
        </div>
        <div className="acpmux-dock">
          <ToastLayer queue={queue} />
          <div className="acpmux-composer">
            <div className="acpmux-composer-box ui-glass toast-gallery-composer">Ask for follow-up changes</div>
          </div>
        </div>
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.settled-toast",
  title: "Settled chat toast",
  area: "Agent pane",
  height: 320,
  pane: true,
  covers: ["agent-session/acpmux/settledToasts.ts#settledToast"],
  keywords: ["settle", "settled", "archive", "undo", "toast", "merged", "idle"],
  load: async () => SettledToastGallery,
  styles: () =>
    Promise.all([
      import("./styles.css"),
      import("./bottomStack.css"),
      import("../../ui/ui.css"),
      import("./ToastLayer.gallery.css"),
    ]),
  variants: {
    merged: { props: { reasons: ["merged"] }, note: "Its pull request merged: Settled, PR merged, with Undo." },
    closed: { props: { reasons: ["closed"] }, note: "Its pull request closed without merging." },
    idle: { props: { reasons: ["idle"] }, note: "Nothing happened in it for the configured idle days." },
    manual: { props: { reasons: ["manual"] }, note: "Settled by hand (`acpmux session settle`): no reason line." },
    open: {
      props: { reasons: ["merged"], held: false },
      note: "A chat this pane never showed: Open instead of Undo, since the app relays Unarchive only for a chat in the pane's scope; opening it brings it in.",
    },
    remote: {
      props: { reasons: ["idle"], remote: true },
      note: "A chat on another computer: Open, since Unsettle is a request to this Mac's acpmux.",
    },
    stacked: {
      props: { reasons: ["merged", "closed", "idle"] },
      note: "Three settled at once: the pane's deck, newest in front.",
    },
  },
});
