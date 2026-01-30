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
var trace_exports = {};
__export(trace_exports, {
  BUILDER_COMPILE_STEP: () => import_constants.BUILDER_COMPILE_STEP,
  BUILDER_INSTALLER_STEP: () => import_constants.BUILDER_INSTALLER_STEP,
  Span: () => import_trace.Span
});
module.exports = __toCommonJS(trace_exports);
var import_trace = require("./trace");
var import_constants = require("./constants");
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  BUILDER_COMPILE_STEP,
  BUILDER_INSTALLER_STEP,
  Span
});
