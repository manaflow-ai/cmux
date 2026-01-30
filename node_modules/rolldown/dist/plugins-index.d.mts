import { u as BindingReplacePluginConfig } from "./shared/binding-MAEzB4KA.mjs";
import { A as BuiltinPlugin } from "./shared/define-config-Cg9apQLa.mjs";
import { t as esmExternalRequirePlugin } from "./shared/constructors-DcGyaGNV.mjs";

//#region src/builtin-plugin/replace-plugin.d.ts

/**
* Replaces targeted strings in files while bundling.
*
* @example
* // Basic usage
* ```js
* replacePlugin({
*   'process.env.NODE_ENV': JSON.stringify('production'),
*    __buildVersion: 15
* })
* ```
* @example
* // With options
* ```js
* replacePlugin({
*   'process.env.NODE_ENV': JSON.stringify('production'),
*   __buildVersion: 15
* }, {
*   preventAssignment: false,
* })
* ```
*/
declare function replacePlugin(values?: BindingReplacePluginConfig["values"], options?: Omit<BindingReplacePluginConfig, "values">): BuiltinPlugin;
//#endregion
export { esmExternalRequirePlugin, replacePlugin };