/**
 * TUI entry point — starts the Ink render loop and returns an AppHandle for
 * the runner to push events, plus a promise that resolves when the user quits.
 */
import React from "react";
import { render } from "ink";
import { App } from "./app.js";
import type { AppHandle, InitialAppProps } from "./app.js";

export type { AppHandle, InitialAppProps };
export type { StreamingState } from "./messages.js";

export interface TuiInstance {
  handle: AppHandle;
  waitUntilExit: () => Promise<void>;
}

export function runTui(opts: InitialAppProps): TuiInstance {
  let resolveHandle!: (h: AppHandle) => void;
  const handlePromise = new Promise<AppHandle>((res) => {
    resolveHandle = res;
  });

  // We need a synchronous handle to return immediately.
  // We build a proxy that buffers events until onReady fires.
  const bufferedEvents: Array<() => void> = [];
  let liveHandle: AppHandle | null = null;

  const proxyHandle: AppHandle = {
    pushStreamEvent(event) {
      if (liveHandle) {
        liveHandle.pushStreamEvent(event);
      } else {
        bufferedEvents.push(() => liveHandle!.pushStreamEvent(event));
      }
    },
    pushToolUpdate(update) {
      if (liveHandle) {
        liveHandle.pushToolUpdate(update);
      } else {
        bufferedEvents.push(() => liveHandle!.pushToolUpdate(update));
      }
    },
    onMessageAppended(message) {
      if (liveHandle) {
        liveHandle.onMessageAppended(message);
      } else {
        bufferedEvents.push(() => liveHandle!.onMessageAppended(message));
      }
    },
  };

  function onReady(h: AppHandle) {
    liveHandle = h;
    resolveHandle(h);
    for (const fn of bufferedEvents) fn();
    bufferedEvents.length = 0;
  }

  const { waitUntilExit } = render(
    React.createElement(App, { ...opts, onReady })
  );

  return {
    handle: proxyHandle,
    waitUntilExit,
  };
}
