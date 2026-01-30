"use strict";
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
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
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);
var os_exports = {};
__export(os_exports, {
  getOsRelease: () => getOsRelease,
  getProvidedRuntime: () => getProvidedRuntime,
  parseOsRelease: () => parseOsRelease
});
module.exports = __toCommonJS(os_exports);
var import_fs_extra = require("fs-extra");
var import_error_utils = require("@vercel/error-utils");
async function getOsRelease() {
  try {
    const data = await (0, import_fs_extra.readFile)("/etc/os-release", "utf8");
    return await parseOsRelease(data);
  } catch (err) {
    if ((0, import_error_utils.isErrnoException)(err) && err.code === "ENOENT") {
      return null;
    }
    throw err;
  }
}
async function parseOsRelease(data) {
  const obj = {};
  for (const line of data.trim().split("\n")) {
    const m = /(?<key>.*)="(?<value>.*)"/.exec(line);
    if (!m?.groups) {
      continue;
    }
    obj[m.groups.key] = m.groups.value;
  }
  return obj;
}
async function getProvidedRuntime() {
  const os = await getOsRelease();
  if (!os) {
    return "provided.al2023";
  }
  return os.PRETTY_NAME === "Amazon Linux 2" ? "provided.al2" : "provided.al2023";
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  getOsRelease,
  getProvidedRuntime,
  parseOsRelease
});
