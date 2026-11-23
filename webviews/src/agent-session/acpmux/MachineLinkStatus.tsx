import { useState } from "react";
import { useT, type Translate } from "./i18n";
import type { PeerLink } from "./peerLink";
import "./machineLinkStatus.css";

/// How the row draws a step a person must take on the link (gallery `agent-pane.machine-link`): the
/// step's words alone (`words`), the machine's name before them (`named`, shipped: a chat's machine is
/// named where its link is said, as the sidebar header names it), or only the dot, with the words in
/// its tooltip (`dot`).
export type MachineLinkLook = "dot" | "words" | "named";

/// What the row says for a link: only a step a person must take (a refused sign-in, an update the
/// machine needs), in the sidebar machine header's words; undefined for every state acpmux recovers
/// from by itself (connecting, reconnecting, degraded, restarting, offline, this Mac's own network).
export function linkWords(link: PeerLink, t: Translate): string | undefined {
  return link.stuck && link.why ? t(`machineLink.${link.why}`) : undefined;
}

/// The link of the machine a chat on another machine runs on, in the composer's quiet row (Leo,
/// 2026-10-28: "you just get a little green dot ... as if you were working on your own computer,
/// but now it's remote"). The dot alone, in its connected look, whatever the link is doing while
/// acpmux brings it back by itself: no spinner, no words, at any duration (Leo, 2026-11-22: "i dont
/// wanna see connecting to [machine]... with the spinner, i want it to just work"). A send made
/// meanwhile waits and goes once the machine answers; only one that has waited past the send
/// deadline says so, on its own message (conversation/PromptDelivery.tsx `LateDelivery`). A step a
/// person must take (a refused sign-in, an update) names the machine and the step at once. A chat
/// on this Mac draws nothing (`link` null).
///
/// One element from the first frame to the last, after the mode chip: the words grow from the
/// dot and fade in, so the model chip and the ring (anchored at the row's end) never move.
export function MachineLinkStatus({ link, look = "named" }: { link: PeerLink | null; look?: MachineLinkLook }) {
  const t = useT();
  const words = link ? linkWords(link, t) : undefined;
  const said = words !== undefined && look !== "dot";
  const name = link ? link.machine : "";
  // The last words said, kept while they fold away once the step is done, so the fold-out shows
  // what was said (state derived during render, not in an effect).
  const [shown, setShown] = useState({ words: words ?? "", name });
  if (said && words !== undefined && (shown.words !== words || shown.name !== name)) setShown({ words, name });
  if (!link) return null;
  const label = words ? `${name} · ${words}` : name;
  return (
    <output
      className="acpmux-machine-link"
      data-link={words ? link.link : "connected"}
      data-look={look}
      data-said={said ? "" : undefined}
      aria-live="polite"
      aria-label={label}
      // tooltip-allow: names the machine where the row draws only the dot.
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
          </span>
        </span>
      )}
    </output>
  );
}
