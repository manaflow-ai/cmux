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
  /** Read pictures (null: the participant has none) and when each was read. */
  private readonly pictures = new Map<string, { picture: Promise<string | null>; at: number }>();
  private readonly listeners = new Map<string, Set<() => void>>();

  constructor(
    private readonly client: PageClient,
    /** A picture is read again after this long (a Cloud picture has no change event here). */
    private readonly maxAgeMs = 10 * 60_000,
  ) {}

  /** The participant's picture as a data URL, or null (none, or an older host). A failed read
   *  is not kept: the next render asks again. */
  picture(participant: string): Promise<string | null> {
    const kept = this.pictures.get(participant);
    if (kept && Date.now() - kept.at < this.maxAgeMs) {
      this.pictures.delete(participant);
      this.pictures.set(participant, kept);
      return kept.picture;
    }
    const picture = this.client
      .call<AvatarReply>(HomeOps.avatar, { participant })
      .then((reply) => (reply?.avatar ? `data:${reply.avatar.mediaType};base64,${reply.avatar.data}` : null));
    picture.catch(() => {
      if (this.pictures.get(participant)?.picture === picture) this.pictures.delete(participant);
    });
    this.pictures.delete(participant);
    this.pictures.set(participant, { picture, at: Date.now() });
    while (this.pictures.size > MAX_KEPT) this.pictures.delete(this.pictures.keys().next().value!);
    return picture.catch(() => null);
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
  // A new participant starts from its initials; a changed picture stays until the new one loads.
  useEffect(() => setPicture(null), [participant]);
  useEffect(() => {
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
