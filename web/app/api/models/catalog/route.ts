import { connection } from "next/server";

import { createCatalogRoute, defaultFetchFeed } from "../../../../services/model-catalog/route";

// The composer's model catalog (CONTRACT: .cmux-scratch/nx-model-catalog/CONTRACT.md). Public,
// unauthenticated and cached by the CDN; see services/model-catalog/route.ts.
const route = createCatalogRoute({ fetchFeed: defaultFetchFeed, now: () => new Date() });

export async function GET(request: Request): Promise<Response> {
  await connection();
  return route.GET(request);
}

export function OPTIONS(): Response {
  return route.OPTIONS();
}
