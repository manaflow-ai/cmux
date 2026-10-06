import type { ModelCatalog } from "./types";

/** Projects the public model feed through the cmux overrides into a `ModelCatalog`. */
export function projectCatalog(_feed: unknown, _now: Date): ModelCatalog {
  throw new Error("projectCatalog is not implemented");
}
