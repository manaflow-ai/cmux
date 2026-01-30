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
var nodejs_lambda_exports = {};
__export(nodejs_lambda_exports, {
  NodejsLambda: () => NodejsLambda
});
module.exports = __toCommonJS(nodejs_lambda_exports);
var import_lambda = require("./lambda");
class NodejsLambda extends import_lambda.Lambda {
  constructor({
    shouldAddHelpers,
    shouldAddSourcemapSupport,
    awsLambdaHandler,
    useWebApi,
    ...opts
  }) {
    super(opts);
    this.launcherType = "Nodejs";
    this.shouldAddHelpers = shouldAddHelpers;
    this.shouldAddSourcemapSupport = shouldAddSourcemapSupport;
    this.awsLambdaHandler = awsLambdaHandler;
    this.useWebApi = useWebApi;
  }
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  NodejsLambda
});
