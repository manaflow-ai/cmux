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
var file_fs_ref_exports = {};
__export(file_fs_ref_exports, {
  default: () => file_fs_ref_default
});
module.exports = __toCommonJS(file_fs_ref_exports);
var import_assert = __toESM(require("assert"));
var import_fs_extra = __toESM(require("fs-extra"));
var import_multistream = __toESM(require("multistream"));
var import_path = __toESM(require("path"));
var import_async_sema = __toESM(require("async-sema"));
const semaToPreventEMFILE = new import_async_sema.default(20);
class FileFsRef {
  constructor({
    mode = 33188,
    contentType,
    fsPath,
    size
  }) {
    (0, import_assert.default)(typeof mode === "number");
    (0, import_assert.default)(typeof fsPath === "string");
    this.type = "FileFsRef";
    this.mode = mode;
    this.contentType = contentType;
    this.fsPath = fsPath;
    this.size = size;
  }
  static async fromFsPath({
    mode,
    contentType,
    fsPath,
    size
  }) {
    let m = mode;
    let s = size;
    if (!m || typeof s === "undefined") {
      const stat = await import_fs_extra.default.lstat(fsPath);
      m = stat.mode;
      s = stat.size;
    }
    return new FileFsRef({ mode: m, contentType, fsPath, size: s });
  }
  static async fromStream({
    mode = 33188,
    contentType,
    stream,
    fsPath
  }) {
    (0, import_assert.default)(typeof mode === "number");
    (0, import_assert.default)(typeof stream.pipe === "function");
    (0, import_assert.default)(typeof fsPath === "string");
    await import_fs_extra.default.mkdirp(import_path.default.dirname(fsPath));
    await new Promise((resolve, reject) => {
      const dest = import_fs_extra.default.createWriteStream(fsPath, {
        mode: mode & 511
      });
      stream.pipe(dest);
      stream.on("error", reject);
      dest.on("finish", resolve);
      dest.on("error", reject);
    });
    return FileFsRef.fromFsPath({ mode, contentType, fsPath });
  }
  async toStreamAsync() {
    await semaToPreventEMFILE.acquire();
    const release = () => semaToPreventEMFILE.release();
    const stream = import_fs_extra.default.createReadStream(this.fsPath);
    stream.on("close", release);
    stream.on("error", release);
    return stream;
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
var file_fs_ref_default = FileFsRef;
