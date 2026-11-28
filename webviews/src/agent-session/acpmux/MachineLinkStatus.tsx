import { useState } from "react";
import { useLinkDownSaid } from "./afterDelay";
import { useT, type Translate } from "./i18n";
import type { PeerLink } from "./peerLink";
import "./machineLinkStatus.css";

/// How the row draws a link that is not connected (gallery `agent-pane.machine-link`): the state's
/// word alone (`words`), the machine's name before it (`named`, shipped: a chat's machine is named
/// where its link is said, as the sidebar header names it), or only the dot, with the words in its
/// tooltip (`dot`).
export type MachineLinkLook = "dot" | "words" | "named";

/// acpmux's peer link state in the sidebar machine header's words ("Reconnecting…", "Offline"), or what
/// is wrong when acpmux knows (a refused sign-in, an update, this Mac's own network).
export function linkWords(link: PeerLink, t: Translate): string {
  if (link.why) return t(`machineLink.${link.why}`);
  switch (link.link) {
    case "connected":
      return t("machineLink.connected");
    case "connecting":
      return t(link.reconnecting ? "machineLink.reconnecting" : "machineLink.connecting");
    case "offline":
      return t("machineLink.offline");
  }
}

/// The link of the machine a chat on another machine runs on, in the composer's quiet row (Leo,
/// 2026-10-28: "you just get a little green dot ... as if you were working on your own computer,
/// but now it's remote"). Connected is the dot alone, and so is a link connecting or reconnecting on
/// its own (Leo, 2026-11-24); down names the machine and its state in the danger ink with Reconnect,
/// and a reason acpmux knows (a refused sign-in, an update, this Mac's network) is said. A chat on this Mac draws nothing (`link` null).
///
/// One element from the first frame to the last, after the mode chip: the words grow from the
/// dot and fade in, so the model chip and the ring (anchored at the row's end) never move, and
/// coming back fades the words out, leaving the dot.
export function MachineLinkStatus({
  link,
  look = "named",
  onReconnect,
  quietMs,
}: {
  link: PeerLink | null;
  look?: MachineLinkLook;
  /// How long a link that comes back on its own stays unsaid (afterDelay.ts `LINK_DOWN_SAID_MS`); the
  /// gallery passes 0 to draw each state at once.
  quietMs?: number;
  onReconnect?(link: PeerLink): Promise<unknown> | void;
}) {
  const t = useT();
  // The link a Reconnect was pressed on: it reads as in flight until it answers or the link moves on
  // its own (another state or machine), whichever comes first.
  const [pressed, setPressed] = useState<string>();
  // A link that is not up and needs no person stays the plain dot until it has been down past the
  // bound (Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up"): a drop that
  // heals within it draws nothing, one that lasts is said once, here. A refused sign-in or an update
  // the machine needs is said at once.
  const waits = link !== null && link.link !== "connected" && !link.stuck;
  const due = useLinkDownSaid(waits, link?.since, quietMs);
  // A link still dialing that needs no person is the plain dot however long it takes (Leo, 2026-11-24:
  // "all the connecting... indicators and the graying out of workspaces, nah let's not do that. let's
  // just keep optimistically connecting"): no spinner, no Connecting or Reconnecting. A link down
  // (offline) still says so past the bound, with Reconnect; a refused sign-in or an update at once.
  const onItsWay = link !== null && link.link === "connecting" && !link.why && !link.stuck;
  const quiet = onItsWay || (waits && !due);
  // The last words said, kept while they fold away on a link that came back, so the fold-out shows
  // what was said rather than "Connected" (state derived during render, not in an effect).
  const words = link ? linkWords(link, t) : "";
  const said = link !== null && link.link !== "connected" && !quiet && look !== "dot";
  const name = link ? link.machine : "";
  const [shown, setShown] = useState({ words, name });
  if (said && (shown.words !== words || shown.name !== name)) setShown({ words, name });
  if (!link) return null;
  const down = link.link === "offline";
  const at = `${link.machine}\n${link.link}`;
  const busy = pressed === at;
  const label = `${name} · ${words}`;
  return (
    <output
      className="acpmux-machine-link"
      data-link={link.link}
      data-look={look}
      data-said={said ? "" : undefined}
      data-quiet={quiet ? "" : undefined}
      aria-live="polite"
      aria-label={label}
      // tooltip-allow: names the machine and its link where the row draws only the dot.
      title={said ? undefined : label}
    >
      <span className="acpmux-machine-link-mark" aria-hidden="true">
        <span className="acpmux-machine-link-dot" />
      </span>
      {look !== "dot" && (
        // Folds open from the dot and closed into it (grid track 0fr to 1fr) while it fades.
        <span className="acpmux-machine-link-fold">
          <span className="acpmux-machine-link-words">
            <span aria-hidden="true" className="acpmux-machine-link-said">
              {look === "named" && <span className="acpmux-machine-link-name">{shown.name}</span>}
              <span className="acpmux-machine-link-state">{shown.words}</span>
            </span>
            {down && !link.stuck && onReconnect && (
              <button
                type="button"
                className="acpmux-machine-link-reconnect"
                disabled={busy}
                onClick={() => {
                  if (busy) return;
                  setPressed(at);
                  const settle = () => setPressed((current) => (current === at ? undefined : current));
                  Promise.resolve(onReconnect(link)).then(settle, settle);
                }}
              >
                {busy ? t("machineLink.reconnecting") : t("machineLink.reconnect")}
              </button>
            )}
          </span>
        </span>
      )}
    </output>
  );
}
