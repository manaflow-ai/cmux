// Hand-written stand-in for `convex codegen` output; `anyApi` provides the
// same runtime function references without schema-derived types.
import { anyApi } from "convex/server";

export const api: any = anyApi;
export const internal: any = anyApi;
