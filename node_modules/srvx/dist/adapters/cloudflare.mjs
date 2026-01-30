import { wrapFetch } from "../_chunks/_middleware-BvRR7B4M.mjs";
import { errorPlugin } from "../_chunks/_plugins-DOhVIkXu.mjs";

//#region src/adapters/cloudflare.ts
const FastURL = URL;
const FastResponse = Response;
function serve(options) {
	return new CloudflareServer(options);
}
var CloudflareServer = class {
	runtime = "cloudflare";
	options;
	serveOptions;
	fetch;
	constructor(options) {
		this.options = {
			...options,
			middleware: [...options.middleware || []]
		};
		for (const plugin of options.plugins || []) plugin(this);
		errorPlugin(this);
		const fetchHandler = wrapFetch(this);
		this.fetch = (request, env, context) => {
			Object.defineProperties(request, {
				waitUntil: { value: context.waitUntil.bind(context) },
				runtime: {
					enumerable: true,
					value: {
						name: "cloudflare",
						cloudflare: {
							env,
							context
						}
					}
				},
				ip: {
					enumerable: true,
					get() {
						return request.headers.get("cf-connecting-ip");
					}
				}
			});
			return fetchHandler(request);
		};
		this.serveOptions = { fetch: this.fetch };
		if (!options.manual) this.serve();
	}
	serve() {
		addEventListener("fetch", (event) => {
			event.respondWith(this.fetch(event.request, {}, event));
		});
	}
	ready() {
		return Promise.resolve().then(() => this);
	}
	close() {
		return Promise.resolve();
	}
};

//#endregion
export { FastResponse, FastURL, serve };