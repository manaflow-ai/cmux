import { splitSetCookieString } from "cookie-es";

//#region src/adapters/_node/_common.ts
const kNodeInspect = /* @__PURE__ */ Symbol.for("nodejs.util.inspect.custom");
function inheritProps(target, source, sourceKey) {
	for (const key of Object.getOwnPropertyNames(source)) {
		if (key in target) continue;
		const desc = Object.getOwnPropertyDescriptor(source, key);
		if (desc.get) Object.defineProperty(target, key, {
			...desc,
			get() {
				return this[sourceKey][key];
			}
		});
		else if (typeof desc.value === "function") Object.defineProperty(target, key, {
			...desc,
			value(...args) {
				return this[sourceKey][key](...args);
			}
		});
		else Object.defineProperty(target, key, desc);
	}
}

//#endregion
//#region src/adapters/_node/headers.ts
const NodeRequestHeaders = /* @__PURE__ */ (() => {
	const _Headers = class Headers$1 {
		_node;
		constructor(nodeCtx) {
			this._node = nodeCtx;
		}
		append(name, value) {
			name = validateHeader(name);
			const _headers = this._node.req.headers;
			const _current = _headers[name];
			if (_current) if (Array.isArray(_current)) _current.push(value);
			else _headers[name] = [_current, value];
			else _headers[name] = value;
		}
		delete(name) {
			name = validateHeader(name);
			this._node.req.headers[name] = void 0;
		}
		get(name) {
			name = validateHeader(name);
			const rawValue = this._node.req.headers[name];
			if (rawValue === void 0) return null;
			return _normalizeValue(this._node.req.headers[name]);
		}
		getSetCookie() {
			const setCookie = this._node.req.headers["set-cookie"];
			if (!setCookie || setCookie.length === 0) return [];
			return splitSetCookieString(setCookie);
		}
		has(name) {
			name = validateHeader(name);
			return !!this._node.req.headers[name];
		}
		set(name, value) {
			name = validateHeader(name);
			this._node.req.headers[name] = value;
		}
		get count() {
			throw new Error("Method not implemented.");
		}
		getAll(_name) {
			throw new Error("Method not implemented.");
		}
		toJSON() {
			const _headers = this._node.req.headers;
			const result = {};
			for (const key in _headers) if (_headers[key]) result[key] = _normalizeValue(_headers[key]);
			return result;
		}
		forEach(cb, thisArg) {
			const _headers = this._node.req.headers;
			for (const key in _headers) if (_headers[key]) cb.call(thisArg, _normalizeValue(_headers[key]), key, this);
		}
		*entries() {
			const headers = this._node.req.headers;
			const isHttp2 = this._node.req.httpVersion === "2.0";
			for (const key in headers) if (!isHttp2 || key[0] !== ":") yield [key, _normalizeValue(headers[key])];
		}
		*keys() {
			const keys = Object.keys(this._node.req.headers);
			for (const key of keys) yield key;
		}
		*values() {
			const values = Object.values(this._node.req.headers);
			for (const value of values) yield _normalizeValue(value);
		}
		[Symbol.iterator]() {
			return this.entries()[Symbol.iterator]();
		}
		get [Symbol.toStringTag]() {
			return "Headers";
		}
		[kNodeInspect]() {
			return Object.fromEntries(this.entries());
		}
	};
	Object.setPrototypeOf(_Headers.prototype, globalThis.Headers.prototype);
	return _Headers;
})();
const NodeResponseHeaders = /* @__PURE__ */ (() => {
	const _Headers = class Headers$1 {
		_node;
		constructor(nodeCtx) {
			this._node = nodeCtx;
		}
		append(name, value) {
			this._node.res.appendHeader(name, value);
		}
		delete(name) {
			this._node.res.removeHeader(name);
		}
		get(name) {
			const rawValue = this._node.res.getHeader(name);
			if (rawValue === void 0) return null;
			return _normalizeValue(rawValue);
		}
		getSetCookie() {
			const setCookie = _normalizeValue(this._node.res.getHeader("set-cookie"));
			if (!setCookie) return [];
			return splitSetCookieString(setCookie);
		}
		has(name) {
			return this._node.res.hasHeader(name);
		}
		set(name, value) {
			this._node.res.setHeader(name, value);
		}
		get count() {
			throw new Error("Method not implemented.");
		}
		getAll(_name) {
			throw new Error("Method not implemented.");
		}
		toJSON() {
			const _headers = this._node.res.getHeaders();
			const result = {};
			for (const key in _headers) if (_headers[key]) result[key] = _normalizeValue(_headers[key]);
			return result;
		}
		forEach(cb, thisArg) {
			const _headers = this._node.res.getHeaders();
			for (const key in _headers) if (_headers[key]) cb.call(thisArg, _normalizeValue(_headers[key]), key, this);
		}
		*entries() {
			const _headers = this._node.res.getHeaders();
			for (const key in _headers) yield [key, _normalizeValue(_headers[key])];
		}
		*keys() {
			const keys = this._node.res.getHeaderNames();
			for (const key of keys) yield key;
		}
		*values() {
			const values = Object.values(this._node.res.getHeaders());
			for (const value of values) yield _normalizeValue(value);
		}
		[Symbol.iterator]() {
			return this.entries()[Symbol.iterator]();
		}
		get [Symbol.toStringTag]() {
			return "Headers";
		}
		[kNodeInspect]() {
			return Object.fromEntries(this.entries());
		}
	};
	Object.setPrototypeOf(_Headers.prototype, globalThis.Headers.prototype);
	return _Headers;
})();
function _normalizeValue(value) {
	if (Array.isArray(value)) return value.join(", ");
	return typeof value === "string" ? value : String(value ?? "");
}
function validateHeader(name) {
	if (name[0] === ":") throw new TypeError(`${JSON.stringify(name)} is an invalid header name.`);
	return name.toLowerCase();
}

//#endregion
//#region src/adapters/_node/response.ts
/**
* Fast Response for Node.js runtime
*
* It is faster because in most cases it doesn't create a full Response instance.
*/
const NodeResponse = /* @__PURE__ */ (() => {
	const NativeResponse = globalThis.Response;
	const STATUS_CODES = globalThis.process?.getBuiltinModule("node:http")?.STATUS_CODES || {};
	class NodeResponse$1 {
		#body;
		#init;
		#headers;
		#response;
		constructor(body, init) {
			this.#body = body;
			this.#init = init;
		}
		get status() {
			return this.#response?.status || this.#init?.status || 200;
		}
		get statusText() {
			return this.#response?.statusText || this.#init?.statusText || STATUS_CODES[this.status] || "";
		}
		get headers() {
			if (this.#response) return this.#response.headers;
			if (this.#headers) return this.#headers;
			const initHeaders = this.#init?.headers;
			return this.#headers = initHeaders instanceof Headers ? initHeaders : new Headers(initHeaders);
		}
		get ok() {
			if (this.#response) return this.#response.ok;
			const status = this.status;
			return status >= 200 && status < 300;
		}
		get _response() {
			if (this.#response) return this.#response;
			this.#response = new NativeResponse(this.#body, this.#headers ? {
				...this.#init,
				headers: this.#headers
			} : this.#init);
			this.#init = void 0;
			this.#headers = void 0;
			this.#body = void 0;
			return this.#response;
		}
		nodeResponse() {
			const status = this.status;
			const statusText = this.statusText;
			let body;
			let contentType;
			let contentLength;
			if (this.#response) body = this.#response.body;
			else if (this.#body) if (this.#body instanceof ReadableStream) body = this.#body;
			else if (typeof this.#body === "string") {
				body = this.#body;
				contentType = "text/plain; charset=UTF-8";
				contentLength = Buffer.byteLength(this.#body);
			} else if (this.#body instanceof ArrayBuffer) {
				body = Buffer.from(this.#body);
				contentLength = this.#body.byteLength;
			} else if (this.#body instanceof Uint8Array) {
				body = this.#body;
				contentLength = this.#body.byteLength;
			} else if (this.#body instanceof DataView) {
				body = Buffer.from(this.#body.buffer);
				contentLength = this.#body.byteLength;
			} else if (this.#body instanceof Blob) {
				body = this.#body.stream();
				contentType = this.#body.type;
				contentLength = this.#body.size;
			} else if (typeof this.#body.pipe === "function") body = this.#body;
			else body = this._response.body;
			const rawNodeHeaders = [];
			const initHeaders = this.#init?.headers;
			const headerEntries = this.#response?.headers || this.#headers || (initHeaders ? Array.isArray(initHeaders) ? initHeaders : initHeaders?.entries ? initHeaders.entries() : Object.entries(initHeaders).map(([k, v]) => [k.toLowerCase(), v]) : void 0);
			let hasContentTypeHeader;
			let hasContentLength;
			if (headerEntries) for (const [key, value] of headerEntries) {
				if (key === "set-cookie") {
					for (const setCookie of splitSetCookieString(value)) rawNodeHeaders.push(["set-cookie", setCookie]);
					continue;
				}
				rawNodeHeaders.push([key, value]);
				if (key === "content-type") hasContentTypeHeader = true;
				else if (key === "content-length") hasContentLength = true;
			}
			if (contentType && !hasContentTypeHeader) rawNodeHeaders.push(["content-type", contentType]);
			if (contentLength && !hasContentLength) rawNodeHeaders.push(["content-length", String(contentLength)]);
			this.#init = void 0;
			this.#headers = void 0;
			this.#response = void 0;
			this.#body = void 0;
			return {
				status,
				statusText,
				headers: rawNodeHeaders,
				body
			};
		}
	}
	inheritProps(NodeResponse$1.prototype, NativeResponse.prototype, "_response");
	Object.setPrototypeOf(NodeResponse$1, NativeResponse);
	Object.setPrototypeOf(NodeResponse$1.prototype, NativeResponse.prototype);
	return NodeResponse$1;
})();

//#endregion
export { NodeRequestHeaders, NodeResponse, NodeResponseHeaders, inheritProps, kNodeInspect };