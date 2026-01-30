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
var run_user_scripts_exports = {};
__export(run_user_scripts_exports, {
  PNPM_10_PREFERRED_AT: () => PNPM_10_PREFERRED_AT,
  detectPackageManager: () => detectPackageManager,
  execCommand: () => execCommand,
  findPackageJson: () => findPackageJson,
  getEnvForPackageManager: () => getEnvForPackageManager,
  getNodeBinPath: () => getNodeBinPath,
  getNodeBinPaths: () => getNodeBinPaths,
  getNodeVersion: () => getNodeVersion,
  getPathForPackageManager: () => getPathForPackageManager,
  getPathOverrideForPackageManager: () => getPathOverrideForPackageManager,
  getScriptName: () => getScriptName,
  getSpawnOptions: () => getSpawnOptions,
  installDependencies: () => installDependencies,
  resetCustomInstallCommandSet: () => resetCustomInstallCommandSet,
  runBundleInstall: () => runBundleInstall,
  runCustomInstallCommand: () => runCustomInstallCommand,
  runNpmInstall: () => runNpmInstall,
  runPackageJsonScript: () => runPackageJsonScript,
  runPipInstall: () => runPipInstall,
  runShellScript: () => runShellScript,
  scanParentDirs: () => scanParentDirs,
  spawnAsync: () => spawnAsync,
  spawnCommand: () => spawnCommand,
  traverseUpDirectories: () => traverseUpDirectories,
  turboVersionSpecifierSupportsCorepack: () => turboVersionSpecifierSupportsCorepack,
  usingCorepack: () => usingCorepack,
  walkParentDirs: () => walkParentDirs
});
module.exports = __toCommonJS(run_user_scripts_exports);
var import_assert = __toESM(require("assert"));
var import_fs_extra = __toESM(require("fs-extra"));
var import_path = __toESM(require("path"));
var import_async_sema = __toESM(require("async-sema"));
var import_cross_spawn = __toESM(require("cross-spawn"));
var import_semver = require("semver");
var import_util = require("util");
var import_debug = __toESM(require("../debug"));
var import_errors = require("../errors");
var import_node_version = require("./node-version");
var import_read_config_file = require("./read-config-file");
var import_clone_env = require("../clone-env");
var import_json5 = __toESM(require("json5"));
var import_js_yaml = __toESM(require("js-yaml"));
const NO_OVERRIDE = {
  detectedLockfile: void 0,
  detectedPackageManager: void 0,
  path: void 0
};
function spawnAsync(command, args, opts = {}) {
  return new Promise((resolve, reject) => {
    const stderrLogs = [];
    opts = { stdio: "inherit", ...opts };
    const child = (0, import_cross_spawn.default)(command, args, opts);
    if (opts.stdio === "pipe" && child.stderr) {
      child.stderr.on("data", (data) => stderrLogs.push(data));
    }
    child.on("error", reject);
    child.on("close", (code, signal) => {
      if (code === 0 || opts.ignoreNon0Exit) {
        return resolve();
      }
      const cmd = opts.prettyCommand ? `Command "${opts.prettyCommand}"` : "Command";
      reject(
        new import_errors.NowBuildError({
          code: `BUILD_UTILS_SPAWN_${code || signal}`,
          message: opts.stdio === "inherit" ? `${cmd} exited with ${code || signal}` : stderrLogs.map((line) => line.toString()).join("")
        })
      );
    });
  });
}
function spawnCommand(command, options = {}) {
  const opts = { ...options, prettyCommand: command };
  if (process.platform === "win32") {
    return (0, import_cross_spawn.default)("cmd.exe", ["/C", command], opts);
  }
  return (0, import_cross_spawn.default)("sh", ["-c", command], opts);
}
async function execCommand(command, options = {}) {
  const opts = { ...options, prettyCommand: command };
  if (process.platform === "win32") {
    await spawnAsync("cmd.exe", ["/C", command], opts);
  } else {
    await spawnAsync("sh", ["-c", command], opts);
  }
  return true;
}
function* traverseUpDirectories({
  start,
  base
}) {
  let current = import_path.default.normalize(start);
  const normalizedRoot = base ? import_path.default.normalize(base) : void 0;
  while (current) {
    yield current;
    if (current === normalizedRoot)
      break;
    const next = import_path.default.join(current, "..");
    current = next === current ? void 0 : next;
  }
}
async function readProjectRootInfo({
  start,
  base
}) {
  let curRootPackageJsonPath;
  for (const dir of traverseUpDirectories({ start, base })) {
    const packageJsonPath = import_path.default.join(dir, "package.json");
    if (await import_fs_extra.default.pathExists(packageJsonPath)) {
      curRootPackageJsonPath = packageJsonPath;
    }
  }
  return curRootPackageJsonPath ? {
    packageJson: await import_fs_extra.default.readJson(curRootPackageJsonPath),
    rootDir: import_path.default.dirname(curRootPackageJsonPath)
  } : void 0;
}
async function getNodeBinPath({
  cwd
}) {
  const { lockfilePath } = await scanParentDirs(cwd);
  const dir = import_path.default.dirname(lockfilePath || cwd);
  return import_path.default.join(dir, "node_modules", ".bin");
}
function getNodeBinPaths({
  start,
  base
}) {
  return Array.from(traverseUpDirectories({ start, base })).map(
    (dir) => import_path.default.join(dir, "node_modules/.bin")
  );
}
async function chmodPlusX(fsPath) {
  const s = await import_fs_extra.default.stat(fsPath);
  const newMode = s.mode | 64 | 8 | 1;
  if (s.mode === newMode)
    return;
  const base8 = newMode.toString(8).slice(-3);
  await import_fs_extra.default.chmod(fsPath, base8);
}
async function runShellScript(fsPath, args = [], spawnOpts) {
  (0, import_assert.default)(import_path.default.isAbsolute(fsPath));
  const destPath = import_path.default.dirname(fsPath);
  await chmodPlusX(fsPath);
  const command = `./${import_path.default.basename(fsPath)}`;
  await spawnAsync(command, args, {
    ...spawnOpts,
    cwd: destPath,
    prettyCommand: command
  });
  return true;
}
function getSpawnOptions(meta, nodeVersion) {
  const opts = {
    env: (0, import_clone_env.cloneEnv)(process.env)
  };
  if ((0, import_node_version.isBunVersion)(nodeVersion)) {
    return opts;
  }
  if (!meta.isDev) {
    let found = false;
    const oldPath = opts.env.PATH || process.env.PATH || "";
    const pathSegments = oldPath.split(import_path.default.delimiter).map((segment) => {
      if (/^\/node[0-9]+\/bin/.test(segment)) {
        found = true;
        return `/node${nodeVersion.major}/bin`;
      }
      return segment;
    });
    if (!found) {
      pathSegments.unshift(`/node${nodeVersion.major}/bin`);
    }
    opts.env.PATH = pathSegments.filter(Boolean).join(import_path.default.delimiter);
  }
  return opts;
}
async function getNodeVersion(destPath, fallbackVersion = process.env.VERCEL_PROJECT_SETTINGS_NODE_VERSION, config = {}, meta = {}, availableVersions = (0, import_node_version.getAvailableNodeVersions)()) {
  if (config.bunVersion) {
    return (0, import_node_version.getSupportedBunVersion)(config.bunVersion);
  }
  const latestVersion = (0, import_node_version.getLatestNodeVersion)(availableVersions);
  if (meta.isDev) {
    latestVersion.runtime = "nodejs";
    return latestVersion;
  }
  const { packageJson } = await findPackageJson(destPath, true);
  const configuredVersion = config.nodeVersion || fallbackVersion;
  const packageJsonVersion = packageJson?.engines?.node;
  const supportedNodeVersion = await (0, import_node_version.getSupportedNodeVersion)(
    packageJsonVersion || configuredVersion,
    !packageJsonVersion,
    availableVersions
  );
  if (packageJson?.engines?.node) {
    const { node } = packageJson.engines;
    if (configuredVersion && !(0, import_semver.intersects)(configuredVersion, supportedNodeVersion.range)) {
      console.warn(
        `Warning: Due to "engines": { "node": "${node}" } in your \`package.json\` file, the Node.js Version defined in your Project Settings ("${configuredVersion}") will not apply, Node.js Version "${supportedNodeVersion.range}" will be used instead. Learn More: https://vercel.link/node-version`
      );
    }
    if ((0, import_semver.coerce)(node)?.raw === node) {
      console.warn(
        `Warning: Detected "engines": { "node": "${node}" } in your \`package.json\` with major.minor.patch, but only major Node.js Version can be selected. Learn More: https://vercel.link/node-version`
      );
    } else if ((0, import_semver.validRange)(node) && (0, import_semver.intersects)(`${latestVersion.major + 1}.x`, node)) {
      console.warn(
        `Warning: Detected "engines": { "node": "${node}" } in your \`package.json\` that will automatically upgrade when a new major Node.js Version is released. Learn More: https://vercel.link/node-version`
      );
    }
  }
  return supportedNodeVersion;
}
async function findPackageJson(destPath, readPackageJson = false, base = "/") {
  (0, import_assert.default)(import_path.default.isAbsolute(destPath));
  const pkgJsonPath = await walkParentDirs({
    base,
    start: destPath,
    filename: "package.json"
  });
  let packageJson;
  if (readPackageJson && pkgJsonPath) {
    try {
      packageJson = JSON.parse(await import_fs_extra.default.readFile(pkgJsonPath, "utf8"));
    } catch (err) {
      throw new Error(
        `Could not read ${pkgJsonPath}: ${err.message}.`
      );
    }
  }
  return {
    packageJsonPath: pkgJsonPath || void 0,
    packageJson
  };
}
async function scanParentDirs(destPath, readPackageJson = false, base = "/") {
  (0, import_assert.default)(import_path.default.isAbsolute(destPath));
  const { packageJsonPath: pkgJsonPath, packageJson } = await findPackageJson(
    destPath,
    readPackageJson,
    base
  );
  const {
    paths: [
      yarnLockPath,
      npmLockPath,
      pnpmLockPath,
      bunLockTextPath,
      bunLockBinPath,
      vltLockPath
    ],
    packageJsonPackageManager
  } = await walkParentDirsMulti({
    base,
    start: destPath,
    filenames: [
      "yarn.lock",
      "package-lock.json",
      "pnpm-lock.yaml",
      "bun.lock",
      "bun.lockb",
      "vlt-lock.json"
    ]
  });
  let lockfilePath;
  let lockfileVersion;
  let cliType;
  const bunLockPath = bunLockTextPath ?? bunLockBinPath;
  const [packageLockJson, pnpmLockYaml, bunLock, yarnLock, vltLock] = await Promise.all([
    npmLockPath ? (0, import_read_config_file.readConfigFile)(npmLockPath) : null,
    pnpmLockPath ? (0, import_read_config_file.readConfigFile)(pnpmLockPath) : null,
    bunLockPath ? import_fs_extra.default.readFile(bunLockPath) : null,
    yarnLockPath ? import_fs_extra.default.readFile(yarnLockPath, "utf8") : null,
    vltLockPath ? (0, import_read_config_file.readConfigFile)(vltLockPath) : null
  ]);
  const rootProjectInfo = readPackageJson ? await readProjectRootInfo({
    base,
    start: destPath
  }) : void 0;
  const turboVersionRange = rootProjectInfo?.packageJson?.devDependencies?.turbo;
  const turboSupportsCorepackHome = turboVersionRange ? await checkTurboSupportsCorepack(
    turboVersionRange,
    rootProjectInfo?.rootDir
  ) : void 0;
  if (bunLock && yarnLock) {
    cliType = "bun";
    lockfilePath = bunLockPath;
    lockfileVersion = bunLockTextPath ? 1 : 0;
  } else if (yarnLock) {
    cliType = "yarn";
    lockfilePath = yarnLockPath;
    lockfileVersion = parseYarnLockVersion(yarnLock);
  } else if (pnpmLockYaml) {
    cliType = "pnpm";
    lockfilePath = pnpmLockPath;
    lockfileVersion = Number(pnpmLockYaml.lockfileVersion);
  } else if (packageLockJson) {
    cliType = "npm";
    lockfilePath = npmLockPath;
    lockfileVersion = packageLockJson.lockfileVersion;
  } else if (bunLock) {
    cliType = "bun";
    lockfilePath = bunLockPath;
    lockfileVersion = bunLockTextPath ? 1 : 0;
  } else if (vltLock) {
    cliType = "vlt";
    lockfilePath = vltLockPath;
  } else {
    cliType = detectPackageManagerNameWithoutLockfile(
      packageJsonPackageManager,
      turboSupportsCorepackHome
    );
  }
  const packageJsonPath = pkgJsonPath || void 0;
  return {
    cliType,
    packageJson,
    packageJsonPackageManager,
    lockfilePath,
    lockfileVersion,
    packageJsonPath,
    turboSupportsCorepackHome
  };
}
function parseYarnLockVersion(yarnLock) {
  if (!yarnLock.includes("__metadata:")) {
    return 1;
  }
  try {
    const metadata = import_js_yaml.default.load(yarnLock).__metadata;
    return Number(metadata.version);
  } catch {
    return void 0;
  }
}
async function checkTurboSupportsCorepack(turboVersionRange, rootDir) {
  if (turboVersionSpecifierSupportsCorepack(turboVersionRange)) {
    return true;
  }
  const turboJsonPath = import_path.default.join(rootDir, "turbo.json");
  const turboJsoncPath = import_path.default.join(rootDir, "turbo.jsonc");
  const [turboJsonExists, turboJsoncExists] = await Promise.all([
    import_fs_extra.default.pathExists(turboJsonPath),
    import_fs_extra.default.pathExists(turboJsoncPath)
  ]);
  let turboJson = null;
  let turboConfigPath = null;
  if (turboJsonExists) {
    turboConfigPath = turboJsonPath;
  } else if (turboJsoncExists) {
    turboConfigPath = turboJsoncPath;
  }
  if (turboConfigPath) {
    try {
      turboJson = import_json5.default.parse(await import_fs_extra.default.readFile(turboConfigPath, "utf8"));
    } catch (err) {
      console.warn(
        `WARNING: Failed to parse ${import_path.default.basename(turboConfigPath)}`
      );
    }
  }
  const turboJsonIncludesCorepackHome = turboJson !== null && typeof turboJson === "object" && "globalPassThroughEnv" in turboJson && Array.isArray(turboJson.globalPassThroughEnv) && turboJson.globalPassThroughEnv.includes("COREPACK_HOME");
  return turboJsonIncludesCorepackHome;
}
function turboVersionSpecifierSupportsCorepack(turboVersionSpecifier) {
  if (!(0, import_semver.validRange)(turboVersionSpecifier)) {
    return false;
  }
  const versionSupportingCorepack = "2.1.3";
  const minTurboBeingUsed = (0, import_semver.minVersion)(turboVersionSpecifier);
  if (!minTurboBeingUsed) {
    return false;
  }
  return (0, import_semver.gte)(minTurboBeingUsed, versionSupportingCorepack);
}
function detectPackageManagerNameWithoutLockfile(packageJsonPackageManager, turboSupportsCorepackHome) {
  if (usingCorepack(
    process.env,
    packageJsonPackageManager,
    turboSupportsCorepackHome
  )) {
    const corepackPackageManager = validateVersionSpecifier(
      packageJsonPackageManager
    );
    switch (corepackPackageManager?.packageName) {
      case "npm":
      case "pnpm":
      case "yarn":
      case "bun":
        return corepackPackageManager.packageName;
      case void 0:
        return "npm";
      default:
        throw new Error(
          `Unknown package manager "${corepackPackageManager?.packageName}". Change your package.json "packageManager" field to a known package manager: npm, pnpm, yarn, bun.`
        );
    }
  }
  return "npm";
}
function usingCorepack(env, packageJsonPackageManager, turboSupportsCorepackHome) {
  if (env.ENABLE_EXPERIMENTAL_COREPACK !== "1" || packageJsonPackageManager === void 0) {
    return false;
  }
  if (turboSupportsCorepackHome === false) {
    console.warn(
      "Warning: Disabling corepack because it may break your project. To use corepack, either upgrade to `turbo@2.1.3+` or include `COREPACK_HOME` in `turbo.json#globalPassThroughEnv`."
    );
    return false;
  }
  return true;
}
async function walkParentDirs({
  base,
  start,
  filename
}) {
  (0, import_assert.default)(import_path.default.isAbsolute(base), 'Expected "base" to be absolute path');
  (0, import_assert.default)(import_path.default.isAbsolute(start), 'Expected "start" to be absolute path');
  for (const dir of traverseUpDirectories({ start, base })) {
    const fullPath = import_path.default.join(dir, filename);
    if (await import_fs_extra.default.pathExists(fullPath)) {
      return fullPath;
    }
  }
  return null;
}
async function walkParentDirsMulti({
  base,
  start,
  filenames
}) {
  let packageManager;
  for (const dir of traverseUpDirectories({ start, base })) {
    const fullPaths = filenames.map((f) => import_path.default.join(dir, f));
    const existResults = await Promise.all(
      fullPaths.map((f) => import_fs_extra.default.pathExists(f))
    );
    const foundOneOrMore = existResults.some((b) => b);
    const packageJsonPath = import_path.default.join(dir, "package.json");
    const packageJson = await import_fs_extra.default.readJSON(packageJsonPath).catch(() => null);
    if (packageJson?.packageManager) {
      packageManager = packageJson.packageManager;
    }
    if (foundOneOrMore) {
      return {
        paths: fullPaths.map((f, i) => existResults[i] ? f : void 0),
        packageJsonPackageManager: packageManager
      };
    }
  }
  return { paths: [], packageJsonPackageManager: packageManager };
}
function isSet(v) {
  return v?.constructor?.name === "Set";
}
function getInstallCommandForPackageManager(packageManager, args) {
  switch (packageManager) {
    case "npm":
      return {
        prettyCommand: "npm install",
        commandArguments: args.filter((a) => a !== "--prefer-offline").concat(["install", "--no-audit"])
      };
    case "pnpm":
      return {
        prettyCommand: "pnpm install",
        // PNPM's install command is similar to NPM's but without the audit nonsense
        // @see options https://pnpm.io/cli/install
        commandArguments: args.filter((a) => a !== "--prefer-offline").concat(["install", "--unsafe-perm"])
      };
    case "bun":
      return {
        prettyCommand: "bun install",
        // @see options https://bun.sh/docs/cli/install
        commandArguments: ["install", ...args]
      };
    case "yarn":
      return {
        prettyCommand: "yarn install",
        commandArguments: ["install", ...args]
      };
    case "vlt":
      return {
        prettyCommand: "vlt install",
        commandArguments: ["install", ...args]
      };
  }
}
async function runInstallCommand({
  packageManager,
  args,
  opts
}) {
  const { commandArguments, prettyCommand } = getInstallCommandForPackageManager(packageManager, args);
  opts.prettyCommand = prettyCommand;
  if (process.env.NPM_ONLY_PRODUCTION) {
    commandArguments.push("--production");
  }
  await spawnAsync(packageManager, commandArguments, opts);
}
function initializeSet(set) {
  if (!isSet(set)) {
    return /* @__PURE__ */ new Set();
  }
  return set;
}
function checkIfAlreadyInstalled(runNpmInstallSet, packageJsonPath) {
  const initializedRunNpmInstallSet = initializeSet(runNpmInstallSet);
  const alreadyInstalled = initializedRunNpmInstallSet.has(packageJsonPath);
  initializedRunNpmInstallSet.add(packageJsonPath);
  return { alreadyInstalled, runNpmInstallSet: initializedRunNpmInstallSet };
}
const runNpmInstallSema = new import_async_sema.default(1);
let customInstallCommandSet;
function resetCustomInstallCommandSet() {
  customInstallCommandSet = void 0;
}
async function runNpmInstall(destPath, args = [], spawnOpts, meta, projectCreatedAt) {
  if (meta?.isDev) {
    (0, import_debug.default)("Skipping dependency installation because dev mode is enabled");
    return false;
  }
  (0, import_assert.default)(import_path.default.isAbsolute(destPath));
  try {
    await runNpmInstallSema.acquire();
    const {
      cliType,
      packageJsonPath,
      packageJson,
      lockfileVersion,
      packageJsonPackageManager,
      turboSupportsCorepackHome
    } = await scanParentDirs(destPath, true);
    if (!packageJsonPath) {
      (0, import_debug.default)(
        `Skipping dependency installation because no package.json was found for ${destPath}`
      );
      return false;
    }
    const defaultInstall = args.length === 0;
    if (meta && packageJsonPath && defaultInstall) {
      const { alreadyInstalled, runNpmInstallSet } = checkIfAlreadyInstalled(
        meta.runNpmInstallSet,
        packageJsonPath
      );
      if (alreadyInstalled) {
        return false;
      }
      if (process.env.VERCEL_INSTALL_COMPLETED === "1") {
        (0, import_debug.default)(
          `Skipping dependency installation for ${packageJsonPath} because VERCEL_INSTALL_COMPLETED is set`
        );
        runNpmInstallSet.add(packageJsonPath);
        meta.runNpmInstallSet = runNpmInstallSet;
        return false;
      }
      meta.runNpmInstallSet = runNpmInstallSet;
    }
    if (cliType === "yarn") {
      const yarnVersion = detectYarnVersion(lockfileVersion);
      if (["yarn@3.x", "yarn@4.x"].includes(yarnVersion)) {
        await spawnAsync(
          "yarn",
          ["config", "set", "enableGlobalCache", "false"],
          { cwd: destPath }
        );
      }
    }
    const installTime = Date.now();
    console.log("Installing dependencies...");
    (0, import_debug.default)(`Installing to ${destPath}`);
    const opts = { cwd: destPath, ...spawnOpts };
    const env = (0, import_clone_env.cloneEnv)(opts.env || process.env);
    delete env.NODE_ENV;
    opts.env = getEnvForPackageManager({
      cliType,
      lockfileVersion,
      packageJsonPackageManager,
      env,
      packageJsonEngines: packageJson?.engines,
      turboSupportsCorepackHome,
      projectCreatedAt
    });
    const maySeeDynamicRequireYarnBug = process.env?.ENABLE_EXPERIMENTAL_COREPACK && packageJson?.packageManager?.startsWith("yarn") && packageJson?.type === "module";
    if (maySeeDynamicRequireYarnBug) {
      console.warn(
        `Warning: This project may see "Error: Dynamic require of "util" is not supported". To avoid this error, remove \`"type": "module"\` from your package.json file, or use \`yarnPath\` instead of Corepack. Learn more: https://vercel.com/docs/errors/error-list#yarn-dynamic-require-of-util-is-not-supported`
      );
    }
    await runInstallCommand({
      packageManager: cliType,
      args,
      opts
    });
    (0, import_debug.default)(`Install complete [${Date.now() - installTime}ms]`);
    return true;
  } finally {
    runNpmInstallSema.release();
  }
}
function getEnvForPackageManager({
  cliType,
  lockfileVersion,
  packageJsonPackageManager,
  env,
  packageJsonEngines,
  turboSupportsCorepackHome,
  projectCreatedAt
}) {
  const corepackEnabled = usingCorepack(
    env,
    packageJsonPackageManager,
    turboSupportsCorepackHome
  );
  const {
    detectedLockfile,
    detectedPackageManager,
    path: newPath
  } = getPathOverrideForPackageManager({
    cliType,
    lockfileVersion,
    corepackPackageManager: packageJsonPackageManager,
    corepackEnabled,
    packageJsonEngines,
    projectCreatedAt
  });
  if (corepackEnabled) {
    (0, import_debug.default)(
      `Detected corepack use for "${packageJsonPackageManager}". Not overriding package manager version.`
    );
  } else {
    (0, import_debug.default)(
      `Detected ${detectedPackageManager}. Added "${newPath}" to path. Based on assumed package manager "${cliType}", lockfile "${detectedLockfile}", and lockfileVersion "${lockfileVersion}"`
    );
  }
  const newEnv = {
    ...env
  };
  const alreadyInPath = (newPath2) => {
    const oldPath = env.PATH ?? "";
    return oldPath.split(import_path.default.delimiter).includes(newPath2);
  };
  if (newPath && !alreadyInPath(newPath)) {
    const oldPath = env.PATH + "";
    newEnv.PATH = `${newPath}${import_path.default.delimiter}${oldPath}`;
    if (detectedLockfile && detectedPackageManager) {
      const detectedV9PnpmLockfile = detectedLockfile === "pnpm-lock.yaml" && lockfileVersion === 9;
      const pnpm10UsingPackageJsonPackageManager = detectedPackageManager === "pnpm@10.x" && packageJsonPackageManager;
      if (pnpm10UsingPackageJsonPackageManager) {
        const versionString = cliType === "pnpm" ? `version ${lockfileVersion} ` : "";
        console.log(
          `Detected \`${detectedLockfile}\` ${versionString}generated by ${detectedPackageManager} with package.json#packageManager ${packageJsonPackageManager}`
        );
      } else if (detectedV9PnpmLockfile) {
        const otherVersion = detectedPackageManager === "pnpm@10.x" ? `pnpm@9.x` : `pnpm@10.x`;
        console.log(
          `Detected \`${detectedLockfile}\` ${lockfileVersion} which may be generated by pnpm@9.x or pnpm@10.x
Using ${detectedPackageManager} based on project creation date
To use ${otherVersion}, manually opt in using corepack (https://vercel.com/docs/deployments/configure-a-build#corepack)`
        );
      } else {
        const versionString = cliType === "pnpm" ? `version ${lockfileVersion} ` : "";
        console.log(
          `Detected \`${detectedLockfile}\` ${versionString}generated by ${detectedPackageManager}`
        );
      }
    }
  }
  if (cliType === "yarn" && !env.YARN_NODE_LINKER) {
    newEnv.YARN_NODE_LINKER = "node-modules";
  }
  return newEnv;
}
const PNPM_10_PREFERRED_AT = /* @__PURE__ */ new Date("2025-02-27T20:00:00Z");
function detectPnpmVersion(lockfileVersion, projectCreatedAt) {
  switch (true) {
    case lockfileVersion === void 0:
      return "not found";
    case lockfileVersion === 5.3:
      return "pnpm 6";
    case lockfileVersion === 5.4:
      return "pnpm 7";
    case (lockfileVersion === 6 || lockfileVersion === 6.1):
      return "pnpm 8";
    case lockfileVersion === 7:
      return "pnpm 9";
    case lockfileVersion === 9: {
      const projectPrefersPnpm10 = projectCreatedAt && projectCreatedAt >= PNPM_10_PREFERRED_AT.getTime();
      return projectPrefersPnpm10 ? "pnpm 10" : "pnpm 9";
    }
    default:
      return "not found";
  }
}
function detectYarnVersion(lockfileVersion) {
  if (lockfileVersion) {
    if ([1].includes(lockfileVersion)) {
      return "yarn@1.x";
    } else if ([4, 5].includes(lockfileVersion)) {
      return "yarn@2.x";
    } else if ([6, 7].includes(lockfileVersion)) {
      return "yarn@3.x";
    } else if ([8].includes(lockfileVersion)) {
      return "yarn@4.x";
    }
  }
  return "unknown yarn";
}
function validLockfileForPackageManager(cliType, lockfileVersion, packageManagerVersion) {
  const packageManagerMajorVersion = packageManagerVersion.major;
  switch (cliType) {
    case "npm":
    case "bun":
    case "yarn":
    case "vlt":
      return true;
    case "pnpm":
      switch (packageManagerMajorVersion) {
        case 10:
          return lockfileVersion === 9;
        case 9:
          if ("9.0.0" === packageManagerVersion.version && lockfileVersion === 6) {
            return false;
          }
          return [6, 7, 9].includes(lockfileVersion);
        case 8:
          return [6, 6.1].includes(lockfileVersion);
        case 7:
          return [5.3, 5.4].includes(lockfileVersion);
        case 6:
          return [5.3, 5.4].includes(lockfileVersion);
        default:
          return true;
      }
  }
}
function getPathOverrideForPackageManager({
  cliType,
  lockfileVersion,
  corepackPackageManager,
  corepackEnabled = true,
  packageJsonEngines,
  projectCreatedAt
}) {
  const detectedPackageManger = detectPackageManager(
    cliType,
    lockfileVersion,
    projectCreatedAt
  );
  const usingCorepack2 = corepackPackageManager && corepackEnabled;
  if (usingCorepack2) {
    validateCorepackPackageManager(
      cliType,
      lockfileVersion,
      corepackPackageManager,
      packageJsonEngines?.pnpm
    );
    return NO_OVERRIDE;
  }
  if (cliType === "pnpm" && packageJsonEngines?.pnpm) {
    const usingDetected = detectedPackageManger?.pnpmVersionRange !== "10.x" || !corepackPackageManager;
    if (usingDetected) {
      checkEnginesPnpmAgainstDetected(
        packageJsonEngines.pnpm,
        detectedPackageManger
      );
    }
  }
  return detectedPackageManger ?? NO_OVERRIDE;
}
function checkEnginesPnpmAgainstDetected(enginesPnpm, detectedPackageManger) {
  if (detectedPackageManger?.pnpmVersionRange && (0, import_semver.validRange)(detectedPackageManger.pnpmVersionRange) && (0, import_semver.validRange)(enginesPnpm)) {
    if (!(0, import_semver.intersects)(detectedPackageManger.pnpmVersionRange, enginesPnpm)) {
      throw new Error(
        `Detected pnpm "${detectedPackageManger.pnpmVersionRange}" is not compatible with the engines.pnpm "${enginesPnpm}" in your package.json. Either enable corepack with a valid package.json#packageManager value (https://vercel.com/docs/deployments/configure-a-build#corepack) or remove your package.json#engines.pnpm.`
      );
    }
  }
  console.warn(
    `Using package.json#engines.pnpm without corepack and package.json#packageManager could lead to failed builds with ERR_PNPM_UNSUPPORTED_ENGINE. Learn more: https://vercel.com/docs/errors/error-list#pnpm-engine-unsupported`
  );
}
function validateCorepackPackageManager(cliType, lockfileVersion, corepackPackageManager, enginesPnpmVersionRange) {
  const validatedCorepackPackageManager = validateVersionSpecifier(
    corepackPackageManager
  );
  if (!validatedCorepackPackageManager) {
    throw new Error(
      `Intended corepack defined package manager "${corepackPackageManager}" is not a valid semver value.`
    );
  }
  if (cliType !== validatedCorepackPackageManager.packageName) {
    throw new Error(
      `Detected package manager "${cliType}" does not match intended corepack defined package manager "${validatedCorepackPackageManager.packageName}". Change your lockfile or "package.json#packageManager" value to match.`
    );
  }
  if (cliType === "pnpm" && enginesPnpmVersionRange) {
    const pnpmWithinEngineRange = (0, import_semver.satisfies)(
      validatedCorepackPackageManager.packageVersion,
      enginesPnpmVersionRange
    );
    if (!pnpmWithinEngineRange) {
      throw new Error(
        `The version of pnpm specified in package.json#packageManager (${validatedCorepackPackageManager.packageVersion}) must satisfy the version range in package.json#engines.pnpm (${enginesPnpmVersionRange}).`
      );
    }
  }
  if (lockfileVersion) {
    const lockfileValid = validLockfileForPackageManager(
      cliType,
      lockfileVersion,
      validatedCorepackPackageManager.packageVersion
    );
    if (!lockfileValid) {
      throw new Error(
        `Detected lockfile "${lockfileVersion}" which is not compatible with the intended corepack package manager "${corepackPackageManager}". Update your lockfile or change to a compatible corepack version.`
      );
    }
  }
}
function validateVersionSpecifier(version) {
  if (!version) {
    return void 0;
  }
  const [before, after, ...extra] = version.split("@");
  if (extra.length) {
    return void 0;
  }
  if (!before) {
    return void 0;
  }
  if (!after) {
    return void 0;
  }
  const packageVersion = (0, import_semver.parse)(after);
  if (!packageVersion) {
    return void 0;
  }
  return {
    packageName: before,
    packageVersion
  };
}
function detectPackageManager(cliType, lockfileVersion, projectCreatedAt) {
  switch (cliType) {
    case "npm":
      return void 0;
    case "pnpm":
      switch (detectPnpmVersion(lockfileVersion, projectCreatedAt)) {
        case "pnpm 7":
          return {
            path: "/pnpm7/node_modules/.bin",
            detectedLockfile: "pnpm-lock.yaml",
            detectedPackageManager: "pnpm@7.x",
            pnpmVersionRange: "7.x"
          };
        case "pnpm 8":
          return {
            path: "/pnpm8/node_modules/.bin",
            detectedLockfile: "pnpm-lock.yaml",
            detectedPackageManager: "pnpm@8.x",
            pnpmVersionRange: "8.x"
          };
        case "pnpm 9":
          return {
            path: "/pnpm9/node_modules/.bin",
            detectedLockfile: "pnpm-lock.yaml",
            detectedPackageManager: "pnpm@9.x",
            pnpmVersionRange: "9.x"
          };
        case "pnpm 10":
          return {
            path: "/pnpm10/node_modules/.bin",
            detectedLockfile: "pnpm-lock.yaml",
            detectedPackageManager: "pnpm@10.x",
            pnpmVersionRange: "10.x"
          };
        case "pnpm 6":
          return {
            path: "/pnpm6/node_modules/.bin",
            detectedLockfile: "pnpm-lock.yaml",
            detectedPackageManager: "pnpm@6.x",
            pnpmVersionRange: "6.x"
          };
        default:
          return void 0;
      }
    case "bun":
      return {
        path: "/bun1",
        detectedLockfile: lockfileVersion === 0 ? "bun.lockb" : "bun.lock",
        detectedPackageManager: "bun@1.x"
      };
    case "yarn":
      return {
        path: void 0,
        detectedLockfile: "yarn.lock",
        detectedPackageManager: detectYarnVersion(lockfileVersion)
      };
    case "vlt":
      return {
        path: void 0,
        detectedLockfile: "vlt-lock.json",
        detectedPackageManager: "vlt@0.x"
      };
  }
}
function getPathForPackageManager({
  cliType,
  lockfileVersion,
  env
}) {
  const corepackEnabled = env.ENABLE_EXPERIMENTAL_COREPACK === "1";
  let overrides = getPathOverrideForPackageManager({
    cliType,
    lockfileVersion,
    corepackPackageManager: void 0
  });
  if (corepackEnabled) {
    overrides = NO_OVERRIDE;
  }
  const alreadyInPath = (newPath) => {
    const oldPath = env.PATH ?? "";
    return oldPath.split(import_path.default.delimiter).includes(newPath);
  };
  switch (true) {
    case (cliType === "yarn" && !env.YARN_NODE_LINKER):
      return { ...overrides, yarnNodeLinker: "node-modules" };
    case alreadyInPath(overrides.path ?? ""):
      return {
        detectedLockfile: void 0,
        detectedPackageManager: void 0,
        path: void 0,
        yarnNodeLinker: void 0
      };
    default:
      return { ...overrides, yarnNodeLinker: void 0 };
  }
}
async function runCustomInstallCommand({
  destPath,
  installCommand,
  spawnOpts,
  projectCreatedAt
}) {
  const normalizedPath = import_path.default.normalize(destPath);
  const { alreadyInstalled, runNpmInstallSet } = checkIfAlreadyInstalled(
    customInstallCommandSet,
    normalizedPath
  );
  customInstallCommandSet = runNpmInstallSet;
  if (alreadyInstalled) {
    (0, import_debug.default)(
      `Skipping custom install command for ${normalizedPath} because it was already run`
    );
    return false;
  }
  if (process.env.VERCEL_INSTALL_COMPLETED === "1") {
    (0, import_debug.default)(
      `Skipping custom install command for ${normalizedPath} because VERCEL_INSTALL_COMPLETED is set`
    );
    return false;
  }
  console.log(`Running "install" command: \`${installCommand}\`...`);
  const {
    cliType,
    lockfileVersion,
    packageJson,
    packageJsonPackageManager,
    turboSupportsCorepackHome
  } = await scanParentDirs(destPath, true);
  const env = getEnvForPackageManager({
    cliType,
    lockfileVersion,
    packageJsonPackageManager,
    env: spawnOpts?.env || {},
    packageJsonEngines: packageJson?.engines,
    turboSupportsCorepackHome,
    projectCreatedAt
  });
  (0, import_debug.default)(`Running with $PATH:`, env?.PATH || "");
  await execCommand(installCommand, {
    ...spawnOpts,
    env,
    cwd: destPath
  });
  return true;
}
async function runPackageJsonScript(destPath, scriptNames, spawnOpts, projectCreatedAt) {
  (0, import_assert.default)(import_path.default.isAbsolute(destPath));
  const {
    packageJson,
    cliType,
    lockfileVersion,
    packageJsonPackageManager,
    turboSupportsCorepackHome
  } = await scanParentDirs(destPath, true);
  const scriptName = getScriptName(
    packageJson,
    typeof scriptNames === "string" ? [scriptNames] : scriptNames
  );
  if (!scriptName)
    return false;
  (0, import_debug.default)("Running user script...");
  const runScriptTime = Date.now();
  const opts = {
    cwd: destPath,
    ...spawnOpts,
    env: getEnvForPackageManager({
      cliType,
      lockfileVersion,
      packageJsonPackageManager,
      env: (0, import_clone_env.cloneEnv)(process.env, spawnOpts?.env),
      packageJsonEngines: packageJson?.engines,
      turboSupportsCorepackHome,
      projectCreatedAt
    })
  };
  if (cliType === "npm") {
    opts.prettyCommand = `npm run ${scriptName}`;
  } else if (cliType === "pnpm") {
    opts.prettyCommand = `pnpm run ${scriptName}`;
  } else if (cliType === "bun") {
    opts.prettyCommand = `bun run ${scriptName}`;
  } else if (cliType === "vlt") {
    opts.prettyCommand = `vlt run ${scriptName}`;
  } else {
    opts.prettyCommand = `yarn run ${scriptName}`;
  }
  console.log(`Running "${opts.prettyCommand}"`);
  await spawnAsync(cliType, ["run", scriptName], opts);
  (0, import_debug.default)(`Script complete [${Date.now() - runScriptTime}ms]`);
  return true;
}
async function runBundleInstall(destPath, args = [], spawnOpts, meta) {
  if (meta && meta.isDev) {
    (0, import_debug.default)("Skipping dependency installation because dev mode is enabled");
    return;
  }
  (0, import_assert.default)(import_path.default.isAbsolute(destPath));
  const opts = { ...spawnOpts, cwd: destPath, prettyCommand: "bundle install" };
  await spawnAsync("bundle", args.concat(["install"]), opts);
}
async function runPipInstall(destPath, args = [], spawnOpts, meta) {
  if (meta && meta.isDev) {
    (0, import_debug.default)("Skipping dependency installation because dev mode is enabled");
    return { installed: false };
  }
  (0, import_assert.default)(import_path.default.isAbsolute(destPath));
  const targetDir = import_path.default.join(destPath, ".vercel_python_packages");
  const opts = {
    ...spawnOpts,
    cwd: destPath,
    prettyCommand: "uv pip install"
  };
  await spawnAsync(
    "uv",
    ["pip", "install", "--target", targetDir, ...args],
    opts
  );
  return { installed: true, targetDir };
}
function getScriptName(pkg, possibleNames) {
  if (pkg?.scripts) {
    for (const name of possibleNames) {
      if (name in pkg.scripts) {
        return name;
      }
    }
  }
  return void 0;
}
const installDependencies = (0, import_util.deprecate)(
  runNpmInstall,
  "installDependencies() is deprecated. Please use runNpmInstall() instead."
);
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  PNPM_10_PREFERRED_AT,
  detectPackageManager,
  execCommand,
  findPackageJson,
  getEnvForPackageManager,
  getNodeBinPath,
  getNodeBinPaths,
  getNodeVersion,
  getPathForPackageManager,
  getPathOverrideForPackageManager,
  getScriptName,
  getSpawnOptions,
  installDependencies,
  resetCustomInstallCommandSet,
  runBundleInstall,
  runCustomInstallCommand,
  runNpmInstall,
  runPackageJsonScript,
  runPipInstall,
  runShellScript,
  scanParentDirs,
  spawnAsync,
  spawnCommand,
  traverseUpDirectories,
  turboVersionSpecifierSupportsCorepack,
  usingCorepack,
  walkParentDirs
});
