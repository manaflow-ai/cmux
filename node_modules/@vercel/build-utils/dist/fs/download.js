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
var download_exports = {};
__export(download_exports, {
  default: () => download,
  downloadFile: () => downloadFile,
  isDirectory: () => isDirectory,
  isSymbolicLink: () => isSymbolicLink
});
module.exports = __toCommonJS(download_exports);
var import_path = __toESM(require("path"));
var import_debug = __toESM(require("../debug"));
var import_file_fs_ref = __toESM(require("../file-fs-ref"));
var import_fs_extra = require("fs-extra");
var import_stream_to_buffer = __toESM(require("./stream-to-buffer"));
const S_IFDIR = 16384;
const S_IFLNK = 40960;
const S_IFMT = 61440;
function isDirectory(mode) {
  return (mode & S_IFMT) === S_IFDIR;
}
function isSymbolicLink(mode) {
  return (mode & S_IFMT) === S_IFLNK;
}
async function prepareSymlinkTarget(file, fsPath) {
  const mkdirPromise = (0, import_fs_extra.mkdirp)(import_path.default.dirname(fsPath));
  if (file.type === "FileFsRef") {
    const [target] = await Promise.all([(0, import_fs_extra.readlink)(file.fsPath), mkdirPromise]);
    return target;
  }
  if (file.type === "FileRef" || file.type === "FileBlob") {
    const targetPathBufferPromise = (0, import_stream_to_buffer.default)(await file.toStreamAsync());
    const [targetPathBuffer] = await Promise.all([
      targetPathBufferPromise,
      mkdirPromise
    ]);
    return targetPathBuffer.toString("utf8");
  }
  throw new Error(
    `file.type "${file.type}" not supported for symlink`
  );
}
async function downloadFile(file, fsPath) {
  const { mode } = file;
  if (isDirectory(mode)) {
    await (0, import_fs_extra.mkdirp)(fsPath);
    await (0, import_fs_extra.chmod)(fsPath, mode);
    return import_file_fs_ref.default.fromFsPath({ mode, fsPath });
  }
  if (isSymbolicLink(mode)) {
    const target = await prepareSymlinkTarget(file, fsPath);
    await (0, import_fs_extra.symlink)(target, fsPath);
    return import_file_fs_ref.default.fromFsPath({ mode, fsPath });
  }
  const stream = file.toStream();
  return import_file_fs_ref.default.fromStream({ mode, stream, fsPath });
}
async function removeFile(basePath, fileMatched) {
  const file = import_path.default.join(basePath, fileMatched);
  await (0, import_fs_extra.remove)(file);
}
async function download(files, basePath, meta) {
  const {
    isDev = false,
    skipDownload = false,
    filesChanged = null,
    filesRemoved = null
  } = meta || {};
  if (isDev || skipDownload) {
    return files;
  }
  (0, import_debug.default)("Downloading deployment source files...");
  const start = Date.now();
  const files2 = {};
  const filenames = Object.keys(files);
  await Promise.all(
    filenames.map(async (name) => {
      if (Array.isArray(filesRemoved) && filesRemoved.includes(name)) {
        await removeFile(basePath, name);
        return;
      }
      if (Array.isArray(filesChanged) && !filesChanged.includes(name)) {
        return;
      }
      const parts = name.split("/");
      for (let i = 1; i < parts.length; i++) {
        const dir = parts.slice(0, i).join("/");
        const parent = files[dir];
        if (parent && isSymbolicLink(parent.mode)) {
          console.warn(
            `Warning: file "${name}" is within a symlinked directory "${dir}" and will be ignored`
          );
          return;
        }
      }
      const file = files[name];
      const fsPath = import_path.default.join(basePath, name);
      files2[name] = await downloadFile(file, fsPath);
    })
  );
  const duration = Date.now() - start;
  (0, import_debug.default)(`Downloaded ${filenames.length} source files: ${duration}ms`);
  return files2;
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  downloadFile,
  isDirectory,
  isSymbolicLink
});
