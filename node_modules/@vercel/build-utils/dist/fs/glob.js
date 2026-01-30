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
var glob_exports = {};
__export(glob_exports, {
  default: () => glob
});
module.exports = __toCommonJS(glob_exports);
var import_path = __toESM(require("path"));
var import_assert = __toESM(require("assert"));
var import_glob = __toESM(require("glob"));
var import_util = require("util");
var import_fs_extra = require("fs-extra");
var import_normalize_path = require("./normalize-path");
var import_file_fs_ref = __toESM(require("../file-fs-ref"));
const vanillaGlob = (0, import_util.promisify)(import_glob.default);
async function glob(pattern, opts, mountpoint) {
  const options = typeof opts === "string" ? { cwd: opts } : opts;
  if (!options.cwd) {
    throw new Error(
      "Second argument (basePath) must be specified for names of resulting files"
    );
  }
  if (!import_path.default.isAbsolute(options.cwd)) {
    throw new Error(`basePath/cwd must be an absolute path (${options.cwd})`);
  }
  const results = {};
  const statCache = {};
  const symlinks = {};
  const files = await vanillaGlob(pattern, {
    ...options,
    symlinks,
    statCache,
    stat: true,
    dot: true
  });
  const dirs = /* @__PURE__ */ new Set();
  const dirsWithEntries = /* @__PURE__ */ new Set();
  for (const relativePath of files) {
    const absPath = import_path.default.join(options.cwd, relativePath);
    const fsPath = (0, import_normalize_path.normalizePath)(absPath);
    let stat = statCache[fsPath];
    (0, import_assert.default)(
      stat,
      `statCache does not contain value for ${relativePath} (resolved to ${fsPath})`
    );
    const isSymlink = symlinks[fsPath];
    if (options.follow && (isSymlink || (await (0, import_fs_extra.lstat)(fsPath)).isSymbolicLink())) {
      const target = await (0, import_fs_extra.readlink)(absPath);
      const absTarget = import_path.default.resolve(import_path.default.dirname(absPath), target);
      if (import_path.default.relative(options.cwd, absTarget).startsWith(`..${import_path.default.sep}`)) {
        continue;
      }
    }
    if (isSymlink || stat.isFile() || stat.isDirectory()) {
      if (isSymlink) {
        stat = await (0, import_fs_extra.lstat)(absPath);
      }
      const dirname = import_path.default.dirname(relativePath);
      dirsWithEntries.add(dirname);
      if (stat.isDirectory()) {
        dirs.add(relativePath);
        continue;
      }
      let finalPath = relativePath;
      if (mountpoint) {
        finalPath = import_path.default.join(mountpoint, finalPath);
      }
      results[finalPath] = new import_file_fs_ref.default({ mode: stat.mode, fsPath });
    }
  }
  if (options.includeDirectories) {
    for (const relativePath of dirs) {
      if (dirsWithEntries.has(relativePath))
        continue;
      let finalPath = relativePath;
      if (mountpoint) {
        finalPath = import_path.default.join(mountpoint, finalPath);
      }
      const fsPath = (0, import_normalize_path.normalizePath)(import_path.default.join(options.cwd, relativePath));
      const stat = statCache[fsPath];
      results[finalPath] = new import_file_fs_ref.default({ mode: stat.mode, fsPath });
    }
  }
  return results;
}
