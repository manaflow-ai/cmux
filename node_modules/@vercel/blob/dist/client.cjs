"use strict";Object.defineProperty(exports, "__esModule", {value: true}); function _interopRequireWildcard(obj) { if (obj && obj.__esModule) { return obj; } else { var newObj = {}; if (obj != null) { for (var key in obj) { if (Object.prototype.hasOwnProperty.call(obj, key)) { newObj[key] = obj[key]; } } } newObj.default = obj; return newObj; } }








var _chunkKLNTTDLTcjs = require('./chunk-KLNTTDLT.cjs');

// src/client.ts
var _crypto = require('crypto'); var crypto = _interopRequireWildcard(_crypto);
var _undici = require('undici');
function createPutExtraChecks(methodName) {
  return function extraChecks(options) {
    if (!options.token.startsWith("vercel_blob_client_")) {
      throw new (0, _chunkKLNTTDLTcjs.BlobError)(`${methodName} must be called with a client token`);
    }
    if (
      // @ts-expect-error -- Runtime check for DX.
      options.addRandomSuffix !== void 0 || // @ts-expect-error -- Runtime check for DX.
      options.allowOverwrite !== void 0 || // @ts-expect-error -- Runtime check for DX.
      options.cacheControlMaxAge !== void 0
    ) {
      throw new (0, _chunkKLNTTDLTcjs.BlobError)(
        `${methodName} doesn't allow \`addRandomSuffix\`, \`cacheControlMaxAge\` or \`allowOverwrite\`. Configure these options at the server side when generating client tokens.`
      );
    }
  };
}
var put = _chunkKLNTTDLTcjs.createPutMethod.call(void 0, {
  allowedOptions: ["contentType"],
  extraChecks: createPutExtraChecks("client/`put`")
});
var createMultipartUpload = _chunkKLNTTDLTcjs.createCreateMultipartUploadMethod.call(void 0, {
  allowedOptions: ["contentType"],
  extraChecks: createPutExtraChecks("client/`createMultipartUpload`")
});
var createMultipartUploader = _chunkKLNTTDLTcjs.createCreateMultipartUploaderMethod.call(void 0, 
  {
    allowedOptions: ["contentType"],
    extraChecks: createPutExtraChecks("client/`createMultipartUpload`")
  }
);
var uploadPart = _chunkKLNTTDLTcjs.createUploadPartMethod.call(void 0, {
  allowedOptions: ["contentType"],
  extraChecks: createPutExtraChecks("client/`multipartUpload`")
});
var completeMultipartUpload = _chunkKLNTTDLTcjs.createCompleteMultipartUploadMethod.call(void 0, 
  {
    allowedOptions: ["contentType"],
    extraChecks: createPutExtraChecks("client/`completeMultipartUpload`")
  }
);
var upload = _chunkKLNTTDLTcjs.createPutMethod.call(void 0, {
  allowedOptions: ["contentType"],
  extraChecks(options) {
    if (options.handleUploadUrl === void 0) {
      throw new (0, _chunkKLNTTDLTcjs.BlobError)(
        "client/`upload` requires the 'handleUploadUrl' parameter"
      );
    }
    if (
      // @ts-expect-error -- Runtime check for DX.
      options.addRandomSuffix !== void 0 || // @ts-expect-error -- Runtime check for DX.
      options.createPutExtraChecks !== void 0 || // @ts-expect-error -- Runtime check for DX.
      options.cacheControlMaxAge !== void 0
    ) {
      throw new (0, _chunkKLNTTDLTcjs.BlobError)(
        "client/`upload` doesn't allow `addRandomSuffix`, `cacheControlMaxAge` or `allowOverwrite`. Configure these options at the server side when generating client tokens."
      );
    }
  },
  async getToken(pathname, options) {
    var _a, _b;
    return retrieveClientToken({
      handleUploadUrl: options.handleUploadUrl,
      pathname,
      clientPayload: (_a = options.clientPayload) != null ? _a : null,
      multipart: (_b = options.multipart) != null ? _b : false
    });
  }
});
async function importKey(token) {
  return globalThis.crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(token),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"]
  );
}
async function signPayload(payload, token) {
  if (!globalThis.crypto) {
    return crypto.createHmac("sha256", token).update(payload).digest("hex");
  }
  const signature = await globalThis.crypto.subtle.sign(
    "HMAC",
    await importKey(token),
    new TextEncoder().encode(payload)
  );
  return Buffer.from(new Uint8Array(signature)).toString("hex");
}
async function verifyCallbackSignature({
  token,
  signature,
  body
}) {
  const secret = token;
  if (!globalThis.crypto) {
    const digest = crypto.createHmac("sha256", secret).update(body).digest("hex");
    const digestBuffer = Buffer.from(digest);
    const signatureBuffer = Buffer.from(signature);
    return digestBuffer.length === signatureBuffer.length && crypto.timingSafeEqual(digestBuffer, signatureBuffer);
  }
  const verified = await globalThis.crypto.subtle.verify(
    "HMAC",
    await importKey(token),
    hexToArrayByte(signature),
    new TextEncoder().encode(body)
  );
  return verified;
}
function hexToArrayByte(input) {
  if (input.length % 2 !== 0) {
    throw new RangeError("Expected string to be an even number of characters");
  }
  const view = new Uint8Array(input.length / 2);
  for (let i = 0; i < input.length; i += 2) {
    view[i / 2] = parseInt(input.substring(i, i + 2), 16);
  }
  return Buffer.from(view);
}
function getPayloadFromClientToken(clientToken) {
  const [, , , , encodedToken] = clientToken.split("_");
  const encodedPayload = Buffer.from(encodedToken != null ? encodedToken : "", "base64").toString().split(".")[1];
  const decodedPayload = Buffer.from(encodedPayload != null ? encodedPayload : "", "base64").toString();
  return JSON.parse(decodedPayload);
}
var EventTypes = {
  generateClientToken: "blob.generate-client-token",
  uploadCompleted: "blob.upload-completed"
};
async function handleUpload({
  token,
  request,
  body,
  onBeforeGenerateToken,
  onUploadCompleted
}) {
  var _a, _b, _c, _d;
  const resolvedToken = _chunkKLNTTDLTcjs.getTokenFromOptionsOrEnv.call(void 0, { token });
  const type = body.type;
  switch (type) {
    case "blob.generate-client-token": {
      const { pathname, callbackUrl, clientPayload, multipart } = body.payload;
      const payload = await onBeforeGenerateToken(
        pathname,
        clientPayload,
        multipart
      );
      const tokenPayload = (_a = payload.tokenPayload) != null ? _a : clientPayload;
      const oneHourInSeconds = 60 * 60;
      const now = /* @__PURE__ */ new Date();
      const validUntil = (_b = payload.validUntil) != null ? _b : now.setSeconds(now.getSeconds() + oneHourInSeconds);
      return {
        type,
        clientToken: await generateClientTokenFromReadWriteToken({
          ...payload,
          token: resolvedToken,
          pathname,
          onUploadCompleted: {
            callbackUrl,
            tokenPayload
          },
          validUntil
        })
      };
    }
    case "blob.upload-completed": {
      const signatureHeader = "x-vercel-signature";
      const signature = "credentials" in request ? (_c = request.headers.get(signatureHeader)) != null ? _c : "" : (_d = request.headers[signatureHeader]) != null ? _d : "";
      if (!signature) {
        throw new (0, _chunkKLNTTDLTcjs.BlobError)("Missing callback signature");
      }
      const isVerified = await verifyCallbackSignature({
        token: resolvedToken,
        signature,
        body: JSON.stringify(body)
      });
      if (!isVerified) {
        throw new (0, _chunkKLNTTDLTcjs.BlobError)("Invalid callback signature");
      }
      await onUploadCompleted(body.payload);
      return { type, response: "ok" };
    }
    default:
      throw new (0, _chunkKLNTTDLTcjs.BlobError)("Invalid event type");
  }
}
async function retrieveClientToken(options) {
  const { handleUploadUrl, pathname } = options;
  const url = isAbsoluteUrl(handleUploadUrl) ? handleUploadUrl : toAbsoluteUrl(handleUploadUrl);
  const event = {
    type: EventTypes.generateClientToken,
    payload: {
      pathname,
      callbackUrl: url,
      clientPayload: options.clientPayload,
      multipart: options.multipart
    }
  };
  const res = await _undici.fetch.call(void 0, url, {
    method: "POST",
    body: JSON.stringify(event),
    headers: {
      "content-type": "application/json"
    },
    signal: options.abortSignal
  });
  if (!res.ok) {
    throw new (0, _chunkKLNTTDLTcjs.BlobError)("Failed to  retrieve the client token");
  }
  try {
    const { clientToken } = await res.json();
    return clientToken;
  } catch (e) {
    throw new (0, _chunkKLNTTDLTcjs.BlobError)("Failed to retrieve the client token");
  }
}
function toAbsoluteUrl(url) {
  return new URL(url, location.href).href;
}
function isAbsoluteUrl(url) {
  try {
    return Boolean(new URL(url));
  } catch (e) {
    return false;
  }
}
async function generateClientTokenFromReadWriteToken({
  token,
  ...argsWithoutToken
}) {
  var _a;
  if (typeof window !== "undefined") {
    throw new (0, _chunkKLNTTDLTcjs.BlobError)(
      '"generateClientTokenFromReadWriteToken" must be called from a server environment'
    );
  }
  const timestamp = /* @__PURE__ */ new Date();
  timestamp.setSeconds(timestamp.getSeconds() + 30);
  const readWriteToken = _chunkKLNTTDLTcjs.getTokenFromOptionsOrEnv.call(void 0, { token });
  const [, , , storeId = null] = readWriteToken.split("_");
  if (!storeId) {
    throw new (0, _chunkKLNTTDLTcjs.BlobError)(
      token ? "Invalid `token` parameter" : "Invalid `BLOB_READ_WRITE_TOKEN`"
    );
  }
  const payload = Buffer.from(
    JSON.stringify({
      ...argsWithoutToken,
      validUntil: (_a = argsWithoutToken.validUntil) != null ? _a : timestamp.getTime()
    })
  ).toString("base64");
  const securedKey = await signPayload(payload, readWriteToken);
  if (!securedKey) {
    throw new (0, _chunkKLNTTDLTcjs.BlobError)("Unable to sign client token");
  }
  return `vercel_blob_client_${storeId}_${Buffer.from(
    `${securedKey}.${payload}`
  ).toString("base64")}`;
}











exports.completeMultipartUpload = completeMultipartUpload; exports.createFolder = _chunkKLNTTDLTcjs.createFolder; exports.createMultipartUpload = createMultipartUpload; exports.createMultipartUploader = createMultipartUploader; exports.generateClientTokenFromReadWriteToken = generateClientTokenFromReadWriteToken; exports.getPayloadFromClientToken = getPayloadFromClientToken; exports.handleUpload = handleUpload; exports.put = put; exports.upload = upload; exports.uploadPart = uploadPart;
//# sourceMappingURL=client.cjs.map