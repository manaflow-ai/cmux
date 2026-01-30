import { createWaitUntil, fmtURL, printListening, resolvePortAndHost, resolveTLSOptions } from "../_chunks/_utils-DRF_4b_y.mjs";
import { wrapFetch } from "../_chunks/_middleware-BvRR7B4M.mjs";
import { FastURL$1 as FastURL } from "../_chunks/_url-CdE4ce6F.mjs";

//#region src/adapters/deno.ts
const FastResponse = Response;
function serve(options) {
	return new DenoServer(options);
}
var DenoServer = class {
	runtime = "deno";
	options;
	deno = {};
	serveOptions;
	fetch;
	#listeningPromise;
	#listeningInfo;
	#wait;
	constructor(options) {
		this.options = {
			...options,
			middleware: [...options.middleware || []]
		};
		for (const plugin of options.plugins || []) plugin(this);
		const fetchHandler = wrapFetch(this);
		this.#wait = createWaitUntil();
		this.fetch = (request, info) => {
			Object.defineProperties(request, {
				waitUntil: { value: this.#wait.waitUntil },
				runtime: {
					enumerable: true,
					value: {
						name: "deno",
						deno: {
							info,
							server: this.deno?.server
						}
					}
				},
				ip: {
					enumerable: true,
					get() {
						return (info?.remoteAddr)?.hostname;
					}
				}
			});
			return fetchHandler(request);
		};
		const tls = resolveTLSOptions(this.options);
		this.serveOptions = {
			...resolvePortAndHost(this.options),
			reusePort: this.options.reusePort,
			onError: this.options.error,
			...tls ? {
				key: tls.key,
				cert: tls.cert,
				passphrase: tls.passphrase
			} : {},
			...this.options.deno
		};
		if (!options.manual) this.serve();
	}
	serve() {
		if (this.deno?.server) return Promise.resolve(this.#listeningPromise).then(() => this);
		const onListenPromise = Promise.withResolvers();
		this.#listeningPromise = onListenPromise.promise;
		this.deno.server = Deno.serve({
			...this.serveOptions,
			onListen: (info) => {
				this.#listeningInfo = info;
				if (this.options.deno?.onListen) this.options.deno.onListen(info);
				printListening(this.options, this.url);
				onListenPromise.resolve();
			}
		}, this.fetch);
		return Promise.resolve(this.#listeningPromise).then(() => this);
	}
	get url() {
		return this.#listeningInfo ? fmtURL(this.#listeningInfo.hostname, this.#listeningInfo.port, !!this.serveOptions.cert) : void 0;
	}
	ready() {
		return Promise.resolve(this.#listeningPromise).then(() => this);
	}
	async close() {
		await Promise.all([this.#wait.wait(), Promise.resolve(this.deno?.server?.shutdown())]);
	}
};

//#endregion
export { FastResponse, FastURL, serve };