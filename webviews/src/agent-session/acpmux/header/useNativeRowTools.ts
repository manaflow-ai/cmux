import { useEffect, useRef, useState } from "react";
import type { HeaderQuickTool } from "./headerQuickTools";
import {
  dispatchNativeRowTool,
  nativeRowToolBindings,
  onNativeRowToolInvocation,
  type NativeRowPanel,
} from "./nativeRowTools";

export interface NativeRowToolsHost {
  enabled: boolean;
  callNative(method: string, params: Record<string, unknown>): Promise<unknown>;
  panel?: NativeRowPanel;
}

/// Publish only changed values. Callback identities can change with a render without sending tools
/// again; invocation always uses the current handlers. Hidden headers/unmount clear the native list.
export function useNativeRowTools(host: NativeRowToolsHost | undefined, quick: readonly HeaderQuickTool[]): boolean {
  const enabled = host?.enabled === true;
  const callNative = host?.callNative;
  const bindings = nativeRowToolBindings(quick, host?.panel);
  const current = useRef(bindings);
  current.current = bindings;
  const payload = JSON.stringify({ tools: bindings.map(({ tool }) => tool) });
  const sent = useRef<string | undefined>(undefined);
  const [failed, setFailed] = useState<string>();
  useEffect(() => {
    if (!enabled || !callNative) return;
    setFailed(undefined);
    return () => {
      sent.current = undefined;
      void callNative("pane.tabRowTools.set", { tools: [] }).catch(() => undefined);
    };
  }, [enabled, callNative]);
  useEffect(() => {
    if (!enabled || !callNative || sent.current === payload) return;
    sent.current = payload;
    let live = true;
    void callNative("pane.tabRowTools.set", JSON.parse(payload))
      .then(() => {
        if (live) setFailed(undefined);
      })
      .catch(() => {
        if (!live) return;
        // An unsupported or unavailable host must not strand the person without buttons.
        setFailed(payload);
        void callNative("pane.tabRowTools.set", { tools: [] }).catch(() => undefined);
      });
    return () => {
      live = false;
    };
  }, [enabled, callNative, payload]);
  const active = enabled && failed !== payload;
  useEffect(() => {
    if (!active) return;
    return onNativeRowToolInvocation((value) => dispatchNativeRowTool(value, current.current));
  }, [active]);
  return active;
}
