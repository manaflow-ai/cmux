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
var hard_link_dir_exports = {};
__export(hard_link_dir_exports, {
  hardLinkDir: () => hardLinkDir
});
module.exports = __toCommonJS(hard_link_dir_exports);
var import_path = __toESM(require("path"));
var import_fs = require("fs");
async function hardLinkDir(src, destDirs) {
  if (destDirs.length === 0)
    return;
  destDirs = destDirs.filter((destDir) => import_path.default.relative(destDir, src) !== "");
  const files = await import_fs.promises.readdir(src);
  await Promise.all(
    files.map(async (file) => {
      if (file === "node_modules")
        return;
      const srcFile = import_path.default.join(src, file);
      if ((await import_fs.promises.lstat(srcFile)).isDirectory()) {
        const destSubdirs = await Promise.all(
          destDirs.map(async (destDir) => {
            const destSubdir = import_path.default.join(destDir, file);
            try {
              await import_fs.promises.mkdir(destSubdir, { recursive: true });
            } catch (err) {
              if (err.code !== "EEXIST")
                throw err;
            }
            return destSubdir;
          })
        );
        await hardLinkDir(srcFile, destSubdirs);
        return;
      }
      await Promise.all(
        destDirs.map(async (destDir) => {
          const destFile = import_path.default.join(destDir, file);
          try {
            await linkOrCopyFile(srcFile, destFile);
          } catch (err) {
            if (err.code === "ENOENT") {
              return;
            }
            throw err;
          }
        })
      );
    })
  );
}
async function linkOrCopyFile(srcFile, destFile) {
  try {
    await linkOrCopy(srcFile, destFile);
  } catch (err) {
    if (err.code === "ENOENT") {
      await import_fs.promises.mkdir(import_path.default.dirname(destFile), { recursive: true });
      await linkOrCopy(srcFile, destFile);
      return;
    }
    if (err.code !== "EEXIST") {
      throw err;
    }
  }
}
async function linkOrCopy(srcFile, destFile) {
  try {
    await import_fs.promises.link(srcFile, destFile);
  } catch (err) {
    if (err.code !== "EXDEV")
      throw err;
    await import_fs.promises.copyFile(srcFile, destFile);
  }
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  hardLinkDir
});
