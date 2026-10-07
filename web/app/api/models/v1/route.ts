import { after } from "next/server";

import { catalogPreflight, serveModelCatalog } from "../../../../services/model-catalog/serve";
import { catalogStore } from "../../../../services/model-catalog/store";

// The curated model and harness catalog the cmux apps and acpmux fetch.
// See services/model-catalog/store.ts for where the data comes from.

export async function GET(request: Request): Promise<Response> {
  return serveModelCatalog(request, catalogStore(), (task) => after(task));
}

export async function HEAD(request: Request): Promise<Response> {
  return serveModelCatalog(request, catalogStore(), (task) => after(task));
}

export function OPTIONS(): Response {
  return catalogPreflight();
}
