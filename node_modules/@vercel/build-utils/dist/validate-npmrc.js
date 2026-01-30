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
var validate_npmrc_exports = {};
__export(validate_npmrc_exports, {
  validateNpmrc: () => validateNpmrc
});
module.exports = __toCommonJS(validate_npmrc_exports);
var import_path = require("path");
var import_promises = require("fs/promises");
async function validateNpmrc(cwd) {
  const npmrc = await (0, import_promises.readFile)((0, import_path.join)(cwd, ".npmrc"), "utf-8").catch((err) => {
    if (err.code !== "ENOENT")
      throw err;
  });
  const nodeRegExp = /(?<!#.*)use-node-version/;
  if (npmrc?.match(nodeRegExp)) {
    throw new Error(
      'Detected unsupported "use-node-version" in your ".npmrc". Please use "engines" in your "package.json" instead.'
    );
  }
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  validateNpmrc
});
