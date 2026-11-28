import { createORPCClient } from "@orpc/client";
import { RPCLink } from "@orpc/client/fetch";
import type { RouterClient } from "@orpc/server";

import type { AppRouter } from "./server/router";

const link = new RPCLink({
  url: () => new URL("/api/rpc", window.location.origin),
});

export const client: RouterClient<AppRouter> = createORPCClient<RouterClient<AppRouter>>(link);
