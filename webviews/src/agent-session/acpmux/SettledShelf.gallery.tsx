// l10n-allow-file: gallery fixture titles, not shipped UI.
// The new chat home's Settled shelf (SettledShelf.tsx): collapsed to "Settled N" by default, opened
// to the settled chats newest first, each with why it settled; a click opens the chat. Only chats the
// pane holds have Unsettle (here "Try a second retry policy" was never shown in this pane, and
// "Release notes" is on another computer). With no settled chat there is no shelf.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { minutesAgo } from "../../gallery/clock";
import { session } from "../../gallery/fixtures/acpmux";
import type { Play } from "../../gallery/play";
import { settledShelf } from "./settledChats";
import { SettledShelf } from "./SettledShelf";
import type { AcpmuxSessionEntry } from "./sessionList";

type Props = { sessions: AcpmuxSessionEntry[]; open?: boolean };

const DAY = 24 * 60;
const settled: AcpmuxSessionEntry[] = [
  session({
    sessionId: "shelf-merged",
    title: "Make cache misses visible",
    archived: true,
    settled: "merged",
    activityAt: minutesAgo(40),
  }),
  session({
    sessionId: "shelf-closed",
    title: "Try a second retry policy",
    archived: true,
    settled: "closed",
    activityAt: minutesAgo(5 * 60),
  }),
  session({
    sessionId: "shelf-idle",
    title: "Reconcile the payment ledger against the processor export before the quarterly close",
    archived: true,
    settled: "idle",
    activityAt: minutesAgo(7 * DAY + 30),
  }),
  session({
    sessionId: "shelf-remote",
    title: "Release notes",
    archived: true,
    settled: "merged",
    peer: "build-box",
    host: "build-box",
    hostKind: "cloud",
    activityAt: minutesAgo(2 * DAY),
  }),
  session({ sessionId: "shelf-manual", title: "Polish the sidebar", archived: true, settled: "manual" }),
];
// Never on the shelf: a plain Archive (no reason), a listed chat, a settled side chat.
const others: AcpmuxSessionEntry[] = [
  session({ sessionId: "shelf-archived", title: "An archived chat", archived: true }),
  session({ sessionId: "shelf-live", title: "A listed chat" }),
  session({ sessionId: "shelf-side", title: "A side chat", side: true, archived: true, settled: "idle" }),
];

// The chats this pane showed before (so the app's relay holds them in its scope): only these have Unsettle.
const HELD = new Set(["shelf-merged", "shelf-idle", "shelf-manual"]);
const holds = (entry: AcpmuxSessionEntry) => !entry.peer && HELD.has(entry.sessionId);

function SettledShelfGallery({ sessions, open }: Props) {
  const [unsettled, setUnsettled] = useState<string>();
  const { rows, total } = settledShelf(sessions);
  return (
    <section className="acpmux-shell settled-shelf-gallery" data-unsettled={unsettled ?? ""}>
      <div className="acpmux-main" data-new-chat="">
        <div className="acpmux-dock">
          <div className="acpmux-home-area">
            <div className="acpmux-home">
              <SettledShelf
                rows={rows}
                total={total}
                open={open}
                onSelect={() => undefined}
                onUnsettle={(entry) => setUnsettled(entry.sessionId)}
                holds={holds}
              />
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

const expand: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /Settled/ });
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(".acpmux-settled-shelf[data-open]")));
};

const unsettle: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-settled-unsettle" });
  await ctx.waitFor(() =>
    Boolean(ctx.document.querySelector(".settled-shelf-gallery")?.getAttribute("data-unsettled")),
  );
};

export default componentEntry<Props>({
  id: "agent-pane.settled-shelf",
  title: "Settled shelf",
  area: "Agent pane",
  pane: true,
  height: 360,
  widths: { narrow: 360, normal: 560, wide: 760 },
  covers: ["agent-session/acpmux/SettledShelf.tsx#SettledShelf"],
  keywords: ["settle", "settled", "archive", "unsettle", "home", "shelf"],
  styles: () => Promise.all([import("./styles.css"), import("../../ui/ui.css")]),
  load: async () => SettledShelfGallery,
  variants: {
    collapsed: {
      props: { sessions: [...settled, ...others] },
      note: "Shipped default: one Settled row with the count, under the home's other lists.",
    },
    expanded: {
      props: { sessions: [...settled, ...others], open: true },
      note: "Opened: newest first, why each settled, Unsettle only on the chats this pane holds.",
    },
    "expand-click": {
      props: { sessions: [...settled, ...others] },
      play: expand,
      note: "The Settled row opens the shelf in place; nothing above it moves.",
    },
    "unsettle-click": {
      props: { sessions: [...settled, ...others], open: true },
      play: unsettle,
      note: "Unsettle on a row: the chat goes back on every list (here it marks the frame).",
    },
    empty: {
      props: { sessions: others },
      note: "No settled chat: no shelf at all (a plain Archive, a listed chat and a side chat never show).",
    },
  },
});
