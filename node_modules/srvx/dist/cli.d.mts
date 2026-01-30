import { Server } from "srvx";

//#region src/cli.d.ts
declare function main(mainOpts: MainOpts): Promise<void>;
declare global {
  var __srvx_version__: string | undefined;
  var __srvx__: Server;
  var __srvx_listen_cb__: () => void;
}
type MainOpts = {
  command: string;
  docs: string;
  issues: string;
};
declare function usage(mainOpts: MainOpts): string;
//#endregion
export { main, usage };