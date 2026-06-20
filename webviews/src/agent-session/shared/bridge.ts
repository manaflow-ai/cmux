import type { AgentEvent, AgentSessionTheme } from "./types";
import { applyAgentTheme } from "./theme";
import { createNativeBridge } from "../../shared/nativeBridge";

declare global {
  interface Window {
    cmuxAgentBridge?: {
      applyTheme(theme: AgentSessionTheme): void;
      receive(event: AgentEvent): void;
    };
  }
}

export class NativeBridgeError extends Error {
  readonly code?: string;

  constructor(message: string, code?: string) {
    super(message);
    this.name = "NativeBridgeError";
    this.code = code;
  }
}

const bridge = createNativeBridge<AgentEvent>({
  handlerName: "agentSession",
  makeError: (message, code) => new NativeBridgeError(message, code),
  requestFailedMessage: "Native bridge request failed.",
  onReceive: (event) => {
    if (event.type === "app.theme") {
      applyAgentTheme(event.theme);
    }
  },
});

if (typeof window !== "undefined") {
  window.cmuxAgentBridge = {
    applyTheme(theme: AgentSessionTheme) {
      applyAgentTheme(theme);
    },
    receive: bridge.receive,
  };
}

export function subscribeToAgentEvents(listener: (event: AgentEvent) => void): () => void {
  return bridge.subscribe(listener);
}

export function callNative<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  return bridge.callNative<T>(method, params);
}
