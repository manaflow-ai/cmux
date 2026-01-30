//#region src/loaders/hooks.ts
let honoUrl = null;
let expressUrl = null;
async function resolve(specifier, context, nextResolve) {
	const result = await nextResolve(specifier, context);
	if (specifier === "hono") honoUrl = result.url;
	else if (specifier === "express") expressUrl = result.url;
	return result;
}
async function load(url, context, nextLoad) {
	const result = await nextLoad(url, context);
	if (expressUrl === url) {
		const pathToExpressExtract = new URL("../express.mjs", import.meta.url);
		return {
			format: "module",
			source: `
import { handle} from ${JSON.stringify(pathToExpressExtract.toString())};
import originalExpress from ${JSON.stringify(url + "?original")};

const extendedExpress = handle(originalExpress);

export * from ${JSON.stringify(url + "?original")};
export default extendedExpress;
`,
			shortCircuit: true
		};
	}
	if (honoUrl === url) {
		const pathToHonoExtract = new URL("../hono.mjs", import.meta.url);
		return {
			format: "module",
			source: `
import { handle } from ${JSON.stringify(pathToHonoExtract.toString())};
import * as originalHono from ${JSON.stringify(url + "?original")};

export * from ${JSON.stringify(url + "?original")};
export const Hono = handle(originalHono);
`,
			shortCircuit: true
		};
	}
	if (url.endsWith("?original")) {
		const originalUrl = url.replace("?original", "");
		if (originalUrl === honoUrl || originalUrl === expressUrl) return result;
	}
	return result;
}

//#endregion
export { load, resolve };