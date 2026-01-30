import { l as PluginDriver, s as validateOption, t as RolldownBuild } from "./rolldown-build-ciWo5RN-.mjs";

//#region src/api/rolldown/index.ts
/** @category Programmatic APIs */
const rolldown = async (input) => {
	validateOption("input", input);
	return new RolldownBuild(await PluginDriver.callOptionsHook(input));
};

//#endregion
export { rolldown as t };