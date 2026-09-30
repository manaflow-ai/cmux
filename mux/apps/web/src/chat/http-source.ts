import type { Conversation, CreateConversationResponse, ServerFrame } from "@mux/protocol";
import type { ChatSource } from "./source.ts";

/** A ChatSource on the mux worker's REST and WebSocket API. */
export function httpSource(options: { baseUrl: string; authQuery: () => string }): ChatSource {
  const url = (path: string) => {
    const query = options.authQuery();
    return `${options.baseUrl}${path}${query ? `?${query}` : ""}`;
  };
  const json = async <T>(path: string, init?: RequestInit): Promise<T> => {
    const response = await fetch(url(path), init);
    if (!response.ok) throw new Error(`${init?.method ?? "GET"} ${path}: ${response.status}`);
    return (await response.json()) as T;
  };
  return {
    viewer: () => json("/api/me"),
    listConversations: () => json("/api/conversations"),
    async createConversation(request) {
      const body = await json<CreateConversationResponse>("/api/conversations", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(request),
      });
      return body.conversation as Conversation;
    },
    connect(conversationId, onFrame, onClose) {
      const wsUrl = new URL(url(`/api/conversations/${conversationId}/ws`), window.location.href);
      wsUrl.protocol = wsUrl.protocol === "https:" ? "wss:" : "ws:";
      const socket = new WebSocket(wsUrl);
      const queue: string[] = [];
      socket.onopen = () => {
        for (const text of queue.splice(0)) socket.send(text);
      };
      socket.onmessage = (event) => onFrame(JSON.parse(String(event.data)) as ServerFrame);
      socket.onclose = onClose;
      return {
        send(frame) {
          const text = JSON.stringify(frame);
          if (socket.readyState === WebSocket.OPEN) socket.send(text);
          else queue.push(text);
        },
        close: () => socket.close(),
      };
    },
  };
}
