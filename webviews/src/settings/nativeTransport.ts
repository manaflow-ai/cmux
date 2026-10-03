// The transport inside the app: requests go through the `cmuxSettings` script message handler
// (WKScriptMessageHandlerWithReply, so postMessage returns a Promise); events and theme
// changes arrive through `window.cmuxSettingsBridge`, which this module installs.
import { applySettingsTheme } from "./theme";
import type { ErrorReply, OpName, Ops, SettingsEvent, SettingsTransport } from "./wire";

type Handler = { postMessage(message: { op: string; params: unknown }): Promise<unknown> };

export type SettingsBridge = {
  dispatch(event: SettingsEvent): void;
  applyTheme(values: Record<string, unknown>): void;
};

declare global {
  interface Window {
    cmuxSettingsBridge?: SettingsBridge;
  }
}

export function nativeHandler(): Handler | null {
  const handlers = (window as unknown as { webkit?: { messageHandlers?: Record<string, Handler | undefined> } }).webkit
    ?.messageHandlers;
  return handlers?.cmuxSettings ?? null;
}

export class NativeTransport implements SettingsTransport {
  private readonly listeners = new Set<(event: SettingsEvent) => void>();

  constructor(private readonly handler: Handler) {
    window.cmuxSettingsBridge = {
      dispatch: (event) => {
        for (const listener of this.listeners) listener(event);
      },
      applyTheme: (values) => applySettingsTheme(values),
    };
  }

  subscribe(listener: (event: SettingsEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  async request<K extends OpName>(op: K, params: Ops[K][0]): Promise<Ops[K][1] | ErrorReply> {
    try {
      return (await this.handler.postMessage({ op, params })) as Ops[K][1] | ErrorReply;
    } catch (error) {
      // A rejected reply means the relay itself failed: treat it as the daemon being away.
      return { error: { code: "unavailable", message: String(error) } };
    }
  }
}
