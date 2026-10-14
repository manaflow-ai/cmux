// Participants' pictures in the Channels view (participant-avatars-v1): one picture per person or
// Chief, read once per participant through the page client (`cmux.home.avatar`: the daemon's
// `participant.avatar.get`, or the Cloud owner's through `cloud-participant-avatar-get`) and shown
// as a data URL (any page policy). A `participant-avatar-changed` event drops the participant's
// cached picture, so the next render reads the new one. No picture: the tile keeps its initials.
import { useContext, useEffect, useState, createContext } from "react";
import type { PageClient } from "../shared/pageClient";
import { HomeOps } from "./types";

interface AvatarReply {
  avatar: { sha256: string; mediaType: string; data: string } | null;
}

/** At most this many pictures are kept (the least recently read goes first). */
const MAX_KEPT = 256;

export class AvatarService {
  private readonly pictures = new Map<string, Promise<string | null>>();
  private readonly listeners = new Map<string, Set<() => void>>();

  constructor(private readonly client: PageClient) {}

  /** The participant's picture as a data URL, or null (none, or an older host). */
  picture(participant: string): Promise<string | null> {
    let found = this.pictures.get(participant);
    if (found) {
      this.pictures.delete(participant);
    } else {
      found = this.client
        .call<AvatarReply>(HomeOps.avatar, { participant })
        .then((reply) => (reply?.avatar ? `data:${reply.avatar.mediaType};base64,${reply.avatar.data}` : null))
        .catch(() => null);
    }
    this.pictures.set(participant, found);
    while (this.pictures.size > MAX_KEPT) this.pictures.delete(this.pictures.keys().next().value!);
    return found;
  }

  /** A participant's picture changed: read it again and redraw its tiles. */
  changed(participants: readonly string[]): void {
    for (const participant of participants) {
      this.pictures.delete(participant);
      for (const listener of this.listeners.get(participant) ?? []) listener();
    }
  }

  watch(participant: string, listener: () => void): () => void {
    let set = this.listeners.get(participant);
    if (!set) this.listeners.set(participant, (set = new Set()));
    set.add(listener);
    return () => {
      set.delete(listener);
      if (set.size === 0) this.listeners.delete(participant);
    };
  }
}

export const AvatarContext = createContext<AvatarService | undefined>(undefined);

/** The picture of `participant` (a data URL), or null while unknown or absent. */
export function useAvatarPicture(participant: string | undefined): string | null {
  const service = useContext(AvatarContext);
  const [picture, setPicture] = useState<string | null>(null);
  const [generation, setGeneration] = useState(0);
  useEffect(() => {
    if (!service || !participant) return;
    return service.watch(participant, () => setGeneration((n) => n + 1));
  }, [service, participant]);
  useEffect(() => {
    setPicture(null);
    if (!service || !participant) return;
    let live = true;
    void service.picture(participant).then((url) => {
      if (live) setPicture(url);
    });
    return () => {
      live = false;
    };
  }, [service, participant, generation]);
  return picture;
}
