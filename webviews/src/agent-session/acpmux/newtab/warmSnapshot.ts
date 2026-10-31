// The recent chats a New Tab page draws on its first frame (Leo 2026-10-19: "there's still a split
// second flicker upon opening up new workspaces wrt the semi dynamic content on the recent chats
// and the recent project... it sometimes doesnt load fast enough"). A page that just mounted has no
// chat list until its own daemon connection answers, so its Chats list painted empty and then
// filled. Every local page posts its newest listed chats and device chats (`newTab.warm`); the host
// keeps the last (AgentPaneNewTab.warmed) and every opening's context carries it (`warm`): Cmd-T,
// the + button, a new workspace, a split and an adopted spare all start from that one snapshot.
// The page lists them until its own list arrives, which changes rows in place.
import { useSyncExternalStore } from "react";
import type { AcpmuxSnapshot } from "../model";
import { activityTime } from "../sessionList";
import { deviceChats, setDeviceChats, subscribeDeviceChats, type DeviceChat } from "./deviceChats";

/// Enough of the newest chats for every template's cards and their folded children.
const KEPT = 100;
/// Coalesces a streaming turn's snapshots (one per row) into one post.
const POST_DELAY_MS = 400;

type Sessions = AcpmuxSnapshot["sessions"];

let warm: Sessions = [];
/// The page's own connection has listed the chats once: a carried list never shows again, not
/// after a reconnect (whose first snapshot lists nothing yet) or a later adoption.
let listedOnce = false;
const listeners = new Set<() => void>();

/// Takes the context's `warm` (JSON text `{sessions, device}`) as the page's starting chats, and the
/// device chats when the host has pushed none yet. Anything malformed leaves what the page had.
export function seedWarmNewTab(value: unknown): void {
  if (typeof value !== "string" || !value) return;
  let parsed: { sessions?: unknown; device?: unknown };
  try {
    parsed = JSON.parse(value) as typeof parsed;
  } catch {
    return;
  }
  if (!parsed || typeof parsed !== "object") return;
  const sessions = Array.isArray(parsed.sessions)
    ? (parsed.sessions as unknown[]).filter(
        (entry): entry is Sessions[number] =>
          !!entry && typeof entry === "object" && typeof (entry as { sessionId?: unknown }).sessionId === "string",
      )
    : [];
  if (deviceChats().length === 0 && Array.isArray(parsed.device)) setDeviceChats(parsed.device);
  if (sessions.length === 0 || listedOnce) return;
  warm = sessions;
  for (const listener of listeners) listener();
}

/// The chats the context carried, newest first; empty when it carried none.
export function warmNewTabSessions(): Sessions {
  return warm;
}

export function useWarmNewTabSessions(): Sessions {
  return useSyncExternalStore(subscribe, warmNewTabSessions, warmNewTabSessions);
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/// The chats a page lists while its own list has not arrived: the context's, until then.
/// A page whose daemon is down shows that, not chats it cannot open (or that were deleted since).
export function shownNewTabSessions(
  snapshot: Pick<AcpmuxSnapshot, "listedSessions" | "sessions" | "connection">,
  carried: Sessions,
): Sessions | undefined {
  if (snapshot.connection === "disconnected" || snapshot.connection === "debug") return undefined;
  return !snapshot.listedSessions && snapshot.sessions.length === 0 && carried.length > 0 ? carried : undefined;
}

let listed: Sessions | undefined;
let posted: string | undefined;
let timer: ReturnType<typeof setTimeout> | undefined;
let post: ((warm: { sessions: Sessions; device: DeviceChat[] }) => void) | undefined;
let unsubscribe: (() => void) | undefined;

/// Each snapshot the page's connection makes. Once it has listed the chats, the carried ones are
/// done. A New Tab page (`posts`: one is always alive, the prewarmed spare) then posts the newest
/// chats of a list this Mac's daemon sent, for the next New Tab page, and again after each device
/// chats push; coalesced, and only when what would be posted changed. Chat pages post nothing, so
/// a streaming turn does not make every open page serialize the list.
export function publishWarmNewTab(
  snapshot: Pick<AcpmuxSnapshot, "origin" | "listedSessions" | "sessions">,
  send: (warm: { sessions: Sessions; device: DeviceChat[] }) => void,
  posts = true,
): void {
  if (!snapshot.listedSessions) return;
  if (!listedOnce) {
    listedOnce = true;
    if (warm.length > 0) {
      warm = [];
      for (const listener of listeners) listener();
    }
  }
  if (snapshot.origin !== "local" || !posts) return;
  post = send;
  unsubscribe ??= subscribeDeviceChats(schedule);
  if (snapshot.sessions === listed) return;
  listed = snapshot.sessions;
  schedule();
}

function schedule(): void {
  if (timer !== undefined || !listed) return;
  timer = setTimeout(() => {
    timer = undefined;
    if (!listed || !post) return;
    // The same chats the live list has (a peer's and Cloud's too), so its arrival changes no row.
    const sessions = [...listed].sort((a, b) => (activityTime(b) ?? 0) - (activityTime(a) ?? 0)).slice(0, KEPT);
    const next = { sessions, device: deviceChats() };
    const text = JSON.stringify(next);
    if (text === posted) return;
    posted = text;
    post(next);
  }, POST_DELAY_MS);
}

/// A new page's start (tests).
export function resetWarmNewTabForTests(): void {
  warm = [];
  listedOnce = false;
  listed = undefined;
  posted = undefined;
  post = undefined;
  if (timer !== undefined) clearTimeout(timer);
  timer = undefined;
  unsubscribe?.();
  unsubscribe = undefined;
}
