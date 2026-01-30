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
var edge_function_exports = {};
__export(edge_function_exports, {
  EdgeFunction: () => EdgeFunction
});
module.exports = __toCommonJS(edge_function_exports);
class EdgeFunction {
  constructor(params) {
    this.type = "EdgeFunction";
    this.name = params.name;
    this.deploymentTarget = params.deploymentTarget;
    this.entrypoint = params.entrypoint;
    this.files = params.files;
    this.assets = params.assets;
    this.regions = params.regions;
    this.framework = params.framework;
    this.environment = params.environment;
  }
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  EdgeFunction
});
