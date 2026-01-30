import {
  BlobAccessError,
  BlobClientTokenExpiredError,
  BlobContentTypeNotAllowedError,
  BlobError,
  BlobFileTooLargeError,
  BlobNotFoundError,
  BlobPathnameMismatchError,
  BlobRequestAbortedError,
  BlobServiceNotAvailable,
  BlobServiceRateLimited,
  BlobStoreNotFoundError,
  BlobStoreSuspendedError,
  BlobUnknownError,
  MAXIMUM_PATHNAME_LENGTH,
  createCompleteMultipartUploadMethod,
  createCreateMultipartUploadMethod,
  createCreateMultipartUploaderMethod,
  createFolder,
  createPutMethod,
  createUploadPartMethod,
  disallowedPathnameCharacters,
  getDownloadUrl,
  requestApi
} from "./chunk-Z56QURM6.js";

// src/del.ts
async function del(url, options) {
  await requestApi(
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
  const response = await requestApi(
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
  const response = await requestApi(
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
    throw new BlobError("missing options, see usage");
  }
  if (options.access !== "public") {
    throw new BlobError('access must be "public"');
  }
  if (toPathname.length > MAXIMUM_PATHNAME_LENGTH) {
    throw new BlobError(
      `pathname is too long, maximum length is ${MAXIMUM_PATHNAME_LENGTH}`
    );
  }
  for (const invalidCharacter of disallowedPathnameCharacters) {
    if (toPathname.includes(invalidCharacter)) {
      throw new BlobError(
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
  const response = await requestApi(
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
var put = createPutMethod({
  allowedOptions: [
    "cacheControlMaxAge",
    "addRandomSuffix",
    "allowOverwrite",
    "contentType"
  ]
});
var createMultipartUpload = createCreateMultipartUploadMethod({
  allowedOptions: [
    "cacheControlMaxAge",
    "addRandomSuffix",
    "allowOverwrite",
    "contentType"
  ]
});
var createMultipartUploader = createCreateMultipartUploaderMethod({
  allowedOptions: [
    "cacheControlMaxAge",
    "addRandomSuffix",
    "allowOverwrite",
    "contentType"
  ]
});
var uploadPart = createUploadPartMethod({
  allowedOptions: [
    "cacheControlMaxAge",
    "addRandomSuffix",
    "allowOverwrite",
    "contentType"
  ]
});
var completeMultipartUpload = createCompleteMultipartUploadMethod({
  allowedOptions: [
    "cacheControlMaxAge",
    "addRandomSuffix",
    "allowOverwrite",
    "contentType"
  ]
});
export {
  BlobAccessError,
  BlobClientTokenExpiredError,
  BlobContentTypeNotAllowedError,
  BlobError,
  BlobFileTooLargeError,
  BlobNotFoundError,
  BlobPathnameMismatchError,
  BlobRequestAbortedError,
  BlobServiceNotAvailable,
  BlobServiceRateLimited,
  BlobStoreNotFoundError,
  BlobStoreSuspendedError,
  BlobUnknownError,
  completeMultipartUpload,
  copy,
  createFolder,
  createMultipartUpload,
  createMultipartUploader,
  del,
  getDownloadUrl,
  head,
  list,
  put,
  uploadPart
};
//# sourceMappingURL=index.js.map