"use strict";Object.defineProperty(exports, "__esModule", {value: true});























var _chunkKLNTTDLTcjs = require('./chunk-KLNTTDLT.cjs');

// src/del.ts
async function del(url, options) {
  await _chunkKLNTTDLTcjs.requestApi.call(void 0, 
    "/delete",
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ urls: Array.isArray(url) ? url : [url] }),
      signal: options == null ? void 0 : options.abortSignal
    },
    options
  );
}

// src/head.ts
async function head(url, options) {
  const searchParams = new URLSearchParams({ url });
  const response = await _chunkKLNTTDLTcjs.requestApi.call(void 0, 
    `?${searchParams.toString()}`,
    // HEAD can't have body as a response, so we use GET
    {
      method: "GET",
      signal: options == null ? void 0 : options.abortSignal
    },
    options
  );
  return {
    url: response.url,
    downloadUrl: response.downloadUrl,
    pathname: response.pathname,
    size: response.size,
    contentType: response.contentType,
    contentDisposition: response.contentDisposition,
    cacheControl: response.cacheControl,
    uploadedAt: new Date(response.uploadedAt)
  };
}

// src/list.ts
async function list(options) {
  var _a;
  const searchParams = new URLSearchParams();
  if (options == null ? void 0 : options.limit) {
    searchParams.set("limit", options.limit.toString());
  }
  if (options == null ? void 0 : options.prefix) {
    searchParams.set("prefix", options.prefix);
  }
  if (options == null ? void 0 : options.cursor) {
    searchParams.set("cursor", options.cursor);
  }
  if (options == null ? void 0 : options.mode) {
    searchParams.set("mode", options.mode);
  }
  const response = await _chunkKLNTTDLTcjs.requestApi.call(void 0, 
    `?${searchParams.toString()}`,
    {
      method: "GET",
      signal: options == null ? void 0 : options.abortSignal
    },
    options
  );
  if ((options == null ? void 0 : options.mode) === "folded") {
    return {
      folders: (_a = response.folders) != null ? _a : [],
      cursor: response.cursor,
      hasMore: response.hasMore,
      blobs: response.blobs.map(mapBlobResult)
    };
  }
  return {
    cursor: response.cursor,
    hasMore: response.hasMore,
    blobs: response.blobs.map(mapBlobResult)
  };
}
function mapBlobResult(blobResult) {
  return {
    url: blobResult.url,
    downloadUrl: blobResult.downloadUrl,
    pathname: blobResult.pathname,
    size: blobResult.size,
    uploadedAt: new Date(blobResult.uploadedAt)
  };
}

// src/copy.ts
async function copy(fromUrl, toPathname, options) {
  if (!options) {
    throw new (0, _chunkKLNTTDLTcjs.BlobError)("missing options, see usage");
  }
  if (options.access !== "public") {
    throw new (0, _chunkKLNTTDLTcjs.BlobError)('access must be "public"');
  }
  if (toPathname.length > _chunkKLNTTDLTcjs.MAXIMUM_PATHNAME_LENGTH) {
    throw new (0, _chunkKLNTTDLTcjs.BlobError)(
      `pathname is too long, maximum length is ${_chunkKLNTTDLTcjs.MAXIMUM_PATHNAME_LENGTH}`
    );
  }
  for (const invalidCharacter of _chunkKLNTTDLTcjs.disallowedPathnameCharacters) {
    if (toPathname.includes(invalidCharacter)) {
      throw new (0, _chunkKLNTTDLTcjs.BlobError)(
        `pathname cannot contain "${invalidCharacter}", please encode it if needed`
      );
    }
  }
  const headers = {};
  if (options.addRandomSuffix !== void 0) {
    headers["x-add-random-suffix"] = options.addRandomSuffix ? "1" : "0";
  }
  if (options.allowOverwrite !== void 0) {
    headers["x-allow-overwrite"] = options.allowOverwrite ? "1" : "0";
  }
  if (options.contentType) {
    headers["x-content-type"] = options.contentType;
  }
  if (options.cacheControlMaxAge !== void 0) {
    headers["x-cache-control-max-age"] = options.cacheControlMaxAge.toString();
  }
  const params = new URLSearchParams({ pathname: toPathname, fromUrl });
  const response = await _chunkKLNTTDLTcjs.requestApi.call(void 0, 
    `?${params.toString()}`,
    {
      method: "PUT",
      headers,
      signal: options.abortSignal
    },
    options
  );
  return {
    url: response.url,
    downloadUrl: response.downloadUrl,
    pathname: response.pathname,
    contentType: response.contentType,
    contentDisposition: response.contentDisposition
  };
}

// src/index.ts
var put = _chunkKLNTTDLTcjs.createPutMethod.call(void 0, {
  allowedOptions: [
    "cacheControlMaxAge",
    "addRandomSuffix",
    "allowOverwrite",
    "contentType"
  ]
});
var createMultipartUpload = _chunkKLNTTDLTcjs.createCreateMultipartUploadMethod.call(void 0, {
  allowedOptions: [
    "cacheControlMaxAge",
    "addRandomSuffix",
    "allowOverwrite",
    "contentType"
  ]
});
var createMultipartUploader = _chunkKLNTTDLTcjs.createCreateMultipartUploaderMethod.call(void 0, {
  allowedOptions: [
    "cacheControlMaxAge",
    "addRandomSuffix",
    "allowOverwrite",
    "contentType"
  ]
});
var uploadPart = _chunkKLNTTDLTcjs.createUploadPartMethod.call(void 0, {
  allowedOptions: [
    "cacheControlMaxAge",
    "addRandomSuffix",
    "allowOverwrite",
    "contentType"
  ]
});
var completeMultipartUpload = _chunkKLNTTDLTcjs.createCompleteMultipartUploadMethod.call(void 0, {
  allowedOptions: [
    "cacheControlMaxAge",
    "addRandomSuffix",
    "allowOverwrite",
    "contentType"
  ]
});

























exports.BlobAccessError = _chunkKLNTTDLTcjs.BlobAccessError; exports.BlobClientTokenExpiredError = _chunkKLNTTDLTcjs.BlobClientTokenExpiredError; exports.BlobContentTypeNotAllowedError = _chunkKLNTTDLTcjs.BlobContentTypeNotAllowedError; exports.BlobError = _chunkKLNTTDLTcjs.BlobError; exports.BlobFileTooLargeError = _chunkKLNTTDLTcjs.BlobFileTooLargeError; exports.BlobNotFoundError = _chunkKLNTTDLTcjs.BlobNotFoundError; exports.BlobPathnameMismatchError = _chunkKLNTTDLTcjs.BlobPathnameMismatchError; exports.BlobRequestAbortedError = _chunkKLNTTDLTcjs.BlobRequestAbortedError; exports.BlobServiceNotAvailable = _chunkKLNTTDLTcjs.BlobServiceNotAvailable; exports.BlobServiceRateLimited = _chunkKLNTTDLTcjs.BlobServiceRateLimited; exports.BlobStoreNotFoundError = _chunkKLNTTDLTcjs.BlobStoreNotFoundError; exports.BlobStoreSuspendedError = _chunkKLNTTDLTcjs.BlobStoreSuspendedError; exports.BlobUnknownError = _chunkKLNTTDLTcjs.BlobUnknownError; exports.completeMultipartUpload = completeMultipartUpload; exports.copy = copy; exports.createFolder = _chunkKLNTTDLTcjs.createFolder; exports.createMultipartUpload = createMultipartUpload; exports.createMultipartUploader = createMultipartUploader; exports.del = del; exports.getDownloadUrl = _chunkKLNTTDLTcjs.getDownloadUrl; exports.head = head; exports.list = list; exports.put = put; exports.uploadPart = uploadPart;
//# sourceMappingURL=index.cjs.map