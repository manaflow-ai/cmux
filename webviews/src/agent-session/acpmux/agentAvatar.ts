// Agent session avatars (Leo 2026-10-26: "upload their own if they have things from elsewhere for
// the avatars"): the person's own picture for a session, which its cards and sender chip draw in
// place of the harness mark. The host keeps it on this Mac and answers a small data URL
// (`agent.avatar {sessionId}`, AgentAvatars.swift); the chat's ⋯ menu sets and removes it
// (`agent.avatar.set`, `agent.avatar.remove`), and the host tells every pane's page of a change
// (`cmuxAcpmuxBridge.agentAvatarChanged`). An answer is kept for the page, a change is told to
// every card at once, and a failed ask (an older host, the page not yet connected) is not kept.
import { useEffect, useSyncExternalStore } from "react";
import { postNative } from "./native";

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;
let call: Call = postNative;

/// Each session's avatar: a data URL, or null for none.
const avatars = new Map<string, string | null>();
const pending = new Map<string, Promise<string | null>>();
/// Each session's change count: a read that started before a Set or Remove keeps nothing.
const changes = new Map<string, number>();
const listeners = new Set<() => void>();
/// How many cards draw each session now: a change re-asks for a drawn session even after a failed read.
const drawn = new Map<string, number>();

/// Tests replace the host; replacing it forgets every answer.
export function setAgentAvatarHost(next: Call | undefined): void {
  call = next ?? postNative;
  avatars.clear();
  pending.clear();
  changes.clear();
  drawn.clear();
}

/// Tells every card and chip that an answer changed.
function notify(): void {
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/// A card draws session `sessionId` until the returned function is called (exported for tests).
export function drawAgentAvatar(sessionId: string): () => void {
  drawn.set(sessionId, (drawn.get(sessionId) ?? 0) + 1);
  return () => {
    const left = (drawn.get(sessionId) ?? 1) - 1;
    if (left > 0) drawn.set(sessionId, left);
    else drawn.delete(sessionId);
  };
}

function src(reply: unknown): string | null {
  const value = (reply as { src?: unknown } | undefined)?.src;
  return typeof value === "string" && value.startsWith("data:image/") ? value : null;
}

/// Asks the host for the session's avatar once at a time (exported for tests).
export function loadAgentAvatar(sessionId: string): Promise<string | null> {
  const started = pending.get(sessionId);
  if (started) return started;
  const asked = changes.get(sessionId) ?? 0;
  const request: Promise<string | null> = Promise.resolve()
    .then(() => call("agent.avatar", { sessionId }))
    .then(
      (reply) => {
        if ((changes.get(sessionId) ?? 0) !== asked) return avatars.get(sessionId) ?? null;
        const value = src(reply);
        avatars.set(sessionId, value);
        notify();
        return value;
      },
      () => {
        // A failed read keeps nothing: a picture shown before a change in another pane goes, and
        // the next card that draws the session asks again.
        if ((changes.get(sessionId) ?? 0) === asked && avatars.delete(sessionId)) notify();
        return null;
      },
    )
    .finally(() => {
      if (pending.get(sessionId) === request) pending.delete(sessionId);
    });
  pending.set(sessionId, request);
  return request;
}

/// Forgets what the page knew of session `sessionId` (a read that started before keeps nothing) and,
/// when `always` or a card draws the session or waits on it, asks the host for it afresh. The old
/// picture stays until the answer comes, so nothing flashes.
function refresh(sessionId: string, always: boolean): Promise<unknown> {
  const asked = always || drawn.has(sessionId) || avatars.has(sessionId) || pending.has(sessionId);
  changes.set(sessionId, (changes.get(sessionId) ?? 0) + 1);
  pending.delete(sessionId);
  if (!asked) return Promise.resolve();
  return loadAgentAvatar(sessionId);
}

/// The host says session `sessionId`'s avatar was set or removed (in this pane or another).
export function agentAvatarChanged(sessionId: string): void {
  void refresh(sessionId, false);
}

/// Set Avatar…: the host's open panel, then every card of the session draws what the host keeps
/// now. The reply itself is never kept: a slow one could undo a change made after it.
export async function setAgentAvatar(sessionId: string): Promise<void> {
  if (src(await call("agent.avatar.set", { sessionId }))) await refresh(sessionId, true);
}

/// Remove Avatar: the session's harness mark again, once the host says it keeps none.
export async function removeAgentAvatar(sessionId: string): Promise<void> {
  await call("agent.avatar.remove", { sessionId });
  await refresh(sessionId, true);
}

/// Whether the session has an avatar the page knows of (the menu offers Remove Avatar then).
export function hasAgentAvatar(sessionId: string | undefined): boolean {
  return sessionId !== undefined && typeof avatars.get(sessionId) === "string";
}

/// Session `sessionId`'s avatar as a data URL once the host answers; undefined for none, and for
/// no session. It reads the page's answers as an external store, so every answer and change
/// redraws the card (a memoized read of the map would keep the first, empty, answer).
export function useAgentAvatar(sessionId: string | undefined): string | undefined {
  const avatar = useSyncExternalStore(subscribe, () => (sessionId ? avatars.get(sessionId) : undefined));
  useEffect(() => (sessionId ? drawAgentAvatar(sessionId) : undefined), [sessionId]);
  useEffect(() => {
    if (sessionId && !avatars.has(sessionId)) void loadAgentAvatar(sessionId);
  }, [sessionId]);
  return avatar ?? undefined;
}
