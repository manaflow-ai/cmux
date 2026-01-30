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
var debug_exports = {};
__export(debug_exports, {
  default: () => debug
});
module.exports = __toCommonJS(debug_exports);
var import_get_platform_env = require("./get-platform-env");
function debug(message, ...additional) {
  if ((0, import_get_platform_env.getPlatformEnv)("BUILDER_DEBUG")) {
    console.log(message, ...additional);
  } else if (process.env.VERCEL_DEBUG_PREFIX) {
    console.log(`${process.env.VERCEL_DEBUG_PREFIX}${message}`, ...additional);
  }
}
