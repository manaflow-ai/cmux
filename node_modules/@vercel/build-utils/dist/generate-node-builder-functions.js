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
var generate_node_builder_functions_exports = {};
__export(generate_node_builder_functions_exports, {
  generateNodeBuilderFunctions: () => generateNodeBuilderFunctions
});
module.exports = __toCommonJS(generate_node_builder_functions_exports);
var import_glob = __toESM(require("./fs/glob"));
var import_node_path = require("node:path");
var import_node_fs = __toESM(require("node:fs"));
var import_node_module = require("node:module");
function generateNodeBuilderFunctions(frameworkName, regex, validFilenames, validExtensions, nodeBuild, opts) {
  const entrypointsForMessage = validFilenames.map((filename) => `- ${filename}.{${validExtensions.join(",")}}`).join("\n");
  const require_ = (0, import_node_module.createRequire)(__filename);
  const build = async (args) => {
    process.env.EXPERIMENTAL_NODE_TYPESCRIPT_ERRORS = "1";
    const includeFiles = ["views/**/*"];
    const includeFilesFromConfig = args.config.includeFiles;
    if (includeFilesFromConfig) {
      includeFiles.push(...includeFilesFromConfig);
    }
    const res = await nodeBuild({
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
      },
      checks: opts?.checks ?? (() => {
      })
    });
    let version = void 0;
    try {
      const resolved = require_.resolve(`${frameworkName}/package.json`, {
        paths: [args.workPath]
      });
      const frameworkVersion = require_(resolved).version;
      if (frameworkVersion) {
        version = frameworkVersion;
      }
    } catch (e) {
    }
    res.output.framework = {
      slug: frameworkName,
      version
    };
    return res;
  };
  const entrypointCallback = async (args) => {
    const mainPackageEntrypoint = findMainPackageEntrypoint(args.files);
    const entrypointGlob = `{${validFilenames.map((entrypoint) => `${entrypoint}`).join(",")}}.{${validExtensions.join(",")}}`;
    const dir = args.config.projectSettings?.outputDirectory?.replace(
      /^\/+|\/+$/g,
      ""
    );
    if (dir) {
      const {
        entrypoint: entrypointFromOutputDir,
        entrypointsNotMatchingRegex: entrypointsNotMatchingRegex2
      } = findEntrypoint(await (0, import_glob.default)(entrypointGlob, (0, import_node_path.join)(args.workPath, dir)));
      if (entrypointFromOutputDir) {
        return (0, import_node_path.join)(dir, entrypointFromOutputDir);
      }
      if (entrypointsNotMatchingRegex2.length > 0) {
        throw new Error(
          `No entrypoint found which imports ${frameworkName}. Found possible ${pluralize("entrypoint", entrypointsNotMatchingRegex2.length)}: ${entrypointsNotMatchingRegex2.join(", ")}`
        );
      }
      throw new Error(
        `No entrypoint found in output directory: "${dir}". Searched for: 
${entrypointsForMessage}`
      );
    }
    const files = await (0, import_glob.default)(entrypointGlob, args.workPath);
    const { entrypoint: entrypointFromRoot, entrypointsNotMatchingRegex } = findEntrypoint(files);
    if (entrypointFromRoot) {
      return entrypointFromRoot;
    }
    if (mainPackageEntrypoint) {
      const entrypointFromPackageJson = await (0, import_glob.default)(
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
        `No entrypoint found which imports ${frameworkName}. Found possible ${pluralize("entrypoint", entrypointsNotMatchingRegex.length)}: ${entrypointsNotMatchingRegex.join(", ")}`
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
  const findEntrypoint = (files) => {
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
  const checkMatchesRegex = (file) => {
    const content = import_node_fs.default.readFileSync(file.fsPath, "utf-8");
    const matchesContent = content.match(regex);
    return matchesContent !== null;
  };
  const findMainPackageEntrypoint = (files) => {
    const packageJson = files["package.json"];
    if (packageJson) {
      if (packageJson.type === "FileFsRef") {
        const packageJsonContent = import_node_fs.default.readFileSync(packageJson.fsPath, "utf-8");
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
  return {
    require_,
    findEntrypoint,
    build,
    entrypointCallback
  };
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  generateNodeBuilderFunctions
});
