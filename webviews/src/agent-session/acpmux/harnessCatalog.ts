// A `_acpmux/harnesses` reply as the picker's catalog. Its bodies live in direct/catalog.ts and
// direct/refusals.ts, so the model catalog reads it without the connection client.
export { harnessRefusal } from "./direct/refusals";
export { catalogModel, normalizeCatalog } from "./direct/catalog";
