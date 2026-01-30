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
var stream_to_buffer_exports = {};
__export(stream_to_buffer_exports, {
  default: () => streamToBuffer,
  streamToBufferChunks: () => streamToBufferChunks
});
module.exports = __toCommonJS(stream_to_buffer_exports);
var import_end_of_stream = __toESM(require("end-of-stream"));
function streamToBuffer(stream) {
  return new Promise((resolve, reject) => {
    const buffers = [];
    stream.on("data", buffers.push.bind(buffers));
    (0, import_end_of_stream.default)(stream, (err) => {
      if (err) {
        reject(err);
        return;
      }
      switch (buffers.length) {
        case 0:
          resolve(Buffer.allocUnsafe(0));
          break;
        case 1:
          resolve(buffers[0]);
          break;
        default:
          resolve(Buffer.concat(buffers));
      }
    });
  });
}
const MB = 1024 * 1024;
async function streamToBufferChunks(stream, chunkSize = 100 * MB) {
  const chunks = [];
  let currentChunk = [];
  let currentSize = 0;
  for await (const chunk of stream) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    let offset = 0;
    while (offset < buffer.length) {
      const remainingSpace = chunkSize - currentSize;
      const sliceSize = Math.min(remainingSpace, buffer.length - offset);
      currentChunk.push(buffer.slice(offset, offset + sliceSize));
      currentSize += sliceSize;
      offset += sliceSize;
      if (currentSize >= chunkSize) {
        chunks.push(Buffer.concat(currentChunk));
        currentChunk = [];
        currentSize = 0;
      }
    }
  }
  if (currentChunk.length > 0) {
    chunks.push(Buffer.concat(currentChunk));
  }
  return chunks;
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  streamToBufferChunks
});
