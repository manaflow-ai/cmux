import { wrapFetch } from "../_chunks/_middleware-BvRR7B4M.mjs";
import { errorPlugin } from "../_chunks/_plugins-DOhVIkXu.mjs";

//#region src/adapters/service-worker.ts
const FastURL = URL;
const FastResponse = Response;
const isBrowserWindow = typeof window !== "undefined" && typeof navigator !== "undefined";
const isServiceWorker = /* @__PURE__ */ (() => typeof self !== "undefined" && "skipWaiting" in self)();
function serve(options) {
	return new ServiceWorkerServer(options);
}
var ServiceWorkerServer = class {
	runtime = "service-worker";
	options;
	fetch;
	#fetchListener;
	#listeningPromise;
	constructor(options) {
		this.options = {
			...options,
			middleware: [...options.middleware || []]
		};
		for (const plugin of options.plugins || []) plugin(this);
		errorPlugin(this);
		const fetchHandler = wrapFetch(this);
		this.fetch = (request, event) => {
			Object.defineProperties(request, { runtime: {
				enumerable: true,
				value: {
					name: "service-worker",
					serviceWorker: { event }
				}
			} });
			return Promise.resolve(fetchHandler(request));
		};
		if (!options.manual) this.serve();
	}
	serve() {
		if (isBrowserWindow) {
			if (!navigator.serviceWorker) throw new Error("Service worker is not supported in the current window.");
			const swURL = this.options.serviceWorker?.url;
			if (!swURL) throw new Error("Service worker URL is not provided. Please set the `serviceWorker.url` serve option or manually register.");
			this.#listeningPromise = navigator.serviceWorker.register(swURL, {
				type: "module",
				scope: this.options.serviceWorker?.scope
			}).then((registration) => {
				if (registration.active) location.replace(location.href);
				else registration.addEventListener("updatefound", () => {
					location.replace(location.href);
				});
			});
		} else if (isServiceWorker) {
			this.#fetchListener = async (event) => {
				if (/\/[^/]*\.[a-zA-Z0-9]+$/.test(new URL(event.request.url).pathname)) return;
				Object.defineProperty(event.request, "waitUntil", { value: event.waitUntil.bind(event) });
				const response = await this.fetch(event.request, event);
				if (response.status !== 404) event.respondWith(response);
			};
			addEventListener("fetch", this.#fetchListener);
			self.addEventListener("install", () => {
				self.skipWaiting();
			});
			self.addEventListener("activate", () => {
				self.clients?.claim?.();
			});
		}
	}
	ready() {
		return Promise.resolve(this.#listeningPromise).then(() => this);
	}
	async close() {
		if (this.#fetchListener) removeEventListener("fetch", this.#fetchListener);
		if (isBrowserWindow) {
			const registrations = await navigator.serviceWorker.getRegistrations();
			for (const registration of registrations) if (registration.active) await registration.unregister();
		} else if (isServiceWorker) await self.registration.unregister();
	}
};

//#endregion
export { FastResponse, FastURL, serve };