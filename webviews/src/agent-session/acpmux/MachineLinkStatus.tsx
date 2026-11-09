import { useState } from "react";
import { Spinner } from "./conversation/icons";
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
/// but now it's remote"). Connected is the dot alone; connecting or reconnecting turns the dot into
/// a spinner in the dot's own box and names the machine and its state; down names them in the
/// danger ink with Reconnect. A chat on this Mac draws nothing (`link` null).
///
/// One element from the first frame to the last, after the mode chip: the words grow from the
/// dot and fade in, so the model chip and the ring (anchored at the row's end) never move, and
/// coming back fades the words out, leaving the dot.
export function MachineLinkStatus({
  link,
  look = "named",
  onReconnect,
}: {
  link: PeerLink | null;
  look?: MachineLinkLook;
  onReconnect?(link: PeerLink): Promise<unknown> | void;
}) {
  const t = useT();
  // The link a Reconnect was pressed on: it reads as in flight until it answers or the link moves on
  // its own (another state or machine), whichever comes first.
  const [pressed, setPressed] = useState<string>();
  // The last words said, kept while they fold away on a link that came back, so the fold-out shows
  // what was said rather than "Connected" (state derived during render, not in an effect).
  const words = link ? linkWords(link, t) : "";
  const said = link !== null && link.link !== "connected" && look !== "dot";
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
      aria-live="polite"
      aria-label={label}
      // tooltip-allow: names the machine and its link where the row draws only the dot.
      title={said ? undefined : label}
    >
      <span className="acpmux-machine-link-mark" aria-hidden="true">
        <span className="acpmux-machine-link-dot" />
        {link.link === "connecting" && <Spinner size={12} loading className="acpmux-machine-link-spinner" />}
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
