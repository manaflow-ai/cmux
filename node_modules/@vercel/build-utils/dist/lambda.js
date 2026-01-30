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
var lambda_exports = {};
__export(lambda_exports, {
  Lambda: () => Lambda,
  createLambda: () => createLambda,
  createZip: () => createZip,
  getLambdaOptionsFromFunction: () => getLambdaOptionsFromFunction
});
module.exports = __toCommonJS(lambda_exports);
var import_assert = __toESM(require("assert"));
var import_async_sema = __toESM(require("async-sema"));
var import_yazl = require("yazl");
var import_minimatch = __toESM(require("minimatch"));
var import_fs_extra = require("fs-extra");
var import_download = require("./fs/download");
var import_stream_to_buffer = __toESM(require("./fs/stream-to-buffer"));
function getDefaultLambdaArchitecture(architecture) {
  if (architecture) {
    return architecture;
  }
  switch (process.arch) {
    case "arm":
    case "arm64": {
      return "arm64";
    }
    default: {
      return "x86_64";
    }
  }
}
class Lambda {
  constructor(opts) {
    const {
      handler,
      runtime,
      runtimeLanguage,
      maxDuration,
      architecture,
      memory,
      environment = {},
      allowQuery,
      regions,
      supportsMultiPayloads,
      supportsWrapper,
      supportsResponseStreaming,
      experimentalResponseStreaming,
      operationType,
      framework,
      experimentalTriggers,
      supportsCancellation,
      shouldDisableAutomaticFetchInstrumentation
    } = opts;
    if ("files" in opts) {
      (0, import_assert.default)(typeof opts.files === "object", '"files" must be an object');
    }
    if ("zipBuffer" in opts) {
      (0, import_assert.default)(Buffer.isBuffer(opts.zipBuffer), '"zipBuffer" must be a Buffer');
    }
    (0, import_assert.default)(typeof handler === "string", '"handler" is not a string');
    (0, import_assert.default)(typeof runtime === "string", '"runtime" is not a string');
    (0, import_assert.default)(typeof environment === "object", '"environment" is not an object');
    if (architecture !== void 0) {
      (0, import_assert.default)(
        architecture === "x86_64" || architecture === "arm64",
        '"architecture" must be either "x86_64" or "arm64"'
      );
    }
    if (runtimeLanguage !== void 0) {
      (0, import_assert.default)(
        runtimeLanguage === "rust" || runtimeLanguage === "go",
        '"runtimeLanguage" is invalid. Valid options: "rust", "go"'
      );
    }
    if ("experimentalAllowBundling" in opts && opts.experimentalAllowBundling !== void 0) {
      (0, import_assert.default)(
        typeof opts.experimentalAllowBundling === "boolean",
        '"experimentalAllowBundling" is not a boolean'
      );
    }
    if (memory !== void 0) {
      (0, import_assert.default)(typeof memory === "number", '"memory" is not a number');
    }
    if (maxDuration !== void 0) {
      (0, import_assert.default)(typeof maxDuration === "number", '"maxDuration" is not a number');
    }
    if (allowQuery !== void 0) {
      (0, import_assert.default)(Array.isArray(allowQuery), '"allowQuery" is not an Array');
      (0, import_assert.default)(
        allowQuery.every((q) => typeof q === "string"),
        '"allowQuery" is not a string Array'
      );
    }
    if (supportsMultiPayloads !== void 0) {
      (0, import_assert.default)(
        typeof supportsMultiPayloads === "boolean",
        '"supportsMultiPayloads" is not a boolean'
      );
    }
    if (supportsWrapper !== void 0) {
      (0, import_assert.default)(
        typeof supportsWrapper === "boolean",
        '"supportsWrapper" is not a boolean'
      );
    }
    if (regions !== void 0) {
      (0, import_assert.default)(Array.isArray(regions), '"regions" is not an Array');
      (0, import_assert.default)(
        regions.every((r) => typeof r === "string"),
        '"regions" is not a string Array'
      );
    }
    if (framework !== void 0) {
      (0, import_assert.default)(typeof framework === "object", '"framework" is not an object');
      (0, import_assert.default)(
        typeof framework.slug === "string",
        '"framework.slug" is not a string'
      );
      if (framework.version !== void 0) {
        (0, import_assert.default)(
          typeof framework.version === "string",
          '"framework.version" is not a string'
        );
      }
    }
    if (experimentalTriggers !== void 0) {
      (0, import_assert.default)(
        Array.isArray(experimentalTriggers),
        '"experimentalTriggers" is not an Array'
      );
      for (let i = 0; i < experimentalTriggers.length; i++) {
        const trigger = experimentalTriggers[i];
        const prefix = `"experimentalTriggers[${i}]"`;
        (0, import_assert.default)(
          typeof trigger === "object" && trigger !== null,
          `${prefix} is not an object`
        );
        (0, import_assert.default)(
          trigger.type === "queue/v1beta",
          `${prefix}.type must be "queue/v1beta"`
        );
        (0, import_assert.default)(
          typeof trigger.topic === "string",
          `${prefix}.topic is required and must be a string`
        );
        (0, import_assert.default)(trigger.topic.length > 0, `${prefix}.topic cannot be empty`);
        (0, import_assert.default)(
          typeof trigger.consumer === "string",
          `${prefix}.consumer is required and must be a string`
        );
        (0, import_assert.default)(
          trigger.consumer.length > 0,
          `${prefix}.consumer cannot be empty`
        );
        if (trigger.maxDeliveries !== void 0) {
          (0, import_assert.default)(
            typeof trigger.maxDeliveries === "number",
            `${prefix}.maxDeliveries must be a number`
          );
          (0, import_assert.default)(
            Number.isInteger(trigger.maxDeliveries) && trigger.maxDeliveries >= 1,
            `${prefix}.maxDeliveries must be at least 1`
          );
        }
        if (trigger.retryAfterSeconds !== void 0) {
          (0, import_assert.default)(
            typeof trigger.retryAfterSeconds === "number",
            `${prefix}.retryAfterSeconds must be a number`
          );
          (0, import_assert.default)(
            trigger.retryAfterSeconds > 0,
            `${prefix}.retryAfterSeconds must be a positive number`
          );
        }
        if (trigger.initialDelaySeconds !== void 0) {
          (0, import_assert.default)(
            typeof trigger.initialDelaySeconds === "number",
            `${prefix}.initialDelaySeconds must be a number`
          );
          (0, import_assert.default)(
            trigger.initialDelaySeconds >= 0,
            `${prefix}.initialDelaySeconds must be a non-negative number`
          );
        }
        if (trigger.maxConcurrency !== void 0) {
          (0, import_assert.default)(
            typeof trigger.maxConcurrency === "number",
            `${prefix}.maxConcurrency must be a number`
          );
          (0, import_assert.default)(
            Number.isInteger(trigger.maxConcurrency) && trigger.maxConcurrency >= 1,
            `${prefix}.maxConcurrency must be at least 1`
          );
        }
      }
    }
    if (supportsCancellation !== void 0) {
      (0, import_assert.default)(
        typeof supportsCancellation === "boolean",
        '"supportsCancellation" is not a boolean'
      );
    }
    this.type = "Lambda";
    this.operationType = operationType;
    this.files = "files" in opts ? opts.files : void 0;
    this.handler = handler;
    this.runtime = runtime;
    this.runtimeLanguage = runtimeLanguage;
    this.architecture = getDefaultLambdaArchitecture(architecture);
    this.memory = memory;
    this.maxDuration = maxDuration;
    this.environment = environment;
    this.allowQuery = allowQuery;
    this.regions = regions;
    this.zipBuffer = "zipBuffer" in opts ? opts.zipBuffer : void 0;
    this.supportsMultiPayloads = supportsMultiPayloads;
    this.supportsWrapper = supportsWrapper;
    this.supportsResponseStreaming = supportsResponseStreaming ?? experimentalResponseStreaming;
    this.framework = framework;
    this.experimentalAllowBundling = "experimentalAllowBundling" in opts ? opts.experimentalAllowBundling : void 0;
    this.experimentalTriggers = experimentalTriggers;
    this.supportsCancellation = supportsCancellation;
    this.shouldDisableAutomaticFetchInstrumentation = shouldDisableAutomaticFetchInstrumentation;
  }
  async createZip() {
    let { zipBuffer } = this;
    if (!zipBuffer) {
      if (!this.files) {
        throw new Error("`files` is not defined");
      }
      await sema.acquire();
      try {
        zipBuffer = await createZip(this.files);
      } finally {
        sema.release();
      }
    }
    return zipBuffer;
  }
  /**
   * @deprecated Use the `supportsResponseStreaming` property instead.
   */
  get experimentalResponseStreaming() {
    return this.supportsResponseStreaming;
  }
  set experimentalResponseStreaming(v) {
    this.supportsResponseStreaming = v;
  }
}
const sema = new import_async_sema.default(10);
const mtime = /* @__PURE__ */ new Date(154e10);
async function createLambda(opts) {
  const lambda = new Lambda(opts);
  lambda.zipBuffer = await lambda.createZip();
  return lambda;
}
async function createZip(files) {
  const names = Object.keys(files).sort();
  const symlinkTargets = /* @__PURE__ */ new Map();
  for (const name of names) {
    const file = files[name];
    if (file.mode && (0, import_download.isSymbolicLink)(file.mode) && file.type === "FileFsRef") {
      const symlinkTarget = await (0, import_fs_extra.readlink)(file.fsPath);
      symlinkTargets.set(name, symlinkTarget);
    }
  }
  const zipFile = new import_yazl.ZipFile();
  const zipBuffer = await new Promise((resolve, reject) => {
    for (const name of names) {
      const file = files[name];
      const opts = { mode: file.mode, mtime };
      const symlinkTarget = symlinkTargets.get(name);
      if (typeof symlinkTarget === "string") {
        zipFile.addBuffer(Buffer.from(symlinkTarget, "utf8"), name, opts);
      } else if (file.mode && (0, import_download.isDirectory)(file.mode)) {
        zipFile.addEmptyDirectory(name, opts);
      } else {
        const stream = file.toStream();
        stream.on("error", reject);
        zipFile.addReadStream(stream, name, opts);
      }
    }
    zipFile.end();
    (0, import_stream_to_buffer.default)(zipFile.outputStream).then(resolve).catch(reject);
  });
  return zipBuffer;
}
async function getLambdaOptionsFromFunction({
  sourceFile,
  config
}) {
  if (config?.functions) {
    for (const [pattern, fn] of Object.entries(config.functions)) {
      if (sourceFile === pattern || (0, import_minimatch.default)(sourceFile, pattern)) {
        return {
          architecture: fn.architecture,
          memory: fn.memory,
          maxDuration: fn.maxDuration,
          experimentalTriggers: fn.experimentalTriggers,
          supportsCancellation: fn.supportsCancellation
        };
      }
    }
  }
  return {};
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  Lambda,
  createLambda,
  createZip,
  getLambdaOptionsFromFunction
});
