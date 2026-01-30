import "./shared/binding-MAEzB4KA.mjs";
import { n as ConfigExport, t as defineConfig } from "./shared/define-config-Cg9apQLa.mjs";

//#region src/utils/load-config.d.ts
declare function loadConfig(configPath: string): Promise<ConfigExport>;
//#endregion
//#region src/config.d.ts
declare const VERSION: string;
//#endregion
export { VERSION, defineConfig, loadConfig };