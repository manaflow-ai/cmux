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

// src/index.ts
var src_exports = {};
__export(src_exports, {
  build: () => build,
  entrypointCallback: () => entrypointCallback,
  findEntrypoint: () => findEntrypoint,
  prepareCache: () => prepareCache,
  require_: () => require_,
  shouldServe: () => shouldServe,
  startDevServer: () => startDevServer,
  version: () => version
});
module.exports = __toCommonJS(src_exports);

// src/build.ts
var import_node = require("@vercel/node");
var import_build_utils = require("@vercel/build-utils");
var { build, entrypointCallback, findEntrypoint, require_ } = (0, import_build_utils.generateNodeBuilderFunctions)(
  "koa",
  /(?:from|require|import)\s*(?:\(\s*)?["']koa["']\s*(?:\))?/g,
  ["app", "index", "server", "src/app", "src/index", "src/server"],
  ["js", "cjs", "mjs", "ts", "cts", "mts"],
  import_node.build
);

// src/prepare-cache.ts
var import_build_utils2 = require("@vercel/build-utils");
var prepareCache = ({ repoRootPath, workPath }) => {
  return (0, import_build_utils2.glob)(import_build_utils2.defaultCachePathGlob, repoRootPath || workPath);
};

// src/index.ts
var import_node2 = require("@vercel/node");
var version = 3;
var shouldServe = async (opts) => {
  const requestPath = opts.requestPath.replace(/\/$/, "");
  if (requestPath.startsWith("api") && opts.hasMatched) {
    return false;
  }
  return true;
};
var startDevServer = async (opts) => {
  const entrypoint = await entrypointCallback(opts);
  process.env.EXPERIMENTAL_NODE_TYPESCRIPT_ERRORS = "1";
  return (0, import_node2.startDevServer)({
    ...opts,
    entrypoint
  });
};
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  build,
  entrypointCallback,
  findEntrypoint,
  prepareCache,
  require_,
  shouldServe,
  startDevServer,
  version
});
