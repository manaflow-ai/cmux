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
var get_platform_env_exports = {};
__export(get_platform_env_exports, {
  getPlatformEnv: () => getPlatformEnv
});
module.exports = __toCommonJS(get_platform_env_exports);
var import_errors = require("./errors");
const getPlatformEnv = (name) => {
  const vName = `VERCEL_${name}`;
  const nName = `NOW_${name}`;
  const v = process.env[vName];
  const n = process.env[nName];
  if (typeof v === "string") {
    if (typeof n === "string") {
      throw new import_errors.NowBuildError({
        code: "CONFLICTING_ENV_VAR_NAMES",
        message: `Both "${vName}" and "${nName}" env vars are defined. Please only define the "${vName}" env var.`,
        link: "https://vercel.link/combining-old-and-new-config"
      });
    }
    return v;
  }
  return n;
};
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  getPlatformEnv
});
