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
var read_config_file_exports = {};
__export(read_config_file_exports, {
  getPackageJson: () => getPackageJson,
  readConfigFile: () => readConfigFile
});
module.exports = __toCommonJS(read_config_file_exports);
var import_js_yaml = __toESM(require("js-yaml"));
var import_toml = __toESM(require("@iarna/toml"));
var import_fs_extra = require("fs-extra");
var import_error_utils = require("@vercel/error-utils");
var import_path = require("path");
async function readFileOrNull(file) {
  try {
    const data = await (0, import_fs_extra.readFile)(file);
    return data;
  } catch (error) {
    if (!(0, import_error_utils.isErrnoException)(error)) {
      throw error;
    }
    if (error.code !== "ENOENT") {
      throw error;
    }
  }
  return null;
}
async function readConfigFile(files) {
  files = Array.isArray(files) ? files : [files];
  for (const name of files) {
    const data = await readFileOrNull(name);
    if (data) {
      const str = data.toString("utf8");
      try {
        if (name.endsWith(".json")) {
          return JSON.parse(str);
        } else if (name.endsWith(".toml")) {
          return import_toml.default.parse(str);
        } else if (name.endsWith(".yaml") || name.endsWith(".yml")) {
          return import_js_yaml.default.safeLoad(str, { filename: name });
        }
      } catch (error) {
        console.log(`Error while parsing config file: "${name}"`);
      }
    }
  }
  return null;
}
async function getPackageJson(dir) {
  const packagePath = (0, import_path.join)(dir, "package.json");
  try {
    return JSON.parse(await (0, import_fs_extra.readFile)(packagePath, "utf8"));
  } catch (err) {
    return {};
  }
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  getPackageJson,
  readConfigFile
});
