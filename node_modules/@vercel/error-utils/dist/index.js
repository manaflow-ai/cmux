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
var src_exports = {};
__export(src_exports, {
  errorToString: () => errorToString,
  isErrnoException: () => isErrnoException,
  isError: () => isError,
  isErrorLike: () => isErrorLike,
  isObject: () => isObject,
  isSpawnError: () => isSpawnError,
  normalizeError: () => normalizeError
});
module.exports = __toCommonJS(src_exports);
var import_node_util = __toESM(require("node:util"));
const isObject = (obj) => typeof obj === "object" && obj !== null;
const isError = (error) => {
  return import_node_util.default.types.isNativeError(error);
};
const isErrnoException = (error) => {
  return isError(error) && "code" in error;
};
const isErrorLike = (error) => isObject(error) && "message" in error;
const errorToString = (error, fallback) => {
  if (isError(error) || isErrorLike(error))
    return error.message;
  if (typeof error === "string")
    return error;
  return fallback ?? "An unknown error has ocurred.";
};
const normalizeError = (error) => {
  if (isError(error))
    return error;
  const errorMessage = errorToString(error);
  return isErrorLike(error) ? Object.assign(new Error(errorMessage), error) : new Error(errorMessage);
};
function isSpawnError(v) {
  return isErrnoException(v) && "spawnargs" in v;
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  errorToString,
  isErrnoException,
  isError,
  isErrorLike,
  isObject,
  isSpawnError,
  normalizeError
});
//# sourceMappingURL=index.js.map
