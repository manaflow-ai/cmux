// A participant's picture (participant-avatars-v1), or their initials on a neutral tile (the
// theme's foreground at low strength; no hue) when they have none.
// Agents get a rounded square, people a circle, so a glance tells them apart. A Chief's tile can
// carry its live state as a small mark on the corner (working: a quiet pulse; waiting: the one
// warning color). A channel is a hash tile with a hairline. A Chief with a picture shows it in the
// tile (PicturesContext: data URLs by participant id, read once per picture) until the avatar
// service has read it.
import { createContext, useContext } from "react";
import { useAvatarPicture } from "./avatars";
import type { ChiefState } from "./model";
import type { HomeParticipant } from "./types";
import { graphemePrefix, initials } from "../../ui/initials";

export { initials } from "../../ui/initials";

/** Pictures by participant id (the page's Chief records). */
export const PicturesContext = createContext<ReadonlyMap<string, string>>(new Map());

export function Avatar({
  participant,
  size = 20,
  state,
}: {
  participant?: HomeParticipant;
  size?: number;
  /** A Chief's live state, drawn on the tile's corner (idle draws nothing). */
  state?: ChiefState;
}) {
  const agent = participant?.kind === "agent";
  const fallback = useContext(PicturesContext).get(participant?.id ?? "");
  const picture = useAvatarPicture(participant?.id) ?? fallback;
  return (
    <span
      className={`hc-avatar${size >= 24 ? " large" : ""}${agent ? " agent" : ""}${participant?.chief ? " chief" : ""}${picture ? " picture" : ""}`}
      style={{ width: size, height: size }}
      aria-hidden="true"
    >
      {/* A small tile has room for one letter only. */}
      {picture ? (
        <img className="hc-avatar-img" src={picture} alt="" draggable={false} />
      ) : (
        graphemePrefix(initials(participant?.name ?? "?"), size >= 24 ? 2 : 1)
      )}
      {state && state !== "idle" && <span className={`lg-state-mark ${state}`} />}
    </span>
  );
}

export function ChannelMark({ size = 20 }: { size?: number }) {
  return (
    <span className="lg-channel-mark" style={{ width: size, height: size }} aria-hidden="true">
      #
    </span>
  );
}
