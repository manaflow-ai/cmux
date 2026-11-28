import { catalogPreflight, serveModelCatalog } from "../../../../services/model-catalog/serve";
import { catalogStore } from "../../../../services/model-catalog/store";

// The curated model and harness catalog acpmux fetches for every cmux client:
// the newest published catalog_versions row (services/model-catalog/store.ts).

export async function GET(request: Request): Promise<Response> {
  return serveModelCatalog(request, catalogStore());
}

export async function HEAD(request: Request): Promise<Response> {
  return serveModelCatalog(request, catalogStore());
}

export function OPTIONS(): Response {
  return catalogPreflight();
}
