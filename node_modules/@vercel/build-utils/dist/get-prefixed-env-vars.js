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
var get_prefixed_env_vars_exports = {};
__export(get_prefixed_env_vars_exports, {
  getPrefixedEnvVars: () => getPrefixedEnvVars
});
module.exports = __toCommonJS(get_prefixed_env_vars_exports);
function getPrefixedEnvVars({
  envPrefix,
  envs
}) {
  const vercelSystemEnvPrefix = "VERCEL_";
  const allowed = [
    "VERCEL_URL",
    "VERCEL_ENV",
    "VERCEL_TARGET_ENV",
    "VERCEL_REGION",
    "VERCEL_BRANCH_URL",
    "VERCEL_PROJECT_PRODUCTION_URL",
    "VERCEL_DEPLOYMENT_ID",
    "VERCEL_PROJECT_ID"
  ];
  const newEnvs = {};
  if (envPrefix && envs.VERCEL_URL) {
    Object.keys(envs).filter((key) => allowed.includes(key) || key.startsWith("VERCEL_GIT_")).forEach((key) => {
      const newKey = `${envPrefix}${key}`;
      if (!(newKey in envs)) {
        newEnvs[newKey] = envs[key];
      }
    });
    newEnvs.TURBO_CI_VENDOR_ENV_KEY = `${envPrefix}${vercelSystemEnvPrefix}`;
  }
  return newEnvs;
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  getPrefixedEnvVars
});
