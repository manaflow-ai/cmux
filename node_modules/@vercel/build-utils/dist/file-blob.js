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
var file_blob_exports = {};
__export(file_blob_exports, {
  default: () => FileBlob
});
module.exports = __toCommonJS(file_blob_exports);
var import_assert = __toESM(require("assert"));
var import_into_stream = __toESM(require("into-stream"));
class FileBlob {
  constructor({ mode = 33188, contentType, data }) {
    (0, import_assert.default)(typeof mode === "number");
    (0, import_assert.default)(typeof data === "string" || Buffer.isBuffer(data));
    this.type = "FileBlob";
    this.mode = mode;
    this.contentType = contentType;
    this.data = data;
  }
  static async fromStream({
    mode = 33188,
    contentType,
    stream
  }) {
    (0, import_assert.default)(typeof mode === "number");
    (0, import_assert.default)(typeof stream.pipe === "function");
    const chunks = [];
    await new Promise((resolve, reject) => {
      stream.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
      stream.on("error", (error) => reject(error));
      stream.on("end", () => resolve());
    });
    const data = Buffer.concat(chunks);
    return new FileBlob({ mode, contentType, data });
  }
  async toStreamAsync() {
    return this.toStream();
  }
  toStream() {
    return (0, import_into_stream.default)(this.data);
  }
}
