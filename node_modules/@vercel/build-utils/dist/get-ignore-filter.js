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
var get_ignore_filter_exports = {};
__export(get_ignore_filter_exports, {
  default: () => get_ignore_filter_default
});
module.exports = __toCommonJS(get_ignore_filter_exports);
var import_path = __toESM(require("path"));
var import_fs_extra = __toESM(require("fs-extra"));
var import_ignore = __toESM(require("ignore"));
function isCodedError(error) {
  return error !== null && error !== void 0 && error.code !== void 0;
}
function clearRelative(s) {
  return s.replace(/(\n|^)\.\//g, "$1");
}
async function get_ignore_filter_default(downloadPath, rootDirectory) {
  const readFile = async (p) => {
    try {
      return await import_fs_extra.default.readFile(p, "utf8");
    } catch (error) {
      if (error.code === "ENOENT" || error instanceof Error && error.message.includes("ENOENT")) {
        return void 0;
      }
      throw error;
    }
  };
  const vercelIgnorePath = import_path.default.join(
    downloadPath,
    rootDirectory || "",
    ".vercelignore"
  );
  const nowIgnorePath = import_path.default.join(
    downloadPath,
    rootDirectory || "",
    ".nowignore"
  );
  const ignoreContents = [];
  try {
    ignoreContents.push(
      ...(await Promise.all([readFile(vercelIgnorePath), readFile(nowIgnorePath)])).filter(Boolean)
    );
  } catch (error) {
    if (isCodedError(error) && error.code === "ENOTDIR") {
      console.log(`Warning: Cannot read ignore file from ${vercelIgnorePath}`);
    } else {
      throw error;
    }
  }
  if (ignoreContents.length === 2) {
    throw new Error(
      "Cannot use both a `.vercelignore` and `.nowignore` file. Please delete the `.nowignore` file."
    );
  }
  if (ignoreContents.length === 0) {
    return () => false;
  }
  const ignoreFilter = (0, import_ignore.default)().add(clearRelative(ignoreContents[0]));
  return function(p) {
    if (p === "now.json" || p === "vercel.json")
      return false;
    return ignoreFilter.test(p).ignored;
  };
}
