"use client";

// The only effects in the share viewer live here, behind two narrow hooks
// (per web/CLAUDE.md's no-scattered-useEffect rule): store subscription via
// useSyncExternalStore, and the ShareClient connect/disconnect lifecycle.

import { useEffect, useState, useSyncExternalStore } from "react";

import { ShareClient } from "./share-connection";

interface ReadableStore<T> {
  get(): T;
  subscribe(listener: () => void): () => void;
}

export function useStoreValue<T>(store: ReadableStore<T>): T {
  return useSyncExternalStore(store.subscribe, () => store.get(), () => store.get());
}

/** Owns one ShareClient for the page's lifetime: connect on mount, close on unmount. */
export function useShareClient(code: string): ShareClient {
  const [client] = useState(() => new ShareClient(code));
  useEffect(() => {
    client.start();
    return () => client.stop();
  }, [client]);
  return client;
}
