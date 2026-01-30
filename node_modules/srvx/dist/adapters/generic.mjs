import { createWaitUntil } from "../_chunks/_utils-DRF_4b_y.mjs";
import { wrapFetch } from "../_chunks/_middleware-BvRR7B4M.mjs";
import { errorPlugin } from "../_chunks/_plugins-DOhVIkXu.mjs";

//#region src/adapters/generic.ts
const FastURL = URL;
const FastResponse = Response;
function serve(options) {
	return new GenericServer(options);
}
var GenericServer = class {
	runtime = "generic";
	options;
	fetch;
	#wait;
	constructor(options) {
		this.options = {
			...options,
			middleware: [...options.middleware || []]
		};
		for (const plugin of options.plugins || []) plugin(this);
		errorPlugin(this);
		this.#wait = createWaitUntil();
		const fetchHandler = wrapFetch(this);
		this.fetch = (request) => {
			Object.defineProperties(request, { waitUntil: { value: this.#wait.waitUntil } });
			return Promise.resolve(fetchHandler(request));
		};
	}
	serve() {}
	ready() {
		return Promise.resolve(this);
	}
	async close() {
		await this.#wait.wait();
	}
};

//#endregion
export { FastResponse, FastURL, serve };