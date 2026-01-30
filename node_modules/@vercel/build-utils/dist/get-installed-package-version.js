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
var get_installed_package_version_exports = {};
__export(get_installed_package_version_exports, {
  getInstalledPackageVersion: () => getInstalledPackageVersion
});
module.exports = __toCommonJS(get_installed_package_version_exports);
var import_debug = __toESM(require("./debug"));
async function getInstalledPackageVersion(packageName, path) {
  try {
    const resolved = require.resolve(`${packageName}/package.json`, {
      paths: path ? Array.isArray(path) ? path : [path] : [process.cwd()]
    });
    const version = require(resolved).version;
    return version;
  } catch (err) {
    (0, import_debug.default)(
      `Could not resolve package "${packageName}". Package is not installed.`,
      err
    );
    return void 0;
  }
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  getInstalledPackageVersion
});
