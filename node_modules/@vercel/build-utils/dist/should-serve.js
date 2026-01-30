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
var should_serve_exports = {};
__export(should_serve_exports, {
  shouldServe: () => shouldServe
});
module.exports = __toCommonJS(should_serve_exports);
var import_path = require("path");
const shouldServe = ({
  entrypoint,
  files,
  requestPath
}) => {
  requestPath = requestPath.replace(/\/$/, "");
  entrypoint = entrypoint.replace(/\\/, "/");
  if (entrypoint === requestPath && hasProp(files, entrypoint)) {
    return true;
  }
  const { dir, name } = (0, import_path.parse)(entrypoint);
  if (name === "index" && dir === requestPath && hasProp(files, entrypoint)) {
    return true;
  }
  return false;
};
function hasProp(obj, key) {
  return Object.hasOwnProperty.call(obj, key);
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  shouldServe
});
