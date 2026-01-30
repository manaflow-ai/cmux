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
var clone_env_exports = {};
__export(clone_env_exports, {
  cloneEnv: () => cloneEnv
});
module.exports = __toCommonJS(clone_env_exports);
const { hasOwnProperty } = Object.prototype;
function cloneEnv(...envs) {
  return envs.reduce((obj, env) => {
    if (env === void 0 || env === null) {
      return obj;
    }
    obj = Object.assign(obj, env);
    if (hasOwnProperty.call(env, "Path")) {
      if (obj.Path !== void 0) {
        obj.PATH = obj.Path;
      }
      delete obj.Path;
    }
    return obj;
  }, {});
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  cloneEnv
});
