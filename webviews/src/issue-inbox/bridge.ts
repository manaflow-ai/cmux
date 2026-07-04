import { useSyncExternalStore } from "react";
import { makeClientId } from "../agent-session/shared/ids";
import { applyIssueInboxTheme } from "./theme";
import type {
  IssueInboxSnapshot,
  IssueInboxStoreState,
  IssueInboxTheme,
  IssueSpawnAgent,
} from "./types";

type NativeReply<T> =
  | { ok: true; value: T }
  | { ok: false; error?: { code?: string; userMessage?: string } };

declare global {
  interface Window {
    cmuxIssueInboxBridge?: {
      applyTheme(theme: IssueInboxTheme): void;
    };
  }
}

type IssueInboxWebKitWindow = Window & {
  webkit?: {
    messageHandlers?: {
      cmuxIssueInbox?: {
        postMessage(message: unknown): Promise<NativeReply<unknown>>;
      };
    };
  };
};

const listeners = new Set<() => void>();
let started = false;
let state: IssueInboxStoreState = {
  snapshot: null,
  loading: true,
  refreshing: false,
  error: null,
};

if (typeof window !== "undefined") {
  window.cmuxIssueInboxBridge = {
    applyTheme(theme: IssueInboxTheme) {
      applyIssueInboxTheme(theme);
    },
  };
}

export class IssueInboxBridgeError extends Error {
  readonly code?: string;

  constructor(message: string, code?: string) {
    super(message);
    this.name = "IssueInboxBridgeError";
    this.code = code;
  }
}

export function startIssueInboxStore(): void {
  if (started) {
    return;
  }
  started = true;
  void loadInitialSnapshot();
}

export function useIssueInboxStore(): IssueInboxStoreState {
  return useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
}

export async function refreshIssues(): Promise<void> {
  updateState({ refreshing: true, error: null });
  try {
    await callNative<unknown>("refresh");
  } catch (error) {
    updateState({
      refreshing: false,
      error: error instanceof Error ? error.message : "Issue Inbox request failed.",
    });
  }
}

export async function spawnWorkspace(issueId: string, agent: IssueSpawnAgent): Promise<void> {
  await callNative<unknown>("spawn", { issueId, agent });
}

export async function openExternal(url: string): Promise<void> {
  await callNative<unknown>("openExternal", { url });
}

export async function openConfig(): Promise<void> {
  await callNative<unknown>("openConfig");
}

async function loadInitialSnapshot(): Promise<void> {
  await pullSnapshot();
  void refreshIssues();
}

async function pullSnapshot(): Promise<void> {
  try {
    const snapshot = await callNative<IssueInboxSnapshot>("snapshot");
    applyIssueInboxTheme(snapshot.theme);
    updateState({
      snapshot,
      loading: false,
      refreshing: snapshot.refreshing.length > 0,
      error: null,
    });
  } catch (error) {
    updateState({
      loading: false,
      refreshing: false,
      error: error instanceof Error ? error.message : "Issue Inbox request failed.",
    });
  }
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  const refreshCompleted = () => {
    void pullSnapshot();
  };
  window.addEventListener("cmuxIssueInboxRefreshCompleted", refreshCompleted);
  return () => {
    listeners.delete(listener);
    window.removeEventListener("cmuxIssueInboxRefreshCompleted", refreshCompleted);
  };
}

function getSnapshot(): IssueInboxStoreState {
  return state;
}

function updateState(next: Partial<IssueInboxStoreState>): void {
  state = { ...state, ...next };
  for (const listener of listeners) {
    listener();
  }
}

async function callNative<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  const handler = (window as IssueInboxWebKitWindow).webkit?.messageHandlers?.cmuxIssueInbox;
  if (!handler || typeof handler.postMessage !== "function") {
    throw new IssueInboxBridgeError("Native bridge is unavailable.", "unavailable");
  }
  const reply = (await handler.postMessage({
    id: makeClientId(),
    method,
    params,
  })) as NativeReply<T>;

  if (!reply.ok) {
    throw new IssueInboxBridgeError(
      reply.error?.userMessage || "Issue Inbox request failed.",
      reply.error?.code,
    );
  }
  return reply.value;
}
