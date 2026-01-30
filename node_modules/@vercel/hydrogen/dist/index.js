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
  prepareCache: () => prepareCache,
  version: () => version
});
module.exports = __toCommonJS(src_exports);

// src/build.ts
var import_fs = require("fs");
var import_path = require("path");
var import_build_utils = require("@vercel/build-utils");
var import_static_config = require("@vercel/static-config");
var import_ts_morph = require("ts-morph");
var build = async ({
  entrypoint,
  files,
  workPath,
  config,
  meta = {}
}) => {
  const { installCommand, buildCommand } = config;
  await (0, import_build_utils.download)(files, workPath, meta);
  const prefixedEnvs = (0, import_build_utils.getPrefixedEnvVars)({
    envPrefix: "PUBLIC_",
    envs: process.env
  });
  for (const [key, value] of Object.entries(prefixedEnvs)) {
    process.env[key] = value;
  }
  const mountpoint = (0, import_path.dirname)(entrypoint);
  const entrypointDir = (0, import_path.join)(workPath, mountpoint);
  const {
    cliType,
    lockfileVersion,
    packageJsonPackageManager,
    turboSupportsCorepackHome
  } = await (0, import_build_utils.scanParentDirs)(entrypointDir, true);
  const spawnEnv = (0, import_build_utils.getEnvForPackageManager)({
    cliType,
    lockfileVersion,
    packageJsonPackageManager,
    env: process.env,
    turboSupportsCorepackHome,
    projectCreatedAt: config.projectSettings?.createdAt
  });
  if (typeof installCommand === "string") {
    if (installCommand.trim()) {
      console.log(`Running "install" command: \`${installCommand}\`...`);
      await (0, import_build_utils.execCommand)(installCommand, {
        env: spawnEnv,
        cwd: entrypointDir
      });
    } else {
      console.log(`Skipping "install" command...`);
    }
  } else {
    await (0, import_build_utils.runNpmInstall)(
      entrypointDir,
      [],
      { env: spawnEnv },
      meta,
      config.projectSettings?.createdAt
    );
  }
  const edgeEntryDir = (0, import_path.join)(workPath, ".vercel/cache/hydrogen");
  const edgeEntryRelative = (0, import_path.relative)(edgeEntryDir, workPath);
  const edgeEntryDest = (0, import_path.join)(edgeEntryDir, "edge-entry.js");
  let edgeEntryContents = await import_fs.promises.readFile(
    (0, import_path.join)(__dirname, "..", "edge-entry.js"),
    "utf8"
  );
  edgeEntryContents = edgeEntryContents.replace(
    /__RELATIVE__/g,
    edgeEntryRelative
  );
  await import_fs.promises.mkdir(edgeEntryDir, { recursive: true });
  await import_fs.promises.writeFile(edgeEntryDest, edgeEntryContents);
  spawnEnv.SHOPIFY_FLAG_BUILD_TARGET = "worker";
  spawnEnv.SHOPIFY_FLAG_BUILD_SSR_ENTRY = edgeEntryDest;
  if (buildCommand) {
    (0, import_build_utils.debug)(`Executing build command "${buildCommand}"`);
    await (0, import_build_utils.execCommand)(buildCommand, {
      env: spawnEnv,
      cwd: entrypointDir
    });
  } else {
    const pkg = await (0, import_build_utils.readConfigFile)(
      (0, import_path.join)(entrypointDir, "package.json")
    );
    if (hasScript("vercel-build", pkg)) {
      (0, import_build_utils.debug)(`Executing "yarn vercel-build"`);
      await (0, import_build_utils.runPackageJsonScript)(
        entrypointDir,
        "vercel-build",
        { env: spawnEnv },
        config.projectSettings?.createdAt
      );
    } else if (hasScript("build", pkg)) {
      (0, import_build_utils.debug)(`Executing "yarn build"`);
      await (0, import_build_utils.runPackageJsonScript)(
        entrypointDir,
        "build",
        { env: spawnEnv },
        config.projectSettings?.createdAt
      );
    } else {
      await (0, import_build_utils.execCommand)("shopify hydrogen build", {
        env: spawnEnv,
        cwd: entrypointDir
      });
    }
  }
  const [staticFiles, edgeFunctionFiles] = await Promise.all([
    (0, import_build_utils.glob)("**", (0, import_path.join)(entrypointDir, "dist/client")),
    (0, import_build_utils.glob)("**", (0, import_path.join)(entrypointDir, "dist/worker"))
  ]);
  const edgeFunction = new import_build_utils.EdgeFunction({
    deploymentTarget: "v8-worker",
    entrypoint: "index.js",
    files: edgeFunctionFiles,
    regions: (() => {
      try {
        const project = new import_ts_morph.Project();
        const config2 = (0, import_static_config.getConfig)(project, edgeFunctionFiles["index.js"].fsPath);
        return config2?.regions;
      } catch {
        return void 0;
      }
    })()
  });
  delete staticFiles["index.html"];
  return {
    routes: [
      {
        handle: "filesystem"
      },
      {
        src: "/(.*)",
        dest: "/hydrogen"
      }
    ],
    output: {
      hydrogen: edgeFunction,
      ...staticFiles
    }
  };
};
function hasScript(scriptName, pkg) {
  const scripts = pkg?.scripts || {};
  return typeof scripts[scriptName] === "string";
}

// src/prepare-cache.ts
var import_build_utils2 = require("@vercel/build-utils");
var prepareCache = ({ repoRootPath, workPath }) => {
  return (0, import_build_utils2.glob)(import_build_utils2.defaultCachePathGlob, repoRootPath || workPath);
};

// src/index.ts
var version = 2;
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  build,
  prepareCache,
  version
});
