// src/helpers.ts
import { isNodeProcess } from "is-node-process";

// src/multipart/helpers.ts
import { Readable } from "stream";
import isBuffer from "is-buffer";
var supportsNewBlobFromArrayBuffer = new Promise((resolve) => {
  try {
    const helloAsArrayBuffer = new Uint8Array([104, 101, 108, 108, 111]);
    const blob = new Blob([helloAsArrayBuffer]);
    blob.text().then((text) => {
      resolve(text === "hello");
    }).catch(() => {
      resolve(false);
    });
  } catch {
    resolve(false);
  }
});
async function toReadableStream(value) {
  if (value instanceof ReadableStream) {
    return value;
  }
  if (value instanceof Blob) {
    return value.stream();
  }
  if (isNodeJsReadableStream(value)) {
    return Readable.toWeb(value);
  }
  let streamValue;
  if (value instanceof ArrayBuffer) {
    streamValue = new Uint8Array(value);
  } else if (isNodeJsBuffer(value)) {
    streamValue = value;
  } else {
    streamValue = stringToUint8Array(value);
  }
  if (await supportsNewBlobFromArrayBuffer) {
    return new Blob([streamValue]).stream();
  }
  return new ReadableStream({
    start(controller) {
      controller.enqueue(streamValue);
      controller.close();
    }
  });
}
function isNodeJsReadableStream(value) {
  return typeof value === "object" && typeof value.pipe === "function" && value.readable && typeof value._read === "function" && // @ts-expect-error _readableState does exists on Readable
  typeof value._readableState === "object";
}
function stringToUint8Array(s) {
  const enc = new TextEncoder();
  return enc.encode(s);
}
function isNodeJsBuffer(value) {
  return isBuffer(value);
}

// src/bytes.ts
var parseRegExp = /^((-|\+)?(\d+(?:\.\d+)?)) *(kb|mb|gb|tb|pb)$/i;
var map = {
  b: 1,
  // eslint-disable-next-line no-bitwise -- fine
  kb: 1 << 10,
  // eslint-disable-next-line no-bitwise -- fine
  mb: 1 << 20,
  // eslint-disable-next-line no-bitwise -- fine
  gb: 1 << 30,
  tb: Math.pow(1024, 4),
  pb: Math.pow(1024, 5)
};
function bytes(val) {
  if (typeof val === "number" && !isNaN(val)) {
    return val;
  }
  if (typeof val !== "string") {
    return null;
  }
  const results = parseRegExp.exec(val);
  let floatValue;
  let unit = "b";
  if (!results) {
    floatValue = parseInt(val, 10);
  } else {
    const [, res, , , unitMatch] = results;
    if (!res) {
      return null;
    }
    floatValue = parseFloat(res);
    if (unitMatch) {
      unit = unitMatch.toLowerCase();
    }
  }
  if (isNaN(floatValue)) {
    return null;
  }
  return Math.floor(map[unit] * floatValue);
}

// src/helpers.ts
var defaultVercelBlobApiUrl = "https://vercel.com/api/blob";
function getTokenFromOptionsOrEnv(options) {
  if (options == null ? void 0 : options.token) {
    return options.token;
  }
  if (process.env.BLOB_READ_WRITE_TOKEN) {
    return process.env.BLOB_READ_WRITE_TOKEN;
  }
  throw new BlobError(
    "No token found. Either configure the `BLOB_READ_WRITE_TOKEN` environment variable, or pass a `token` option to your calls."
  );
}
var BlobError = class extends Error {
  constructor(message) {
    super(`Vercel Blob: ${message}`);
  }
};
function getDownloadUrl(blobUrl) {
  const url = new URL(blobUrl);
  url.searchParams.set("download", "1");
  return url.toString();
}
function isPlainObject(value) {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  const prototype = Object.getPrototypeOf(value);
  return (prototype === null || prototype === Object.prototype || Object.getPrototypeOf(prototype) === null) && !(Symbol.toStringTag in value) && !(Symbol.iterator in value);
}
var disallowedPathnameCharacters = ["//"];
var supportsRequestStreams = (() => {
  if (isNodeProcess()) {
    return true;
  }
  const apiUrl = getApiUrl();
  if (apiUrl.startsWith("http://localhost")) {
    return false;
  }
  let duplexAccessed = false;
  const hasContentType = new Request(getApiUrl(), {
    body: new ReadableStream(),
    method: "POST",
    // @ts-expect-error -- TypeScript doesn't yet have duplex but it's in the spec: https://github.com/microsoft/TypeScript-DOM-lib-generator/pull/1729
    get duplex() {
      duplexAccessed = true;
      return "half";
    }
  }).headers.has("Content-Type");
  return duplexAccessed && !hasContentType;
})();
function getApiUrl(pathname = "") {
  let baseUrl = null;
  try {
    baseUrl = process.env.VERCEL_BLOB_API_URL || process.env.NEXT_PUBLIC_VERCEL_BLOB_API_URL;
  } catch {
  }
  return `${baseUrl || defaultVercelBlobApiUrl}${pathname}`;
}
var TEXT_ENCODER = typeof TextEncoder === "function" ? new TextEncoder() : null;
function computeBodyLength(body) {
  if (!body) {
    return 0;
  }
  if (typeof body === "string") {
    if (TEXT_ENCODER) {
      return TEXT_ENCODER.encode(body).byteLength;
    }
    return new Blob([body]).size;
  }
  if ("byteLength" in body && typeof body.byteLength === "number") {
    return body.byteLength;
  }
  if ("size" in body && typeof body.size === "number") {
    return body.size;
  }
  return 0;
}
var createChunkTransformStream = (chunkSize, onProgress) => {
  let buffer = new Uint8Array(0);
  return new TransformStream({
    transform(chunk, controller) {
      queueMicrotask(() => {
        const newBuffer = new Uint8Array(buffer.length + chunk.byteLength);
        newBuffer.set(buffer);
        newBuffer.set(new Uint8Array(chunk), buffer.length);
        buffer = newBuffer;
        while (buffer.length >= chunkSize) {
          const newChunk = buffer.slice(0, chunkSize);
          controller.enqueue(newChunk);
          onProgress == null ? void 0 : onProgress(newChunk.byteLength);
          buffer = buffer.slice(chunkSize);
        }
      });
    },
    flush(controller) {
      queueMicrotask(() => {
        if (buffer.length > 0) {
          controller.enqueue(buffer);
          onProgress == null ? void 0 : onProgress(buffer.byteLength);
        }
      });
    }
  });
};
function isReadableStream(value) {
  return (
    // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition -- Not present in Node.js 16
    globalThis.ReadableStream && // TODO: Can be removed once Node.js 16 is no more required internally
    value instanceof ReadableStream
  );
}
function isStream(value) {
  if (isReadableStream(value)) {
    return true;
  }
  if (isNodeJsReadableStream(value)) {
    return true;
  }
  return false;
}

// src/api.ts
import retry from "async-retry";

// src/is-network-error.ts
var objectToString = Object.prototype.toString;
var isError = (value) => objectToString.call(value) === "[object Error]";
var errorMessages = /* @__PURE__ */ new Set([
  "network error",
  // Chrome
  "Failed to fetch",
  // Chrome
  "NetworkError when attempting to fetch resource.",
  // Firefox
  "The Internet connection appears to be offline.",
  // Safari 16
  "Load failed",
  // Safari 17+
  "Network request failed",
  // `cross-fetch`
  "fetch failed",
  // Undici (Node.js)
  "terminated"
  // Undici (Node.js)
]);
function isNetworkError(error) {
  const isValid = error && isError(error) && error.name === "TypeError" && typeof error.message === "string";
  if (!isValid) {
    return false;
  }
  if (error.message === "Load failed") {
    return error.stack === void 0;
  }
  return errorMessages.has(error.message);
}

// src/debug.ts
var debugIsActive = false;
var _a, _b;
try {
  if (((_a = process.env.DEBUG) == null ? void 0 : _a.includes("blob")) || ((_b = process.env.NEXT_PUBLIC_DEBUG) == null ? void 0 : _b.includes("blob"))) {
    debugIsActive = true;
  }
} catch (error) {
}
function debug(message, ...args) {
  if (debugIsActive) {
    console.debug(`vercel-blob: ${message}`, ...args);
  }
}

// src/fetch.ts
import { fetch } from "undici";
var hasFetch = typeof fetch === "function";
var hasFetchWithUploadProgress = hasFetch && supportsRequestStreams;
var CHUNK_SIZE = 64 * 1024;
var blobFetch = async ({
  input,
  init,
  onUploadProgress
}) => {
  debug("using fetch");
  let body;
  if (init.body) {
    if (onUploadProgress) {
      const stream = await toReadableStream(init.body);
      let loaded = 0;
      const chunkTransformStream = createChunkTransformStream(
        CHUNK_SIZE,
        (newLoaded) => {
          loaded += newLoaded;
          onUploadProgress(loaded);
        }
      );
      body = stream.pipeThrough(chunkTransformStream);
    } else {
      body = init.body;
    }
  }
  const duplex = supportsRequestStreams && body && isStream(body) ? "half" : void 0;
  return fetch(
    input,
    // @ts-expect-error -- Blob and Nodejs Blob are triggering type errors, fine with it
    {
      ...init,
      ...init.body ? { body } : {},
      duplex
    }
  );
};

// src/xhr.ts
var hasXhr = typeof XMLHttpRequest !== "undefined";
var blobXhr = async ({
  input,
  init,
  onUploadProgress
}) => {
  debug("using xhr");
  let body = null;
  if (init.body) {
    if (isReadableStream(init.body)) {
      body = await new Response(init.body).blob();
    } else {
      body = init.body;
    }
  }
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open(init.method || "GET", input.toString(), true);
    if (onUploadProgress) {
      xhr.upload.addEventListener("progress", (event) => {
        if (event.lengthComputable) {
          onUploadProgress(event.loaded);
        }
      });
    }
    xhr.onload = () => {
      var _a3;
      if ((_a3 = init.signal) == null ? void 0 : _a3.aborted) {
        reject(new DOMException("The user aborted the request.", "AbortError"));
        return;
      }
      const headers = new Headers();
      const rawHeaders = xhr.getAllResponseHeaders().trim().split(/[\r\n]+/);
      rawHeaders.forEach((line) => {
        const parts = line.split(": ");
        const key = parts.shift();
        const value = parts.join(": ");
        if (key) headers.set(key.toLowerCase(), value);
      });
      const response = new Response(xhr.response, {
        status: xhr.status,
        statusText: xhr.statusText,
        headers
      });
      resolve(response);
    };
    xhr.onerror = () => {
      reject(new TypeError("Network request failed"));
    };
    xhr.ontimeout = () => {
      reject(new TypeError("Network request timed out"));
    };
    xhr.onabort = () => {
      reject(new DOMException("The user aborted a request.", "AbortError"));
    };
    if (init.headers) {
      const headers = new Headers(init.headers);
      headers.forEach((value, key) => {
        xhr.setRequestHeader(key, value);
      });
    }
    if (init.signal) {
      init.signal.addEventListener("abort", () => {
        xhr.abort();
      });
      if (init.signal.aborted) {
        xhr.abort();
        return;
      }
    }
    xhr.send(body);
  });
};

// src/request.ts
var blobRequest = async ({
  input,
  init,
  onUploadProgress
}) => {
  if (onUploadProgress) {
    if (hasFetchWithUploadProgress) {
      return blobFetch({ input, init, onUploadProgress });
    }
    if (hasXhr) {
      return blobXhr({ input, init, onUploadProgress });
    }
  }
  if (hasFetch) {
    return blobFetch({ input, init });
  }
  if (hasXhr) {
    return blobXhr({ input, init });
  }
  throw new Error("No request implementation available");
};

// src/dom-exception.ts
var _a2;
var DOMException2 = (_a2 = globalThis.DOMException) != null ? _a2 : (() => {
  try {
    atob("~");
  } catch (err) {
    return Object.getPrototypeOf(err).constructor;
  }
})();

// src/api.ts
var MAXIMUM_PATHNAME_LENGTH = 950;
var BlobAccessError = class extends BlobError {
  constructor() {
    super("Access denied, please provide a valid token for this resource.");
  }
};
var BlobContentTypeNotAllowedError = class extends BlobError {
  constructor(message) {
    super(`Content type mismatch, ${message}.`);
  }
};
var BlobPathnameMismatchError = class extends BlobError {
  constructor(message) {
    super(
      `Pathname mismatch, ${message}. Check the pathname used in upload() or put() matches the one from the client token.`
    );
  }
};
var BlobClientTokenExpiredError = class extends BlobError {
  constructor() {
    super("Client token has expired.");
  }
};
var BlobFileTooLargeError = class extends BlobError {
  constructor(message) {
    super(`File is too large, ${message}.`);
  }
};
var BlobStoreNotFoundError = class extends BlobError {
  constructor() {
    super("This store does not exist.");
  }
};
var BlobStoreSuspendedError = class extends BlobError {
  constructor() {
    super("This store has been suspended.");
  }
};
var BlobUnknownError = class extends BlobError {
  constructor() {
    super("Unknown error, please visit https://vercel.com/help.");
  }
};
var BlobNotFoundError = class extends BlobError {
  constructor() {
    super("The requested blob does not exist");
  }
};
var BlobServiceNotAvailable = class extends BlobError {
  constructor() {
    super("The blob service is currently not available. Please try again.");
  }
};
var BlobServiceRateLimited = class extends BlobError {
  constructor(seconds) {
    super(
      `Too many requests please lower the number of concurrent requests ${seconds ? ` - try again in ${seconds} seconds` : ""}.`
    );
    this.retryAfter = seconds != null ? seconds : 0;
  }
};
var BlobRequestAbortedError = class extends BlobError {
  constructor() {
    super("The request was aborted.");
  }
};
var BLOB_API_VERSION = 11;
function getApiVersion() {
  let versionOverride = null;
  try {
    versionOverride = process.env.VERCEL_BLOB_API_VERSION_OVERRIDE || process.env.NEXT_PUBLIC_VERCEL_BLOB_API_VERSION_OVERRIDE;
  } catch {
  }
  return `${versionOverride != null ? versionOverride : BLOB_API_VERSION}`;
}
function getRetries() {
  try {
    const retries = process.env.VERCEL_BLOB_RETRIES || "10";
    return parseInt(retries, 10);
  } catch {
    return 10;
  }
}
function createBlobServiceRateLimited(response) {
  const retryAfter = response.headers.get("retry-after");
  return new BlobServiceRateLimited(
    retryAfter ? parseInt(retryAfter, 10) : void 0
  );
}
async function getBlobError(response) {
  var _a3, _b2, _c;
  let code;
  let message;
  try {
    const data = await response.json();
    code = (_b2 = (_a3 = data.error) == null ? void 0 : _a3.code) != null ? _b2 : "unknown_error";
    message = (_c = data.error) == null ? void 0 : _c.message;
  } catch {
    code = "unknown_error";
  }
  if ((message == null ? void 0 : message.includes("contentType")) && message.includes("is not allowed")) {
    code = "content_type_not_allowed";
  }
  if ((message == null ? void 0 : message.includes('"pathname"')) && message.includes("does not match the token payload")) {
    code = "client_token_pathname_mismatch";
  }
  if (message === "Token expired") {
    code = "client_token_expired";
  }
  if (message == null ? void 0 : message.includes("the file length cannot be greater than")) {
    code = "file_too_large";
  }
  let error;
  switch (code) {
    case "store_suspended":
      error = new BlobStoreSuspendedError();
      break;
    case "forbidden":
      error = new BlobAccessError();
      break;
    case "content_type_not_allowed":
      error = new BlobContentTypeNotAllowedError(message);
      break;
    case "client_token_pathname_mismatch":
      error = new BlobPathnameMismatchError(message);
      break;
    case "client_token_expired":
      error = new BlobClientTokenExpiredError();
      break;
    case "file_too_large":
      error = new BlobFileTooLargeError(message);
      break;
    case "not_found":
      error = new BlobNotFoundError();
      break;
    case "store_not_found":
      error = new BlobStoreNotFoundError();
      break;
    case "bad_request":
      error = new BlobError(message != null ? message : "Bad request");
      break;
    case "service_unavailable":
      error = new BlobServiceNotAvailable();
      break;
    case "rate_limited":
      error = createBlobServiceRateLimited(response);
      break;
    case "unknown_error":
    case "not_allowed":
    default:
      error = new BlobUnknownError();
      break;
  }
  return { code, error };
}
async function requestApi(pathname, init, commandOptions) {
  const apiVersion = getApiVersion();
  const token = getTokenFromOptionsOrEnv(commandOptions);
  const extraHeaders = getProxyThroughAlternativeApiHeaderFromEnv();
  const [, , , storeId = ""] = token.split("_");
  const requestId = `${storeId}:${Date.now()}:${Math.random().toString(16).slice(2)}`;
  let retryCount = 0;
  let bodyLength = 0;
  let totalLoaded = 0;
  const sendBodyLength = (commandOptions == null ? void 0 : commandOptions.onUploadProgress) || shouldUseXContentLength();
  if (init.body && // 1. For upload progress we always need to know the total size of the body
  // 2. In development we need the header for put() to work correctly when passing a stream
  sendBodyLength) {
    bodyLength = computeBodyLength(init.body);
  }
  if (commandOptions == null ? void 0 : commandOptions.onUploadProgress) {
    commandOptions.onUploadProgress({
      loaded: 0,
      total: bodyLength,
      percentage: 0
    });
  }
  const apiResponse = await retry(
    async (bail) => {
      let res;
      try {
        res = await blobRequest({
          input: getApiUrl(pathname),
          init: {
            ...init,
            headers: {
              "x-api-blob-request-id": requestId,
              "x-api-blob-request-attempt": String(retryCount),
              "x-api-version": apiVersion,
              ...sendBodyLength ? { "x-content-length": String(bodyLength) } : {},
              authorization: `Bearer ${token}`,
              ...extraHeaders,
              ...init.headers
            }
          },
          onUploadProgress: (commandOptions == null ? void 0 : commandOptions.onUploadProgress) ? (loaded) => {
            var _a3;
            const total = bodyLength !== 0 ? bodyLength : loaded;
            totalLoaded = loaded;
            const percentage = bodyLength > 0 ? Number((loaded / total * 100).toFixed(2)) : 0;
            if (percentage === 100 && bodyLength > 0) {
              return;
            }
            (_a3 = commandOptions.onUploadProgress) == null ? void 0 : _a3.call(commandOptions, {
              loaded,
              // When passing a stream to put(), we have no way to know the total size of the body.
              // Instead of defining total as total?: number we decided to set the total to the currently
              // loaded number. This is not inaccurate and way more practical for DX.
              // Passing down a stream to put() is very rare
              total,
              percentage
            });
          } : void 0
        });
      } catch (error2) {
        if (error2 instanceof DOMException2 && error2.name === "AbortError") {
          bail(new BlobRequestAbortedError());
          return;
        }
        if (isNetworkError(error2)) {
          throw error2;
        }
        if (error2 instanceof TypeError) {
          bail(error2);
          return;
        }
        throw error2;
      }
      if (res.ok) {
        return res;
      }
      const { code, error } = await getBlobError(res);
      if (code === "unknown_error" || code === "service_unavailable" || code === "internal_server_error") {
        throw error;
      }
      bail(error);
    },
    {
      retries: getRetries(),
      onRetry: (error) => {
        if (error instanceof Error) {
          debug(`retrying API request to ${pathname}`, error.message);
        }
        retryCount = retryCount + 1;
      }
    }
  );
  if (!apiResponse) {
    throw new BlobUnknownError();
  }
  if (commandOptions == null ? void 0 : commandOptions.onUploadProgress) {
    commandOptions.onUploadProgress({
      loaded: totalLoaded,
      total: totalLoaded,
      percentage: 100
    });
  }
  return await apiResponse.json();
}
function getProxyThroughAlternativeApiHeaderFromEnv() {
  const extraHeaders = {};
  try {
    if ("VERCEL_BLOB_PROXY_THROUGH_ALTERNATIVE_API" in process.env && process.env.VERCEL_BLOB_PROXY_THROUGH_ALTERNATIVE_API !== void 0) {
      extraHeaders["x-proxy-through-alternative-api"] = process.env.VERCEL_BLOB_PROXY_THROUGH_ALTERNATIVE_API;
    } else if ("NEXT_PUBLIC_VERCEL_BLOB_PROXY_THROUGH_ALTERNATIVE_API" in process.env && process.env.NEXT_PUBLIC_VERCEL_BLOB_PROXY_THROUGH_ALTERNATIVE_API !== void 0) {
      extraHeaders["x-proxy-through-alternative-api"] = process.env.NEXT_PUBLIC_VERCEL_BLOB_PROXY_THROUGH_ALTERNATIVE_API;
    }
  } catch {
  }
  return extraHeaders;
}
function shouldUseXContentLength() {
  try {
    return process.env.VERCEL_BLOB_USE_X_CONTENT_LENGTH === "1";
  } catch {
    return false;
  }
}

// src/put-helpers.ts
var putOptionHeaderMap = {
  cacheControlMaxAge: "x-cache-control-max-age",
  addRandomSuffix: "x-add-random-suffix",
  allowOverwrite: "x-allow-overwrite",
  contentType: "x-content-type"
};
function createPutHeaders(allowedOptions, options) {
  const headers = {};
  if (allowedOptions.includes("contentType") && options.contentType) {
    headers[putOptionHeaderMap.contentType] = options.contentType;
  }
  if (allowedOptions.includes("addRandomSuffix") && options.addRandomSuffix !== void 0) {
    headers[putOptionHeaderMap.addRandomSuffix] = options.addRandomSuffix ? "1" : "0";
  }
  if (allowedOptions.includes("allowOverwrite") && options.allowOverwrite !== void 0) {
    headers[putOptionHeaderMap.allowOverwrite] = options.allowOverwrite ? "1" : "0";
  }
  if (allowedOptions.includes("cacheControlMaxAge") && options.cacheControlMaxAge !== void 0) {
    headers[putOptionHeaderMap.cacheControlMaxAge] = options.cacheControlMaxAge.toString();
  }
  return headers;
}
async function createPutOptions({
  pathname,
  options,
  extraChecks,
  getToken
}) {
  if (!pathname) {
    throw new BlobError("pathname is required");
  }
  if (pathname.length > MAXIMUM_PATHNAME_LENGTH) {
    throw new BlobError(
      `pathname is too long, maximum length is ${MAXIMUM_PATHNAME_LENGTH}`
    );
  }
  for (const invalidCharacter of disallowedPathnameCharacters) {
    if (pathname.includes(invalidCharacter)) {
      throw new BlobError(
        `pathname cannot contain "${invalidCharacter}", please encode it if needed`
      );
    }
  }
  if (!options) {
    throw new BlobError("missing options, see usage");
  }
  if (options.access !== "public") {
    throw new BlobError('access must be "public"');
  }
  if (extraChecks) {
    extraChecks(options);
  }
  if (getToken) {
    options.token = await getToken(pathname, options);
  }
  return options;
}

// src/multipart/complete.ts
function createCompleteMultipartUploadMethod({ allowedOptions, getToken, extraChecks }) {
  return async (pathname, parts, optionsInput) => {
    const options = await createPutOptions({
      pathname,
      options: optionsInput,
      extraChecks,
      getToken
    });
    const headers = createPutHeaders(allowedOptions, options);
    return completeMultipartUpload({
      uploadId: options.uploadId,
      key: options.key,
      pathname,
      headers,
      options,
      parts
    });
  };
}
async function completeMultipartUpload({
  uploadId,
  key,
  pathname,
  parts,
  headers,
  options
}) {
  const params = new URLSearchParams({ pathname });
  try {
    const response = await requestApi(
      `/mpu?${params.toString()}`,
      {
        method: "POST",
        headers: {
          ...headers,
          "content-type": "application/json",
          "x-mpu-action": "complete",
          "x-mpu-upload-id": uploadId,
          // key can be any utf8 character so we need to encode it as HTTP headers can only be us-ascii
          // https://www.rfc-editor.org/rfc/rfc7230#swection-3.2.4
          "x-mpu-key": encodeURIComponent(key)
        },
        body: JSON.stringify(parts),
        signal: options.abortSignal
      },
      options
    );
    debug("mpu: complete", response);
    return response;
  } catch (error) {
    if (error instanceof TypeError && (error.message === "Failed to fetch" || error.message === "fetch failed")) {
      throw new BlobServiceNotAvailable();
    } else {
      throw error;
    }
  }
}

// src/multipart/create.ts
function createCreateMultipartUploadMethod({ allowedOptions, getToken, extraChecks }) {
  return async (pathname, optionsInput) => {
    const options = await createPutOptions({
      pathname,
      options: optionsInput,
      extraChecks,
      getToken
    });
    const headers = createPutHeaders(allowedOptions, options);
    const createMultipartUploadResponse = await createMultipartUpload(
      pathname,
      headers,
      options
    );
    return {
      key: createMultipartUploadResponse.key,
      uploadId: createMultipartUploadResponse.uploadId
    };
  };
}
async function createMultipartUpload(pathname, headers, options) {
  debug("mpu: create", "pathname:", pathname);
  const params = new URLSearchParams({ pathname });
  try {
    const response = await requestApi(
      `/mpu?${params.toString()}`,
      {
        method: "POST",
        headers: {
          ...headers,
          "x-mpu-action": "create"
        },
        signal: options.abortSignal
      },
      options
    );
    debug("mpu: create", response);
    return response;
  } catch (error) {
    if (error instanceof TypeError && (error.message === "Failed to fetch" || error.message === "fetch failed")) {
      throw new BlobServiceNotAvailable();
    }
    throw error;
  }
}

// src/multipart/upload.ts
import throttle from "throttleit";
function createUploadPartMethod({ allowedOptions, getToken, extraChecks }) {
  return async (pathname, body, optionsInput) => {
    const options = await createPutOptions({
      pathname,
      options: optionsInput,
      extraChecks,
      getToken
    });
    const headers = createPutHeaders(allowedOptions, options);
    if (isPlainObject(body)) {
      throw new BlobError(
        "Body must be a string, buffer or stream. You sent a plain JavaScript object, double check what you're trying to upload."
      );
    }
    const result = await uploadPart({
      uploadId: options.uploadId,
      key: options.key,
      pathname,
      part: { blob: body, partNumber: options.partNumber },
      headers,
      options
    });
    return {
      etag: result.etag,
      partNumber: options.partNumber
    };
  };
}
async function uploadPart({
  uploadId,
  key,
  pathname,
  headers,
  options,
  internalAbortController = new AbortController(),
  part
}) {
  var _a3, _b2, _c;
  const params = new URLSearchParams({ pathname });
  const responsePromise = requestApi(
    `/mpu?${params.toString()}`,
    {
      signal: internalAbortController.signal,
      method: "POST",
      headers: {
        ...headers,
        "x-mpu-action": "upload",
        "x-mpu-key": encodeURIComponent(key),
        "x-mpu-upload-id": uploadId,
        "x-mpu-part-number": part.partNumber.toString()
      },
      // weird things between undici types and native fetch types
      body: part.blob
    },
    options
  );
  function handleAbort() {
    internalAbortController.abort();
  }
  if ((_a3 = options.abortSignal) == null ? void 0 : _a3.aborted) {
    handleAbort();
  } else {
    (_b2 = options.abortSignal) == null ? void 0 : _b2.addEventListener("abort", handleAbort);
  }
  const response = await responsePromise;
  (_c = options.abortSignal) == null ? void 0 : _c.removeEventListener("abort", handleAbort);
  return response;
}
var maxConcurrentUploads = typeof window !== "undefined" ? 6 : 8;
var partSizeInBytes = 8 * 1024 * 1024;
var maxBytesInMemory = maxConcurrentUploads * partSizeInBytes * 2;
function uploadAllParts({
  uploadId,
  key,
  pathname,
  stream,
  headers,
  options,
  totalToLoad
}) {
  debug("mpu: upload init", "key:", key);
  const internalAbortController = new AbortController();
  return new Promise((resolve, reject) => {
    const partsToUpload = [];
    const completedParts = [];
    const reader = stream.getReader();
    let activeUploads = 0;
    let reading = false;
    let currentPartNumber = 1;
    let rejected = false;
    let currentBytesInMemory = 0;
    let doneReading = false;
    let bytesSent = 0;
    let arrayBuffers = [];
    let currentPartBytesRead = 0;
    let onUploadProgress;
    const totalLoadedPerPartNumber = {};
    if (options.onUploadProgress) {
      onUploadProgress = throttle(() => {
        var _a3;
        const loaded = Object.values(totalLoadedPerPartNumber).reduce(
          (acc, cur) => {
            return acc + cur;
          },
          0
        );
        const total = totalToLoad || loaded;
        const percentage = totalToLoad > 0 ? Number(((loaded / totalToLoad || loaded) * 100).toFixed(2)) : 0;
        (_a3 = options.onUploadProgress) == null ? void 0 : _a3.call(options, { loaded, total, percentage });
      }, 150);
    }
    read().catch(cancel);
    async function read() {
      debug(
        "mpu: upload read start",
        "activeUploads:",
        activeUploads,
        "currentBytesInMemory:",
        `${bytes(currentBytesInMemory)}/${bytes(maxBytesInMemory)}`,
        "bytesSent:",
        bytes(bytesSent)
      );
      reading = true;
      while (currentBytesInMemory < maxBytesInMemory && !rejected) {
        try {
          const { value, done } = await reader.read();
          if (done) {
            doneReading = true;
            debug("mpu: upload read consumed the whole stream");
            if (arrayBuffers.length > 0) {
              partsToUpload.push({
                partNumber: currentPartNumber++,
                blob: new Blob(arrayBuffers, {
                  type: "application/octet-stream"
                })
              });
              sendParts();
            }
            reading = false;
            return;
          }
          currentBytesInMemory += value.byteLength;
          let valueOffset = 0;
          while (valueOffset < value.byteLength) {
            const remainingPartSize = partSizeInBytes - currentPartBytesRead;
            const endOffset = Math.min(
              valueOffset + remainingPartSize,
              value.byteLength
            );
            const chunk = value.slice(valueOffset, endOffset);
            arrayBuffers.push(chunk);
            currentPartBytesRead += chunk.byteLength;
            valueOffset = endOffset;
            if (currentPartBytesRead === partSizeInBytes) {
              partsToUpload.push({
                partNumber: currentPartNumber++,
                blob: new Blob(arrayBuffers, {
                  type: "application/octet-stream"
                })
              });
              arrayBuffers = [];
              currentPartBytesRead = 0;
              sendParts();
            }
          }
        } catch (error) {
          cancel(error);
        }
      }
      debug(
        "mpu: upload read end",
        "activeUploads:",
        activeUploads,
        "currentBytesInMemory:",
        `${bytes(currentBytesInMemory)}/${bytes(maxBytesInMemory)}`,
        "bytesSent:",
        bytes(bytesSent)
      );
      reading = false;
    }
    async function sendPart(part) {
      activeUploads++;
      debug(
        "mpu: upload send part start",
        "partNumber:",
        part.partNumber,
        "size:",
        part.blob.size,
        "activeUploads:",
        activeUploads,
        "currentBytesInMemory:",
        `${bytes(currentBytesInMemory)}/${bytes(maxBytesInMemory)}`,
        "bytesSent:",
        bytes(bytesSent)
      );
      try {
        const uploadProgressForPart = options.onUploadProgress ? (event) => {
          totalLoadedPerPartNumber[part.partNumber] = event.loaded;
          if (onUploadProgress) {
            onUploadProgress();
          }
        } : void 0;
        const completedPart = await uploadPart({
          uploadId,
          key,
          pathname,
          headers,
          options: {
            ...options,
            onUploadProgress: uploadProgressForPart
          },
          internalAbortController,
          part
        });
        debug(
          "mpu: upload send part end",
          "partNumber:",
          part.partNumber,
          "activeUploads",
          activeUploads,
          "currentBytesInMemory:",
          `${bytes(currentBytesInMemory)}/${bytes(maxBytesInMemory)}`,
          "bytesSent:",
          bytes(bytesSent)
        );
        if (rejected) {
          return;
        }
        completedParts.push({
          partNumber: part.partNumber,
          etag: completedPart.etag
        });
        currentBytesInMemory -= part.blob.size;
        activeUploads--;
        bytesSent += part.blob.size;
        if (partsToUpload.length > 0) {
          sendParts();
        }
        if (doneReading) {
          if (activeUploads === 0) {
            reader.releaseLock();
            resolve(completedParts);
          }
          return;
        }
        if (!reading) {
          read().catch(cancel);
        }
      } catch (error) {
        cancel(error);
      }
    }
    function sendParts() {
      if (rejected) {
        return;
      }
      debug(
        "send parts",
        "activeUploads",
        activeUploads,
        "partsToUpload",
        partsToUpload.length
      );
      while (activeUploads < maxConcurrentUploads && partsToUpload.length > 0) {
        const partToSend = partsToUpload.shift();
        if (partToSend) {
          void sendPart(partToSend);
        }
      }
    }
    function cancel(error) {
      if (rejected) {
        return;
      }
      rejected = true;
      internalAbortController.abort();
      reader.releaseLock();
      if (error instanceof TypeError && (error.message === "Failed to fetch" || error.message === "fetch failed")) {
        reject(new BlobServiceNotAvailable());
      } else {
        reject(error);
      }
    }
  });
}

// src/put.ts
import throttle2 from "throttleit";

// src/multipart/uncontrolled.ts
async function uncontrolledMultipartUpload(pathname, body, headers, options) {
  debug("mpu: init", "pathname:", pathname, "headers:", headers);
  const optionsWithoutOnUploadProgress = {
    ...options,
    onUploadProgress: void 0
  };
  const createMultipartUploadResponse = await createMultipartUpload(
    pathname,
    headers,
    optionsWithoutOnUploadProgress
  );
  const totalToLoad = computeBodyLength(body);
  const stream = await toReadableStream(body);
  const parts = await uploadAllParts({
    uploadId: createMultipartUploadResponse.uploadId,
    key: createMultipartUploadResponse.key,
    pathname,
    stream,
    headers,
    options,
    totalToLoad
  });
  const blob = await completeMultipartUpload({
    uploadId: createMultipartUploadResponse.uploadId,
    key: createMultipartUploadResponse.key,
    pathname,
    parts,
    headers,
    options: optionsWithoutOnUploadProgress
  });
  return blob;
}

// src/put.ts
function createPutMethod({
  allowedOptions,
  getToken,
  extraChecks
}) {
  return async function put(pathname, body, optionsInput) {
    if (!body) {
      throw new BlobError("body is required");
    }
    if (isPlainObject(body)) {
      throw new BlobError(
        "Body must be a string, buffer or stream. You sent a plain JavaScript object, double check what you're trying to upload."
      );
    }
    const options = await createPutOptions({
      pathname,
      options: optionsInput,
      extraChecks,
      getToken
    });
    const headers = createPutHeaders(allowedOptions, options);
    if (options.multipart === true) {
      return uncontrolledMultipartUpload(pathname, body, headers, options);
    }
    const onUploadProgress = options.onUploadProgress ? throttle2(options.onUploadProgress, 100) : void 0;
    const params = new URLSearchParams({ pathname });
    const response = await requestApi(
      `/?${params.toString()}`,
      {
        method: "PUT",
        body,
        headers,
        signal: options.abortSignal
      },
      {
        ...options,
        onUploadProgress
      }
    );
    return {
      url: response.url,
      downloadUrl: response.downloadUrl,
      pathname: response.pathname,
      contentType: response.contentType,
      contentDisposition: response.contentDisposition
    };
  };
}

// src/multipart/create-uploader.ts
function createCreateMultipartUploaderMethod({ allowedOptions, getToken, extraChecks }) {
  return async (pathname, optionsInput) => {
    const options = await createPutOptions({
      pathname,
      options: optionsInput,
      extraChecks,
      getToken
    });
    const headers = createPutHeaders(allowedOptions, options);
    const createMultipartUploadResponse = await createMultipartUpload(
      pathname,
      headers,
      options
    );
    return {
      key: createMultipartUploadResponse.key,
      uploadId: createMultipartUploadResponse.uploadId,
      async uploadPart(partNumber, body) {
        if (isPlainObject(body)) {
          throw new BlobError(
            "Body must be a string, buffer or stream. You sent a plain JavaScript object, double check what you're trying to upload."
          );
        }
        const result = await uploadPart({
          uploadId: createMultipartUploadResponse.uploadId,
          key: createMultipartUploadResponse.key,
          pathname,
          part: { partNumber, blob: body },
          headers,
          options
        });
        return {
          etag: result.etag,
          partNumber
        };
      },
      async complete(parts) {
        return completeMultipartUpload({
          uploadId: createMultipartUploadResponse.uploadId,
          key: createMultipartUploadResponse.key,
          pathname,
          parts,
          headers,
          options
        });
      }
    };
  };
}

// src/create-folder.ts
async function createFolder(pathname, options = {}) {
  const folderPathname = pathname.endsWith("/") ? pathname : `${pathname}/`;
  const headers = {};
  headers[putOptionHeaderMap.addRandomSuffix] = "0";
  const params = new URLSearchParams({ pathname: folderPathname });
  const response = await requestApi(
    `/?${params.toString()}`,
    {
      method: "PUT",
      headers,
      signal: options.abortSignal
    },
    options
  );
  return {
    url: response.url,
    pathname: response.pathname
  };
}

export {
  getTokenFromOptionsOrEnv,
  BlobError,
  getDownloadUrl,
  disallowedPathnameCharacters,
  MAXIMUM_PATHNAME_LENGTH,
  BlobAccessError,
  BlobContentTypeNotAllowedError,
  BlobPathnameMismatchError,
  BlobClientTokenExpiredError,
  BlobFileTooLargeError,
  BlobStoreNotFoundError,
  BlobStoreSuspendedError,
  BlobUnknownError,
  BlobNotFoundError,
  BlobServiceNotAvailable,
  BlobServiceRateLimited,
  BlobRequestAbortedError,
  requestApi,
  createCompleteMultipartUploadMethod,
  createCreateMultipartUploadMethod,
  createUploadPartMethod,
  createPutMethod,
  createCreateMultipartUploaderMethod,
  createFolder
};
/*!
 * bytes
 * Copyright(c) 2012-2014 TJ Holowaychuk
 * Copyright(c) 2015 Jed Watson
 * MIT Licensed
 */
//# sourceMappingURL=chunk-Z56QURM6.js.map