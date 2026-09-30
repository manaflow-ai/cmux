import { QueryClient } from "@tanstack/react-query";
import { createRouter } from "@tanstack/react-router";
import { fixtureSource } from "./chat/fixture.ts";
import type { ChatSource } from "./chat/source.ts";
import { routeTree } from "./routeTree.gen.ts";

export interface RouterContext {
  queryClient: QueryClient;
  source: ChatSource;
}

export function makeRouter() {
  const queryClient = new QueryClient();
  return createRouter({
    routeTree,
    context: { queryClient, source: fixtureSource },
    defaultPreload: "intent",
    scrollRestoration: true,
  });
}

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof makeRouter>;
  }
}
