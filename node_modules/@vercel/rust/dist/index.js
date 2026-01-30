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

// src/index.ts
var src_exports = {};
__export(src_exports, {
  build: () => build,
  prepareCache: () => prepareCache,
  shouldServe: () => shouldServe,
  startDevServer: () => startDevServer2,
  version: () => version
});
module.exports = __toCommonJS(src_exports);
var import_node_path4 = __toESM(require("path"));
var import_build_utils6 = require("@vercel/build-utils");
var import_execa4 = __toESM(require("execa"));

// src/lib/rust-toolchain.ts
var import_build_utils = require("@vercel/build-utils");
var import_execa = __toESM(require("execa"));
async function downloadRustToolchain() {
  try {
    await (0, import_execa.default)(
      `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y`,
      [],
      { shell: true, stdio: "inherit" }
    );
  } catch (err) {
    let message = "Unknown Error";
    if (err instanceof Error) {
      message = err.message;
    }
    throw new Error(`Installing Rust Toolchain via rustup failed: ${message}`);
  }
}
var installRustToolchain = async () => {
  try {
    await (0, import_execa.default)(`rustup -V`, [], { shell: true, stdio: "ignore" });
    (0, import_build_utils.debug)("Rust Toolchain is already installed, skipping download");
  } catch (err) {
    await downloadRustToolchain();
  }
};

// src/lib/cargo.ts
var import_node_fs = __toESM(require("fs"));
var import_node_path = __toESM(require("path"));
var import_toml = __toESM(require("@iarna/toml"));
var import_execa2 = __toESM(require("execa"));
async function getCargoMetadata(options) {
  const { stdout: cargoMetaData } = await (0, import_execa2.default)(
    "cargo",
    ["metadata", "--format-version", "1"],
    options
  );
  return JSON.parse(cargoMetaData);
}
async function findCargoWorkspace(config) {
  const { stdout: projectDescriptionStr } = await (0, import_execa2.default)(
    "cargo",
    ["locate-project"],
    config
  );
  const projectDescription = JSON.parse(projectDescriptionStr);
  return {
    toml: await import_toml.default.parse.stream(import_node_fs.default.createReadStream(projectDescription.root)),
    root: projectDescription.root
  };
}
async function findCargoBuildConfiguration(workspace) {
  const configPath = import_node_path.default.join(
    import_node_path.default.dirname(workspace.root),
    ".cargo/config.toml"
  );
  if (!import_node_fs.default.existsSync(configPath)) {
    return null;
  }
  const config = await import_toml.default.parse.stream(import_node_fs.default.createReadStream(configPath));
  return config;
}
function findBinaryName(workspace, entryPath) {
  const { bin } = workspace.toml;
  if (bin) {
    const relativePath = import_node_path.default.relative(import_node_path.default.dirname(workspace.root), entryPath);
    const entry = bin.find((binEntry) => binEntry.path === relativePath);
    if (entry?.name) {
      return entry.name;
    }
  }
  return import_node_path.default.basename(entryPath, ".rs").replace("[", "_").replace("]", "_");
}

// src/lib/utils.ts
var import_node_fs2 = __toESM(require("fs"));
var import_node_path2 = __toESM(require("path"));
var import_build_utils2 = require("@vercel/build-utils");
function getExecutableName(binName) {
  return process.platform === "win32" ? `${binName}.exe` : binName;
}
function assertEnv(name) {
  if (!process.env[name]) {
    throw new Error(`Missing ENV variable process.env.${name}`);
  }
  return process.env[name];
}
async function runUserScripts(dir) {
  const buildScriptPath = import_node_path2.default.join(dir, "build.sh");
  const buildScriptExists = import_node_fs2.default.existsSync(buildScriptPath);
  if (buildScriptExists) {
    (0, import_build_utils2.debug)("Running `build.sh`");
    await (0, import_build_utils2.runShellScript)(buildScriptPath);
  }
}
async function gatherExtraFiles(globMatcher, workPath) {
  if (!globMatcher)
    return {};
  (0, import_build_utils2.debug)(
    `Gathering extra files for glob \`${JSON.stringify(
      globMatcher
    )}\` in ${workPath}`
  );
  if (Array.isArray(globMatcher)) {
    const allMatches = await Promise.all(
      globMatcher.map((pattern) => (0, import_build_utils2.glob)(pattern, workPath))
    );
    return allMatches.reduce((acc, matches) => ({ ...acc, ...matches }), {});
  }
  return (0, import_build_utils2.glob)(globMatcher, workPath);
}

// src/lib/start-dev-server.ts
var import_child_process = require("child_process");
var import_events = require("events");
var import_build_utils5 = require("@vercel/build-utils");

// src/lib/dev-build.ts
var import_node_path3 = __toESM(require("path"));
var import_execa3 = __toESM(require("execa"));
var import_build_utils3 = require("@vercel/build-utils");
async function buildExecutableForDev(workPath, entrypoint) {
  (0, import_build_utils3.debug)(`Building executable for development: ${entrypoint}`);
  const HOME = process.platform === "win32" ? assertEnv("USERPROFILE") : assertEnv("HOME");
  const PATH = assertEnv("PATH");
  const rustEnv = {
    PATH: `${import_node_path3.default.join(HOME, ".cargo/bin")}${import_node_path3.default.delimiter}${PATH}`,
    RUSTFLAGS: [process.env.RUSTFLAGS].filter(Boolean).join(" ")
  };
  const entryPath = import_node_path3.default.join(workPath, entrypoint);
  const cargoWorkspace = await findCargoWorkspace({
    env: rustEnv,
    cwd: import_node_path3.default.dirname(entryPath)
  });
  const binaryName = findBinaryName(cargoWorkspace, entryPath);
  (0, import_build_utils3.debug)(`Building binary "${binaryName}" in debug mode for dev server`);
  try {
    await (0, import_execa3.default)(
      "cargo",
      [
        "build",
        "--bin",
        binaryName,
        "--message-format=json-diagnostic-rendered-ansi"
      ],
      {
        cwd: workPath,
        env: rustEnv,
        stdio: "pipe"
      }
    );
  } catch (err) {
    (0, import_build_utils3.debug)(`Cargo build failed for ${binaryName}`);
    throw new Error(`Failed to build Rust binary for development: ${err}`);
  }
  const { target_directory: targetDirectory } = await getCargoMetadata({
    cwd: workPath,
    env: rustEnv
  });
  const executablePath = import_node_path3.default.join(
    targetDirectory,
    "debug",
    getExecutableName(binaryName)
  );
  (0, import_build_utils3.debug)(`Built executable at: ${executablePath}`);
  return executablePath;
}

// src/lib/dev-server.ts
var import_build_utils4 = require("@vercel/build-utils");
function createDevServerEnv(baseEnv, meta = {}) {
  const devEnv = {
    // Base environment
    ...Object.fromEntries(
      Object.entries(baseEnv).filter(([, value]) => value !== void 0)
    ),
    // Development-specific variables
    VERCEL_DEV: "1",
    RUST_LOG: process.env.RUST_LOG || "info",
    // Runtime environment from meta
    ...meta.env || {}
  };
  Object.keys(devEnv).forEach((key) => {
    if (devEnv[key] === void 0) {
      delete devEnv[key];
    }
  });
  (0, import_build_utils4.debug)(`Dev server environment: ${Object.keys(devEnv).join(", ")}`);
  return devEnv;
}

// src/lib/start-dev-server.ts
var startDevServer = async (opts) => {
  const { entrypoint, workPath, meta = {} } = opts;
  try {
    await installRustToolchain();
    const executablePath = await buildExecutableForDev(workPath, entrypoint);
    (0, import_build_utils5.debug)(`Starting Rust dev server: ${executablePath}`);
    const devEnv = createDevServerEnv(process.env, meta);
    const child = (0, import_child_process.spawn)(executablePath, [], {
      cwd: workPath,
      env: devEnv,
      stdio: ["pipe", "pipe", "pipe"]
    });
    if (!child.pid) {
      throw new Error("Failed to start dev server process");
    }
    (0, import_build_utils5.debug)(`Dev server process started with PID: ${child.pid}`);
    let buffer = "";
    let portEmitted = false;
    child.stdout?.on("data", (data) => {
      const output = data.toString();
      buffer += output;
      if (!portEmitted && buffer.includes("Dev server listening:")) {
        const portMatch = buffer.match(/Dev server listening: (\d+)/);
        if (portMatch) {
          const port = parseInt(portMatch[1], 10);
          (0, import_build_utils5.debug)(
            `Rust dev server detected port ${port}, emitting message event`
          );
          child.emit("message", { port }, null);
          portEmitted = true;
        }
        buffer = "";
      }
      console.log(output);
    });
    child.stderr?.on("data", (data) => {
      console.error(data.toString());
    });
    child.on("error", (err) => {
      (0, import_build_utils5.debug)(`Dev server error: ${err}`);
    });
    child.on("exit", (code, signal) => {
      (0, import_build_utils5.debug)(`Dev server exited with code ${code}, signal ${signal}`);
    });
    const onMessage = (0, import_events.once)(child, "message");
    const onExit = (0, import_events.once)(child, "close");
    const result = await Promise.race([
      onMessage.then((args) => {
        const [messageData] = args;
        return { state: "message", value: messageData };
      }),
      onExit.then((args) => {
        const [code, signal] = args;
        return { state: "exit", value: [code, signal] };
      })
    ]);
    if (result.state === "message") {
      const { port } = result.value;
      (0, import_build_utils5.debug)(`Rust dev server ready on port ${port}`);
      if (!child.pid) {
        throw new Error("Child process has no PID");
      }
      const shutdown = async () => {
        try {
          process.kill(child.pid, "SIGTERM");
        } catch (err) {
          (0, import_build_utils5.debug)(`Error terminating Rust dev server: ${err}`);
        }
      };
      return { port, pid: child.pid, shutdown };
    } else {
      const [exitCode, signal] = result.value;
      const reason = signal ? `"${signal}" signal` : `exit code ${exitCode}`;
      throw new Error(`Rust dev server failed with ${reason}`);
    }
  } catch (error) {
    (0, import_build_utils5.debug)(`Failed to start dev server: ${error}`);
    return null;
  }
};

// src/index.ts
async function buildHandler(options) {
  const BUILDER_DEBUG = Boolean(process.env.VERCEL_BUILDER_DEBUG ?? false);
  const isVercelBuild = Boolean(process.env.VERCEL_BUILD_IMAGE ?? false);
  const { files, entrypoint, workPath, config, meta } = options;
  const crossCompilationEnabled = !isVercelBuild && !meta?.isDev;
  if (crossCompilationEnabled && process.platform === "win32") {
    throw new Error(
      "Production prebuilt deployments for @vercel/rust are not yet supported on Windows. Please use a Linux or macOS environment, or deploy directly on Vercel."
    );
  }
  await installRustToolchain();
  (0, import_build_utils6.debug)("Creating file system");
  const downloadedFiles = await (0, import_build_utils6.download)(files, workPath, meta);
  const entryPath = downloadedFiles[entrypoint].fsPath;
  const HOME = process.platform === "win32" ? assertEnv("USERPROFILE") : assertEnv("HOME");
  const PATH = assertEnv("PATH");
  const rustEnv = {
    PATH: `${import_node_path4.default.join(HOME, ".cargo/bin")}${import_node_path4.default.delimiter}${PATH}`,
    RUSTFLAGS: [process.env.RUSTFLAGS].filter(Boolean).join(" ")
  };
  const cargoWorkspace = await findCargoWorkspace({
    env: rustEnv,
    cwd: import_node_path4.default.dirname(entryPath)
  });
  const binaryName = findBinaryName(cargoWorkspace, entryPath);
  const cargoBuildConfiguration = await findCargoBuildConfiguration(cargoWorkspace);
  await runUserScripts(workPath);
  const extraFiles = await gatherExtraFiles(config.includeFiles, workPath);
  const lambdaOptions = await (0, import_build_utils6.getLambdaOptionsFromFunction)({
    sourceFile: entrypoint,
    config
  });
  const architecture = lambdaOptions?.architecture || "x86_64";
  const buildVariant = meta?.isDev ? "debug" : "release";
  const buildTarget = cargoBuildConfiguration?.build.target ?? "";
  try {
    const args = crossCompilationEnabled ? [
      "zigbuild",
      "--target",
      architecture === "x86_64" ? "x86_64-unknown-linux-gnu" : "aarch64-unknown-linux-gnu",
      "--bin",
      binaryName
    ].concat(BUILDER_DEBUG ? ["--verbose"] : ["--quiet"], ["--release"]) : ["build", "--bin", binaryName].concat(
      BUILDER_DEBUG ? ["--verbose"] : ["--quiet"],
      meta?.isDev ? [] : ["--release"]
    );
    (0, import_build_utils6.debug)(
      `Running \`cargo build\` for \`${binaryName}\` (\`${architecture}\`)`
    );
    await (0, import_execa4.default)("cargo", args, {
      cwd: workPath,
      env: rustEnv
    });
  } catch (err) {
    (0, import_build_utils6.debug)(`Running \`cargo build\` for \`${binaryName}\` failed`);
    throw err;
  }
  (0, import_build_utils6.debug)(
    `Building \`${binaryName}\` for \`${process.platform}\` (\`${architecture}\`) completed`
  );
  let { target_directory: targetDirectory } = await getCargoMetadata({
    cwd: workPath,
    env: rustEnv
  });
  if (crossCompilationEnabled) {
    targetDirectory = import_node_path4.default.join(
      targetDirectory,
      architecture === "x86_64" ? "x86_64-unknown-linux-gnu" : "aarch64-unknown-linux-gnu"
    );
  }
  targetDirectory = import_node_path4.default.join(targetDirectory, buildTarget);
  const bin = import_node_path4.default.join(
    targetDirectory,
    buildVariant,
    getExecutableName(binaryName)
  );
  const handler = getExecutableName("executable");
  const executableFile = new import_build_utils6.FileFsRef({ mode: 493, fsPath: bin });
  const lambda = new import_build_utils6.Lambda({
    ...lambdaOptions,
    files: {
      ...extraFiles,
      [handler]: executableFile
    },
    handler,
    supportsResponseStreaming: true,
    architecture,
    runtime: "executable",
    runtimeLanguage: "rust"
  });
  lambda.zipBuffer = await lambda.createZip();
  (0, import_build_utils6.debug)(`generating function for \`${entrypoint}\``);
  return {
    output: lambda
  };
}
var runtime = {
  version: 3,
  build: buildHandler,
  prepareCache: async ({ workPath }) => {
    (0, import_build_utils6.debug)(`Caching \`${workPath}\``);
    const cacheFiles = await (0, import_build_utils6.glob)("target/**", workPath);
    for (const f of Object.keys(cacheFiles)) {
      const accept = /(?:^|\/)target\/release\/\.fingerprint\//.test(f) || /(?:^|\/)target\/release\/build\//.test(f) || /(?:^|\/)target\/release\/deps\//.test(f) || /(?:^|\/)target\/debug\/\.fingerprint\//.test(f) || /(?:^|\/)target\/debug\/build\//.test(f) || /(?:^|\/)target\/debug\/deps\//.test(f);
      if (!accept) {
        delete cacheFiles[f];
      }
    }
    return cacheFiles;
  },
  startDevServer,
  shouldServe: async (options) => {
    (0, import_build_utils6.debug)(`Requested ${options.requestPath} for ${options.entrypoint}`);
    return Promise.resolve(options.requestPath === options.entrypoint);
  }
};
var { version, build, prepareCache, startDevServer: startDevServer2, shouldServe } = runtime;
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  build,
  prepareCache,
  shouldServe,
  startDevServer,
  version
});
