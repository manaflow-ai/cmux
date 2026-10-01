import type { Conversation, CreateConversationResponse, ServerFrame } from "@mux/protocol";
import type { Credential } from "../auth/stack.ts";
import type { ChatSource } from "./source.ts";

/** A ChatSource on the mux worker's REST and WebSocket API. */
export function httpSource(options: {
  baseUrl: string;
  credential: () => Promise<Credential>;
}): ChatSource {
  const json = async <T>(path: string, init: RequestInit = {}): Promise<T> => {
    const credential = await options.credential();
    const headers = new Headers(init.headers);
    if (credential.kind === "stack")
      headers.set("authorization", `Bearer ${credential.accessToken}`);
    else if (credential.kind === "dev") headers.set("x-mux-dev-user", credential.user);
    const response = await fetch(`${options.baseUrl}${path}`, { ...init, headers });
    if (!response.ok) throw new Error(`${init.method ?? "GET"} ${path}: ${response.status}`);
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
    listMachines: () => json("/api/machines"),
    async mintLinkToken() {
      return (await json<{ token: string }>("/api/link/token", { method: "POST" })).token;
    },
    watchConversations(onListChanged) {
      let socket: WebSocket | undefined;
      let stopped = false;
      void options.credential().then((credential) => {
        if (stopped) return;
        const url = new URL(`${options.baseUrl}/api/events`, window.location.href);
        url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
        if (credential.kind === "stack")
          url.searchParams.set("access_token", credential.accessToken);
        else if (credential.kind === "dev") url.searchParams.set("dev_user", credential.user);
        socket = new WebSocket(url);
        socket.onmessage = () => onListChanged();
      });
      return () => {
        stopped = true;
        socket?.close();
      };
    },
    connect(conversationId, onFrame, onClose) {
      let socket: WebSocket | undefined;
      let closed = false;
      const queue: string[] = [];
      // Browsers cannot set headers on WebSockets, so the credential goes in the query.
      void options.credential().then(
        (credential) => {
          if (closed) return;
          const url = new URL(
            `${options.baseUrl}/api/conversations/${conversationId}/ws`,
            window.location.href,
          );
          url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
          if (credential.kind === "stack")
            url.searchParams.set("access_token", credential.accessToken);
          else if (credential.kind === "dev") url.searchParams.set("dev_user", credential.user);
          socket = new WebSocket(url);
          socket.onopen = () => {
            for (const text of queue.splice(0)) socket?.send(text);
          };
          socket.onmessage = (event) => onFrame(JSON.parse(String(event.data)) as ServerFrame);
          socket.onclose = onClose;
        },
        () => onClose(),
      );
      return {
        send(frame) {
          const text = JSON.stringify(frame);
          if (socket?.readyState === WebSocket.OPEN) socket.send(text);
          else queue.push(text);
        },
        close() {
          closed = true;
          socket?.close();
        },
      };
    },
  };
}
