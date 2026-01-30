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
var prerender_exports = {};
__export(prerender_exports, {
  Prerender: () => Prerender
});
module.exports = __toCommonJS(prerender_exports);
class Prerender {
  constructor({
    expiration,
    staleExpiration,
    lambda,
    fallback,
    group,
    bypassToken,
    allowQuery,
    allowHeader,
    initialHeaders,
    initialStatus,
    passQuery,
    sourcePath,
    experimentalBypassFor,
    experimentalStreamingLambdaPath,
    chain
  }) {
    this.type = "Prerender";
    this.expiration = expiration;
    this.staleExpiration = staleExpiration;
    this.sourcePath = sourcePath;
    this.lambda = lambda;
    if (this.lambda) {
      this.lambda.operationType = this.lambda.operationType || "ISR";
    }
    if (typeof group !== "undefined" && (group <= 0 || !Number.isInteger(group))) {
      throw new Error(
        "The `group` argument for `Prerender` needs to be a natural number."
      );
    }
    this.group = group;
    if (passQuery === true) {
      this.passQuery = true;
    } else if (typeof passQuery !== "boolean" && typeof passQuery !== "undefined") {
      throw new Error(
        `The \`passQuery\` argument for \`Prerender\` must be a boolean.`
      );
    }
    if (bypassToken == null) {
      this.bypassToken = null;
    } else if (typeof bypassToken === "string") {
      if (bypassToken.length < 32) {
        throw new Error(
          "The `bypassToken` argument for `Prerender` must be 32 characters or more."
        );
      }
      this.bypassToken = bypassToken;
    } else {
      throw new Error(
        "The `bypassToken` argument for `Prerender` must be a `string`."
      );
    }
    if (experimentalBypassFor !== void 0) {
      if (!Array.isArray(experimentalBypassFor) || experimentalBypassFor.some(
        (field) => typeof field !== "object" || typeof field.type !== "string" || field.type === "host" && "key" in field || field.type !== "host" && typeof field.key !== "string" || field.value !== void 0 && typeof field.value !== "string" && (typeof field.value !== "object" || field.value === null || Array.isArray(field.value))
      )) {
        throw new Error(
          "The `experimentalBypassFor` argument for `Prerender` must be Array of objects with fields `type`, `key` and optionally `value`."
        );
      }
      this.experimentalBypassFor = experimentalBypassFor;
    }
    if (typeof fallback === "undefined") {
      throw new Error(
        "The `fallback` argument for `Prerender` needs to be a `FileBlob`, `FileFsRef`, `FileRef`, or null."
      );
    }
    this.fallback = fallback;
    if (initialHeaders !== void 0) {
      if (!initialHeaders || typeof initialHeaders !== "object" || Object.entries(initialHeaders).some(
        ([key, value]) => typeof key !== "string" || typeof value !== "string"
      )) {
        throw new Error(
          `The \`initialHeaders\` argument for \`Prerender\` must be an object with string key/values`
        );
      }
      this.initialHeaders = initialHeaders;
    }
    if (initialStatus !== void 0) {
      if (initialStatus <= 0 || !Number.isInteger(initialStatus)) {
        throw new Error(
          `The \`initialStatus\` argument for \`Prerender\` must be a natural number.`
        );
      }
      this.initialStatus = initialStatus;
    }
    if (allowQuery !== void 0) {
      if (!Array.isArray(allowQuery)) {
        throw new Error(
          "The `allowQuery` argument for `Prerender` must be Array."
        );
      }
      if (!allowQuery.every((q) => typeof q === "string")) {
        throw new Error(
          "The `allowQuery` argument for `Prerender` must be Array of strings."
        );
      }
      this.allowQuery = allowQuery;
    }
    if (allowHeader !== void 0) {
      if (!Array.isArray(allowHeader)) {
        throw new Error(
          "The `allowHeader` argument for `Prerender` must be Array."
        );
      }
      if (!allowHeader.every((q) => typeof q === "string")) {
        throw new Error(
          "The `allowHeader` argument for `Prerender` must be Array of strings."
        );
      }
      this.allowHeader = allowHeader;
    }
    if (experimentalStreamingLambdaPath !== void 0) {
      if (typeof experimentalStreamingLambdaPath !== "string") {
        throw new Error(
          "The `experimentalStreamingLambdaPath` argument for `Prerender` must be a string."
        );
      }
      this.experimentalStreamingLambdaPath = experimentalStreamingLambdaPath;
    }
    if (chain !== void 0) {
      if (typeof chain !== "object") {
        throw new Error(
          "The `chain` argument for `Prerender` must be an object."
        );
      }
      if (!chain.headers || typeof chain.headers !== "object" || Object.entries(chain.headers).some(
        ([key, value]) => typeof key !== "string" || typeof value !== "string"
      )) {
        throw new Error(
          `The \`chain.headers\` argument for \`Prerender\` must be an object with string key/values`
        );
      }
      if (!chain.outputPath || typeof chain.outputPath !== "string") {
        throw new Error(
          "The `chain.outputPath` argument for `Prerender` must be a string."
        );
      }
      this.chain = chain;
    }
  }
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  Prerender
});
