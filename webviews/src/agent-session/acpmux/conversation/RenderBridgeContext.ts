import { createContext, useLayoutEffect, useMemo, useRef, type ContextType } from "react";

/// Pane actions available to a render, confirmed in the pane first.
export const RenderBridgeContext = createContext<
  | {
      prefill(text: string): void;
      send(text: string): boolean | void | Promise<unknown>;
      openLink(url: string): boolean | Promise<boolean>;
    }
  | undefined
>(undefined);

/// Streaming updates keep the same bridge while its actions read the pane's latest callbacks (Lucas 2026-10-18).
export function useRenderBridge(bridge: NonNullable<ContextType<typeof RenderBridgeContext>>) {
  const latest = useRef(bridge);
  useLayoutEffect(() => {
    latest.current = bridge;
  });
  return useMemo(
    () => ({
      prefill: (text: string) => latest.current.prefill(text),
      send: (text: string) => latest.current.send(text),
      openLink: (url: string) => latest.current.openLink(url),
    }),
    [],
  );
}
