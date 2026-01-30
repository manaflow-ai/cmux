//#region src/_url.ts
/**
* Wrapper for URL with fast path access to `.pathname` and `.search` props.
*
* **NOTE:** It is assumed that the input URL is already ecoded and formatted from an HTTP request and contains no hash.
*
* **NOTE:** Triggering the setters or getters on other props will deoptimize to full URL parsing.
*/
const FastURL = /* @__PURE__ */ (() => {
	const FastURL$1 = class URL {
		#originalURL;
		#parsedURL;
		_pathname;
		_urlqindex;
		_query;
		_search;
		constructor(url) {
			this.#originalURL = url;
		}
		get _url() {
			if (!this.#parsedURL) this.#parsedURL = new globalThis.URL(this.#originalURL);
			return this.#parsedURL;
		}
		toString() {
			return this._url.toString();
		}
		toJSON() {
			return this.toString();
		}
		get pathname() {
			if (this.#parsedURL) return this.#parsedURL.pathname;
			if (this._pathname === void 0) {
				const url = this.#originalURL;
				const protoIndex = url.indexOf("://");
				if (protoIndex === -1) return this._url.pathname;
				const pIndex = url.indexOf("/", protoIndex + 4);
				if (pIndex === -1) return this._url.pathname;
				const qIndex = this._urlqindex = url.indexOf("?", pIndex);
				this._pathname = url.slice(pIndex, qIndex === -1 ? void 0 : qIndex);
			}
			return this._pathname;
		}
		set pathname(value) {
			this._pathname = void 0;
			this._url.pathname = value;
		}
		get searchParams() {
			if (this.#parsedURL) return this.#parsedURL.searchParams;
			if (!this._query) this._query = new URLSearchParams(this.search);
			return this._query;
		}
		get search() {
			if (this.#parsedURL) return this.#parsedURL.search;
			if (this._search === void 0) {
				const qIndex = this._urlqindex;
				if (qIndex === -1 || qIndex === this.#originalURL.length - 1) this._search = "";
				else this._search = qIndex === void 0 ? this._url.search : this.#originalURL.slice(qIndex);
			}
			return this._search;
		}
		set search(value) {
			this._search = void 0;
			this._query = void 0;
			this._url.search = value;
		}
	};
	const slowProps = [
		"hash",
		"host",
		"hostname",
		"href",
		"origin",
		"password",
		"port",
		"protocol",
		"username"
	];
	for (const prop of slowProps) Object.defineProperty(FastURL$1.prototype, prop, {
		get() {
			return this._url[prop];
		},
		set(value) {
			this._url[prop] = value;
		}
	});
	Object.setPrototypeOf(FastURL$1, globalThis.URL);
	return FastURL$1;
})();

//#endregion
export { FastURL as FastURL$1 };