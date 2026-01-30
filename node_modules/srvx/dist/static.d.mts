import { ServerMiddleware } from "./_chunks/types-BtByT9ny.mjs";

//#region src/static.d.ts
interface ServeStaticOptions {
  dir: string;
}
declare const serveStatic: (options: ServeStaticOptions) => ServerMiddleware;
//#endregion
export { ServeStaticOptions, serveStatic };