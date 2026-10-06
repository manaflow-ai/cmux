export interface CatalogRouteDeps {
  fetchFeed: () => Promise<Response>;
  now: () => Date;
}

export function createCatalogRoute(_deps: CatalogRouteDeps): {
  GET: (request: Request) => Promise<Response>;
  OPTIONS: () => Response;
} {
  const refuse = () => new Response("not implemented", { status: 501 });
  return { GET: async () => refuse(), OPTIONS: refuse };
}
