import { BuildV2, PrepareCache } from "@vercel/build-utils";

//#region src/index.d.ts
declare const version = 2;
declare const build: BuildV2;
declare const prepareCache: PrepareCache;
//#endregion
export { build, prepareCache, version };