import { createTanstackQueryUtils } from "@orpc/tanstack-query";

import { client } from "./client";

export const orpc = createTanstackQueryUtils(client);
