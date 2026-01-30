import { createWaitUntil, fmtURL, printListening, resolvePortAndHost, resolveTLSOptions } from "../_chunks/_utils-DRF_4b_y.mjs";
import { wrapFetch } from "../_chunks/_middleware-BvRR7B4M.mjs";
import { FastURL$1 as FastURL } from "../_chunks/_url-CdE4ce6F.mjs";
import { NodeRequestHeaders, NodeResponse, NodeResponseHeaders, inheritProps, kNodeInspect } from "../_chunks/response-6LJL3Qlz.mjs";
import { errorPlugin } from "../_chunks/_plugins-DOhVIkXu.mjs";
import { splitSetCookieString } from "cookie-es";

//#region src/adapters/_node/send.ts
async function sendNodeResponse(nodeRes, webRes) {
	if (!webRes) {
		nodeRes.statusCode = 500;
		return endNodeResponse(nodeRes);
	}
	if (webRes.nodeResponse) {
		const res = webRes.nodeResponse();
		writeHead(nodeRes, res.status, res.statusText, res.headers.flat());
		if (res.body) {
			if (res.body instanceof ReadableStream) return streamBody(res.body, nodeRes);
			else if (typeof res.body?.pipe === "function") {
				res.body.pipe(nodeRes);
				return new Promise((resolve) => nodeRes.on("close", resolve));
			}
			nodeRes.write(res.body);
		}
		return endNodeResponse(nodeRes);
	}
	const headerEntries = [];
	for (const [key, value] of webRes.headers) if (key === "set-cookie") for (const setCookie of splitSetCookieString(value)) headerEntries.push(["set-cookie", setCookie]);
	else headerEntries.push([key, value]);
	writeHead(nodeRes, webRes.status, webRes.statusText, headerEntries.flat());
	return webRes.body ? streamBody(webRes.body, nodeRes) : endNodeResponse(nodeRes);
}
function writeHead(nodeRes, status, statusText, headers) {
	if (!nodeRes.headersSent) if (nodeRes.req?.httpVersion === "2.0") nodeRes.writeHead(status, headers.flat());
	else nodeRes.writeHead(status, statusText, headers.flat());
}
function endNodeResponse(nodeRes) {
	return new Promise((resolve) => nodeRes.end(resolve));
}
function streamBody(stream, nodeRes) {
	if (nodeRes.destroyed) {
		stream.cancel();
		return;
	}
	const reader = stream.getReader();
	function streamCancel(error) {
		reader.cancel(error).catch(() => {});
		if (error) nodeRes.destroy(error);
	}
	function streamHandle({ done, value }) {
		try {
			if (done) nodeRes.end();
			else if (nodeRes.write(value)) reader.read().then(streamHandle, streamCancel);
			else nodeRes.once("drain", () => reader.read().then(streamHandle, streamCancel));
		} catch (error) {
			streamCancel(error instanceof Error ? error : void 0);
		}
	}
	nodeRes.on("close", streamCancel);
	nodeRes.on("error", streamCancel);
	reader.read().then(streamHandle, streamCancel);
	return reader.closed.finally(() => {
		nodeRes.off("close", streamCancel);
		nodeRes.off("error", streamCancel);
	});
}

//#endregion
//#region src/adapters/_node/url.ts
const NodeRequestURL = /* @__PURE__ */ (() => {
	const _URL = class URL {
		_node;
		_hash = "";
		_username = "";
		_password = "";
		_protocol;
		_hostname;
		_port;
		_pathname;
		_search;
		_searchParams;
		constructor(nodeCtx) {
			this._node = nodeCtx;
		}
		get hash() {
			return this._hash;
		}
		set hash(value) {
			this._hash = value;
		}
		get username() {
			return this._username;
		}
		set username(value) {
			this._username = value;
		}
		get password() {
			return this._password;
		}
		set password(value) {
			this._password = value;
		}
		get host() {
			return this._node.req.headers.host || this._node.req.headers[":authority"] || "";
		}
		set host(value) {
			this._hostname = void 0;
			this._port = void 0;
			this._node.req.headers.host = value;
		}
		get hostname() {
			if (this._hostname === void 0) {
				const [hostname, port] = parseHost(this._node.req.headers.host);
				if (this._port === void 0 && port) this._port = String(Number.parseInt(port) || "");
				this._hostname = hostname || "localhost";
			}
			return this._hostname;
		}
		set hostname(value) {
			this._hostname = value;
		}
		get port() {
			if (this._port === void 0) {
				const [hostname, port] = parseHost(this._node.req.headers.host);
				if (this._hostname === void 0 && hostname) this._hostname = hostname;
				this._port = port || String(this._node.req.socket?.localPort || "");
			}
			return this._port;
		}
		set port(value) {
			this._port = String(Number.parseInt(value) || "");
		}
		get pathname() {
			if (this._pathname === void 0) {
				const [pathname, search] = parsePath(this._node.req.url || "/");
				this._pathname = pathname;
				if (this._search === void 0) this._search = search;
			}
			return this._pathname;
		}
		set pathname(value) {
			if (value[0] !== "/") value = "/" + value;
			if (value === this._pathname) return;
			this._pathname = value;
			this._node.req.url = value + this.search;
		}
		get search() {
			if (this._search === void 0) {
				const [pathname, search] = parsePath(this._node.req.url || "/");
				this._search = search;
				if (this._pathname === void 0) this._pathname = pathname;
			}
			return this._search;
		}
		set search(value) {
			if (value === "?") value = "";
			else if (value && value[0] !== "?") value = "?" + value;
			if (value === this._search) return;
			this._search = value;
			this._searchParams = void 0;
			this._node.req.url = this.pathname + value;
		}
		get searchParams() {
			if (!this._searchParams) this._searchParams = new URLSearchParams(this.search);
			return this._searchParams;
		}
		set searchParams(value) {
			this._searchParams = value;
			this._search = value.toString();
		}
		get protocol() {
			if (!this._protocol) this._protocol = this._node.req.socket?.encrypted || this._node.req.headers["x-forwarded-proto"] === "https" ? "https:" : "http:";
			return this._protocol;
		}
		set protocol(value) {
			this._protocol = value;
		}
		get origin() {
			return `${this.protocol}//${this.host}`;
		}
		set origin(_value) {}
		get href() {
			return `${this.protocol}//${this.host}${this.pathname}${this.search}`;
		}
		set href(value) {
			const _url = new globalThis.URL(value);
			this._protocol = _url.protocol;
			this.username = _url.username;
			this.password = _url.password;
			this._hostname = _url.hostname;
			this._port = _url.port;
			this.pathname = _url.pathname;
			this.search = _url.search;
			this.hash = _url.hash;
		}
		toString() {
			return this.href;
		}
		toJSON() {
			return this.href;
		}
		get [Symbol.toStringTag]() {
			return "URL";
		}
		[kNodeInspect]() {
			return this.href;
		}
	};
	Object.setPrototypeOf(_URL.prototype, globalThis.URL.prototype);
	return _URL;
})();
function parsePath(input) {
	const url = (input || "/").replace(/\\/g, "/");
	const qIndex = url.indexOf("?");
	if (qIndex === -1) return [url, ""];
	return [url.slice(0, qIndex), url.slice(qIndex)];
}
function parseHost(host) {
	const s = (host || "").split(":");
	return [s[0], String(Number.parseInt(s[1]) || "")];
}

//#endregion
//#region src/adapters/_node/request.ts
const NodeRequest = /* @__PURE__ */ (() => {
	const { Readable } = process.getBuiltinModule("node:stream");
	const NativeRequest = globalThis._Request ??= globalThis.Request;
	const PatchedRequest = class Request extends NativeRequest {
		static _srvx = true;
		constructor(input, options) {
			if (typeof input === "object" && "_request" in input) input = input._request;
			if ((options?.body)?.getReader !== void 0) options.duplex ??= "half";
			super(input, options);
		}
	};
	if (!globalThis.Request._srvx) globalThis.Request = PatchedRequest;
	class NodeRequest$1 {
		_node;
		_url;
		runtime;
		#request;
		#headers;
		#abortSignal;
		constructor(ctx) {
			this._node = ctx;
			this._url = new NodeRequestURL({ req: ctx.req });
			this.runtime = {
				name: "node",
				node: ctx
			};
		}
		get ip() {
			return this._node.req.socket?.remoteAddress;
		}
		get method() {
			return this._node.req.method || "GET";
		}
		get url() {
			return this._url.href;
		}
		get headers() {
			return this.#headers ||= new NodeRequestHeaders(this._node);
		}
		get signal() {
			if (!this.#abortSignal) {
				this.#abortSignal = new AbortController();
				this._node.req.once("close", () => {
					this.#abortSignal?.abort();
				});
			}
			return this.#abortSignal.signal;
		}
		get _request() {
			if (!this.#request) {
				const method = this.method;
				const hasBody = !(method === "GET" || method === "HEAD");
				this.#request = new PatchedRequest(this.url, {
					method,
					headers: this.headers,
					signal: this.signal,
					body: hasBody ? Readable.toWeb(this._node.req) : void 0
				});
			}
			return this.#request;
		}
	}
	inheritProps(NodeRequest$1.prototype, NativeRequest.prototype, "_request");
	Object.setPrototypeOf(NodeRequest$1.prototype, PatchedRequest.prototype);
	return NodeRequest$1;
})();

//#endregion
//#region src/adapters/node.ts
function serve(options) {
	return new NodeServer(options);
}
function toNodeHandler(fetchHandler) {
	return (nodeReq, nodeRes) => {
		const request = new NodeRequest({
			req: nodeReq,
			res: nodeRes
		});
		const res = fetchHandler(request);
		return res instanceof Promise ? res.then((resolvedRes) => sendNodeResponse(nodeRes, resolvedRes)) : sendNodeResponse(nodeRes, res);
	};
}
var NodeServer = class {
	runtime = "node";
	options;
	node;
	serveOptions;
	fetch;
	#isSecure;
	#listeningPromise;
	#wait;
	constructor(options) {
		this.options = {
			...options,
			middleware: [...options.middleware || []]
		};
		for (const plugin of options.plugins || []) plugin(this);
		errorPlugin(this);
		const fetchHandler = this.fetch = wrapFetch(this);
		this.#wait = createWaitUntil();
		const handler = (nodeReq, nodeRes) => {
			const request = new NodeRequest({
				req: nodeReq,
				res: nodeRes
			});
			request.waitUntil = this.#wait.waitUntil;
			const res = fetchHandler(request);
			return res instanceof Promise ? res.then((resolvedRes) => sendNodeResponse(nodeRes, resolvedRes)) : sendNodeResponse(nodeRes, res);
		};
		const tls = resolveTLSOptions(this.options);
		const { port, hostname: host } = resolvePortAndHost(this.options);
		this.serveOptions = {
			port,
			host,
			exclusive: !this.options.reusePort,
			...tls ? {
				cert: tls.cert,
				key: tls.key,
				passphrase: tls.passphrase
			} : {},
			...this.options.node
		};
		let server;
		this.#isSecure = !!this.serveOptions.cert && this.options.protocol !== "http";
		const isHttp2 = this.options.node?.http2 ?? this.#isSecure;
		if (isHttp2) if (this.#isSecure) {
			const { createSecureServer } = process.getBuiltinModule("node:http2");
			server = createSecureServer({
				allowHTTP1: true,
				...this.serveOptions
			}, handler);
		} else throw new Error("node.http2 option requires tls certificate!");
		else if (this.#isSecure) {
			const { createServer } = process.getBuiltinModule("node:https");
			server = createServer(this.serveOptions, handler);
		} else {
			const { createServer } = process.getBuiltinModule("node:http");
			server = createServer(this.serveOptions, handler);
		}
		this.node = {
			server,
			handler
		};
		if (!options.manual) this.serve();
	}
	serve() {
		if (this.#listeningPromise) return Promise.resolve(this.#listeningPromise).then(() => this);
		this.#listeningPromise = new Promise((resolve) => {
			this.node.server.listen(this.serveOptions, () => {
				printListening(this.options, this.url);
				resolve();
			});
		});
	}
	get url() {
		const addr = this.node?.server?.address();
		if (!addr) return;
		return typeof addr === "string" ? addr : fmtURL(addr.address, addr.port, this.#isSecure);
	}
	ready() {
		return Promise.resolve(this.#listeningPromise).then(() => this);
	}
	async close(closeAll) {
		await Promise.all([this.#wait.wait(), new Promise((resolve, reject) => {
			const server = this.node?.server;
			if (!server) return resolve();
			if (closeAll && "closeAllConnections" in server) server.closeAllConnections();
			server.close((error) => error ? reject(error) : resolve());
		})]);
	}
};

//#endregion
export { NodeResponse as FastResponse, FastURL, NodeRequest, NodeRequestHeaders, NodeResponse, NodeResponseHeaders, sendNodeResponse, serve, toNodeHandler };