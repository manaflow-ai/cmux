import type { FeedNativeEvent, FeedSnapshot } from "./types";

type NativeReply<T> =
  | { ok: true; value: T }
  | { ok: false; error?: { code?: string; userMessage?: string } };

declare global {
  interface Window {
    cmuxFeedBridge?: { receive(event: FeedNativeEvent): void };
  }
}

type FeedBridgeWindow = Window & {
  webkit?: {
    messageHandlers?: {
      cmuxFeed?: { postMessage(message: unknown): Promise<NativeReply<unknown>> };
    };
  };
};

let currentSnapshot: FeedSnapshot | null = null;
const listeners = new Set<() => void>();
let subscriptionPromise: Promise<void> | null = null;

function publish(snapshot: FeedSnapshot) {
  currentSnapshot = snapshot;
  for (const listener of listeners) listener();
}

export function receiveFeedNativeEvent(event: FeedNativeEvent) {
  if (event.type === "feed.snapshot") publish(event.snapshot);
}

if (typeof window !== "undefined") {
  window.cmuxFeedBridge = { receive: receiveFeedNativeEvent };
}

export async function callFeedNative<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  const handler = (window as FeedBridgeWindow).webkit?.messageHandlers?.cmuxFeed;
  if (!handler?.postMessage) throw new Error("Native Feed bridge is unavailable.");
  const reply = (await handler.postMessage({ method, params })) as NativeReply<T>;
  if (!reply.ok) throw new Error(reply.error?.userMessage || "Feed request failed.");
  return reply.value;
}

async function ensureSubscribed() {
  if (subscriptionPromise) return subscriptionPromise;
  subscriptionPromise = callFeedNative<FeedSnapshot>("feed.subscribe")
    .then(publish)
    .catch((error) => {
      subscriptionPromise = null;
      throw error;
    });
  return subscriptionPromise;
}

export const feedSnapshotStore = {
  getSnapshot: () => currentSnapshot,
  subscribe(listener: () => void) {
    listeners.add(listener);
    void ensureSubscribed();
    return () => listeners.delete(listener);
  },
};
