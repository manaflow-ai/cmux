import "./shared/binding-MAEzB4KA.mjs";
import { wt as MaybePromise, x as Plugin } from "./shared/define-config-Cg9apQLa.mjs";

//#region src/plugin/parallel-plugin-implementation.d.ts
type ParallelPluginImplementation = Plugin;
type Context = {
  /**
  * Thread number
  */
  threadNumber: number;
};
declare function defineParallelPluginImplementation<Options>(plugin: (Options: Options, context: Context) => MaybePromise<ParallelPluginImplementation>): (Options: Options, context: Context) => MaybePromise<ParallelPluginImplementation>;
//#endregion
export { type Context, type ParallelPluginImplementation, defineParallelPluginImplementation };