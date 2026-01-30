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
var get_writable_directory_exports = {};
__export(get_writable_directory_exports, {
  default: () => getWritableDirectory
});
module.exports = __toCommonJS(get_writable_directory_exports);
var import_path = require("path");
var import_os = require("os");
var import_fs_extra = require("fs-extra");
async function getWritableDirectory() {
  const name = Math.floor(Math.random() * 2147483647).toString(16);
  const directory = (0, import_path.join)((0, import_os.tmpdir)(), name);
  await (0, import_fs_extra.mkdirp)(directory);
  return directory;
}
