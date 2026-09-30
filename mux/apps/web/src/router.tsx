import { QueryClient } from "@tanstack/react-query";
import { createRouter } from "@tanstack/react-router";
import { makeSession, type ChatSession } from "./chat/session.ts";
import { routeTree } from "./routeTree.gen.ts";

export interface RouterContext {
  queryClient: QueryClient;
  session: ChatSession;
}

export function makeRouter() {
  const queryClient = new QueryClient();
  return createRouter({
    routeTree,
    context: {
      queryClient,
      session: makeSession(
        () => void queryClient.invalidateQueries({ queryKey: ["conversations"] }),
      ),
    },
    defaultPreload: "intent",
  });
}

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof makeRouter>;
  }
}
