"use strict";
var __create = Object.create;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getProtoOf = Object.getPrototypeOf;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name2 in all)
    __defProp(target, name2, { get: all[name2], enumerable: true });
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

// src/index.ts
var src_exports = {};
__export(src_exports, {
  build: () => build,
  entrypointCallback: () => entrypointCallback,
  findEntrypoint: () => findEntrypoint,
  name: () => name,
  prepareCache: () => prepareCache,
  require_: () => require_,
  shouldServe: () => shouldServe,
  startDevServer: () => startDevServer,
  version: () => version
});
module.exports = __toCommonJS(src_exports);

// src/build.ts
var import_build_utils = require("@vercel/build-utils");
var import_node = require("@vercel/node");
var import_module = require("module");
var import_path = require("path");
var import_fs = __toESM(require("fs"));
var frameworkName = "express";
var REGEX = /(?:from|require|import)\s*(?:\(\s*)?["']express["']\s*(?:\))?/g;
var validFilenames = [
  "app",
  "index",
  "server",
  "src/app",
  "src/index",
  "src/server"
];
var require_ = (0, import_module.createRequire)(__filename);
var validExtensions = ["js", "cjs", "mjs", "ts", "cts", "mts"];
var entrypointsForMessage = validFilenames.map((filename) => `- ${filename}.{${validExtensions.join(",")}}`).join("\n");
var build = async (args) => {
  process.env.EXPERIMENTAL_NODE_TYPESCRIPT_ERRORS = "1";
  const includeFiles = ["views/**/*"];
  const includeFilesFromConfig = args.config.includeFiles;
  if (includeFilesFromConfig) {
    includeFiles.push(...includeFilesFromConfig);
  }
  const res = await (0, import_node.build)({
    ...args,
    config: {
      ...args.config,
      includeFiles
    },
    // this is package.json, but we'll replace it with the return value of the entrypointCallback
    // after install and build scripts have had a chance to run
    entrypoint: "package.json",
    considerBuildCommand: true,
    entrypointCallback: async () => {
      return entrypointCallback(args);
    }
  });
  let version2 = void 0;
  try {
    const resolved = require_.resolve(`${frameworkName}/package.json`, {
      paths: [args.workPath]
    });
    const expressVersion = require_(resolved).version;
    if (expressVersion) {
      version2 = expressVersion;
    }
  } catch (e) {
  }
  res.output.framework = {
    slug: frameworkName,
    version: version2
  };
  return res;
};
var entrypointCallback = async (args) => {
  const mainPackageEntrypoint = findMainPackageEntrypoint(args.files);
  const entrypointGlob = `{${validFilenames.map((entrypoint) => `${entrypoint}`).join(",")}}.{${validExtensions.join(",")}}`;
  const dir = args.config.projectSettings?.outputDirectory?.replace(
    /^\/+|\/+$/g,
    ""
  );
  if (dir) {
    const { entrypoint: entrypointFromOutputDir, entrypointsNotMatchingRegex: entrypointsNotMatchingRegex2 } = findEntrypoint(await (0, import_build_utils.glob)(entrypointGlob, (0, import_path.join)(args.workPath, dir)));
    if (entrypointFromOutputDir) {
      return (0, import_path.join)(dir, entrypointFromOutputDir);
    }
    if (entrypointsNotMatchingRegex2.length > 0) {
      throw new Error(
        `No entrypoint found which imports express. Found possible ${pluralize("entrypoint", entrypointsNotMatchingRegex2.length)}: ${entrypointsNotMatchingRegex2.join(", ")}`
      );
    }
    throw new Error(
      `No entrypoint found in output directory: "${dir}". Searched for: 
${entrypointsForMessage}`
    );
  }
  const files = await (0, import_build_utils.glob)(entrypointGlob, args.workPath);
  const { entrypoint: entrypointFromRoot, entrypointsNotMatchingRegex } = findEntrypoint(files);
  if (entrypointFromRoot) {
    return entrypointFromRoot;
  }
  if (mainPackageEntrypoint) {
    const entrypointFromPackageJson = await (0, import_build_utils.glob)(
      mainPackageEntrypoint,
      args.workPath
    );
    if (entrypointFromPackageJson[mainPackageEntrypoint]) {
      if (checkMatchesRegex(entrypointFromPackageJson[mainPackageEntrypoint])) {
        return mainPackageEntrypoint;
      }
    }
  }
  if (entrypointsNotMatchingRegex.length > 0) {
    throw new Error(
      `No entrypoint found which imports express. Found possible ${pluralize("entrypoint", entrypointsNotMatchingRegex.length)}: ${entrypointsNotMatchingRegex.join(", ")}`
    );
  }
  throw new Error(
    `No entrypoint found. Searched for:
${entrypointsForMessage}`
  );
};
function pluralize(word, count) {
  return count === 1 ? word : `${word}s`;
}
var findEntrypoint = (files) => {
  const allEntrypoints = validFilenames.flatMap(
    (filename) => validExtensions.map((extension) => `${filename}.${extension}`)
  );
  const possibleEntrypointsInFiles = allEntrypoints.filter((entrypoint2) => {
    return files[entrypoint2] !== void 0;
  });
  const entrypointsMatchingRegex = possibleEntrypointsInFiles.filter(
    (entrypoint2) => {
      const file = files[entrypoint2];
      return checkMatchesRegex(file);
    }
  );
  const entrypointsNotMatchingRegex = possibleEntrypointsInFiles.filter(
    (entrypoint2) => {
      const file = files[entrypoint2];
      return !checkMatchesRegex(file);
    }
  );
  const entrypoint = entrypointsMatchingRegex[0];
  if (entrypointsMatchingRegex.length > 1) {
    console.warn(
      `Multiple entrypoints found: ${entrypointsMatchingRegex.join(", ")}. Using ${entrypoint}.`
    );
  }
  return {
    entrypoint,
    entrypointsNotMatchingRegex
  };
};
var checkMatchesRegex = (file) => {
  const content = import_fs.default.readFileSync(file.fsPath, "utf-8");
  const matchesContent = content.match(REGEX);
  return matchesContent !== null;
};
var findMainPackageEntrypoint = (files) => {
  const packageJson = files["package.json"];
  if (packageJson) {
    if (packageJson.type === "FileFsRef") {
      const packageJsonContent = import_fs.default.readFileSync(packageJson.fsPath, "utf-8");
      let packageJsonJson;
      try {
        packageJsonJson = JSON.parse(packageJsonContent);
      } catch (_e) {
        packageJsonJson = {};
      }
      if ("main" in packageJsonJson && typeof packageJsonJson.main === "string") {
        return packageJsonJson.main;
      }
    }
  }
  return null;
};

// src/prepare-cache.ts
var import_build_utils2 = require("@vercel/build-utils");
var prepareCache = ({ repoRootPath, workPath }) => {
  return (0, import_build_utils2.glob)(import_build_utils2.defaultCachePathGlob, repoRootPath || workPath);
};

// src/index.ts
var import_node2 = require("@vercel/node");
var version = 3;
var name = "express";
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
    entrypoint,
    publicDir: "public"
  });
};
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  build,
  entrypointCallback,
  findEntrypoint,
  name,
  prepareCache,
  require_,
  shouldServe,
  startDevServer,
  version
});
