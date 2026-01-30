"use strict";
var __create = Object.create;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getProtoOf = Object.getPrototypeOf;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
  // If the importer is in node compatibility mode or this is not an ESM
  // file that has been converted to a CommonJS file using a Babel-
  // compatible transform (i.e. "__esModule" has not been set), then set
  // "default" to the CommonJS "module.exports" for node compatibility.
  isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
  mod
));
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);
var file_ref_exports = {};
__export(file_ref_exports, {
  default: () => FileRef
});
module.exports = __toCommonJS(file_ref_exports);
var import_assert = __toESM(require("assert"));
var import_node_fetch = __toESM(require("node-fetch"));
var import_multistream = __toESM(require("multistream"));
var import_async_retry = __toESM(require("async-retry"));
var import_async_sema = __toESM(require("async-sema"));
const semaToDownloadFromS3 = new import_async_sema.default(5);
class BailableError extends Error {
  constructor(...args) {
    super(...args);
    this.bail = false;
  }
}
class FileRef {
  constructor({
    mode = 33188,
    digest,
    contentType,
    mutable = false
  }) {
    (0, import_assert.default)(typeof mode === "number");
    (0, import_assert.default)(typeof digest === "string");
    this.type = "FileRef";
    this.mode = mode;
    this.digest = digest;
    this.contentType = contentType;
    this.mutable = mutable;
  }
  /**
   * Retrieves the URL of the CloudFront distribution for the S3
   * bucket represented by {@link getNowFilesS3Url}.
   *
   * @returns The URL of the CloudFront distribution
   */
  getNowFilesCloudfrontUrl() {
    return getEnvAsUrlOrThrow("NOW_FILES_CLOUDFRONT_URL") || "https://dmmcy0pwk6bqi.cloudfront.net";
  }
  /**
   * Retrieves the URL of the S3 bucket for storing ephemeral files.
   *
   * @returns The URL of the S3 bucket
   */
  getNowEphemeralFilesS3Url() {
    return getEnvAsUrlOrThrow("NOW_EPHEMERAL_FILES_S3_URL") || "https://now-ephemeral-files.s3.amazonaws.com";
  }
  /**
   * Retrieves the URL of the S3 bucket for storing files.
   *
   * @returns The URL of the S3 bucket
   */
  getNowFilesS3Url() {
    return getEnvAsUrlOrThrow("NOW_FILES_S3_URL") || "https://now-files.s3.amazonaws.com";
  }
  async toStreamAsync() {
    let url = "";
    const [digestType, digestHash] = this.digest.split(":");
    if (digestType === "sha") {
      url = this.mutable ? `${this.getNowFilesS3Url()}/${digestHash}` : `${this.getNowFilesCloudfrontUrl()}/${digestHash}`;
    } else if (digestType === "sha+ephemeral") {
      url = `${this.getNowEphemeralFilesS3Url()}/${digestHash}`;
    } else {
      throw new Error("Expected digest to be sha");
    }
    await semaToDownloadFromS3.acquire();
    try {
      return await (0, import_async_retry.default)(
        async () => {
          const resp = await (0, import_node_fetch.default)(url);
          if (!resp.ok) {
            const error = new BailableError(
              `download: ${resp.status} ${resp.statusText} for ${url}`
            );
            if (resp.status === 403)
              error.bail = true;
            throw error;
          }
          return resp.body;
        },
        { factor: 1, retries: 3 }
      );
    } finally {
      semaToDownloadFromS3.release();
    }
  }
  toStream() {
    let flag = false;
    return (0, import_multistream.default)((cb) => {
      if (flag)
        return cb(null, null);
      flag = true;
      this.toStreamAsync().then((stream) => {
        cb(null, stream);
      }).catch((error) => {
        cb(error, null);
      });
    });
  }
}
function getEnvAsUrlOrThrow(key) {
  const value = process.env[key];
  if (value === void 0)
    return void 0;
  try {
    new URL(value);
    return value;
  } catch (e) {
    if (e instanceof TypeError && "code" in e && e.code === "ERR_INVALID_URL") {
      throw new Error(
        `A non-URL value was supplied to the ${key} environment variable`
      );
    } else {
      throw e;
    }
  }
}
