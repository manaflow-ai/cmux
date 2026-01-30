"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || function (mod) {
    if (mod && mod.__esModule) return mod;
    var result = {};
    if (mod != null) for (var k in mod) if (k !== "default" && Object.prototype.hasOwnProperty.call(mod, k)) __createBinding(result, mod, k);
    __setModuleDefault(result, mod);
    return result;
};
var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
};
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.cleanCacheDir = exports.destroy = exports.invoke = exports.createFunction = exports.ValidationError = exports.initializeRuntime = exports.funCacheDir = exports.providers = exports.runtimes = void 0;
const debug_1 = __importDefault(require("debug"));
const promises_1 = require("node:fs/promises");
const unzip_1 = require("./unzip");
const errors_1 = require("./errors");
const providers = __importStar(require("./providers"));
exports.providers = providers;
const runtimes_1 = require("./runtimes");
Object.defineProperty(exports, "funCacheDir", { enumerable: true, get: function () { return runtimes_1.funCacheDir; } });
Object.defineProperty(exports, "runtimes", { enumerable: true, get: function () { return runtimes_1.runtimes; } });
Object.defineProperty(exports, "initializeRuntime", { enumerable: true, get: function () { return runtimes_1.initializeRuntime; } });
const debug = (0, debug_1.default)('@vercel/fun:index');
// Environment variable names that AWS Lambda does not allow to be overridden.
// https://docs.aws.amazon.com/lambda/latest/dg/current-supported-versions.html#lambda-environment-variables
const reservedEnvVars = new Set([
    '_HANDLER',
    'LAMBDA_TASK_ROOT',
    'LAMBDA_RUNTIME_DIR',
    'AWS_EXECUTION_ENV',
    'AWS_DEFAULT_REGION',
    'AWS_REGION',
    'AWS_LAMBDA_LOG_GROUP_NAME',
    'AWS_LAMBDA_LOG_STREAM_NAME',
    'AWS_LAMBDA_FUNCTION_NAME',
    'AWS_LAMBDA_FUNCTION_MEMORY_SIZE',
    'AWS_LAMBDA_FUNCTION_VERSION',
    'AWS_ACCESS_KEY',
    'AWS_ACCESS_KEY_ID',
    'AWS_SECRET_KEY',
    'AWS_SECRET_ACCESS_KEY',
    'AWS_SESSION_TOKEN',
    'TZ'
]);
class ValidationError extends Error {
    constructor(message) {
        super(message);
        // Restore prototype chain (see https://stackoverflow.com/a/41102306/376773)
        this.name = ValidationError.name;
        const actualProto = ValidationError.prototype;
        Object.setPrototypeOf(this, actualProto);
    }
}
exports.ValidationError = ValidationError;
function createFunction(params) {
    return __awaiter(this, void 0, void 0, function* () {
        const Provider = providers[params.Provider || 'native'];
        if (!Provider) {
            throw new TypeError(`Provider "${params.Provider}" is not implemented`);
        }
        const runtime = runtimes_1.runtimes[params.Runtime];
        if (!runtime) {
            throw new TypeError(`Runtime "${params.Runtime}" is not implemented`);
        }
        yield (0, runtimes_1.initializeRuntime)(runtime);
        const envVars = (params.Environment && params.Environment.Variables) || {};
        const reserved = Object.keys(envVars).filter(name => {
            return reservedEnvVars.has(name.toUpperCase());
        });
        if (reserved.length > 0) {
            const err = new ValidationError(`The following environment variables can not be configured: ${reserved.join(', ')}`);
            err.reserved = reserved;
            throw err;
        }
        const fn = function (payload) {
            return __awaiter(this, void 0, void 0, function* () {
                const result = yield fn.invoke({
                    InvocationType: 'RequestResponse',
                    Payload: JSON.stringify(payload)
                });
                let resultPayload = result.Payload;
                if (typeof resultPayload !== 'string') {
                    // For Buffer / Blob
                    resultPayload = String(resultPayload);
                }
                const parsedPayload = JSON.parse(resultPayload);
                if (result.FunctionError) {
                    throw new errors_1.LambdaError(parsedPayload);
                }
                else {
                    return parsedPayload;
                }
            });
        };
        fn.params = params;
        fn.runtime = runtime;
        fn.destroy = destroy.bind(null, fn);
        fn.invoke = invoke.bind(null, fn);
        fn.functionName = params.FunctionName;
        fn.region = params.Region || 'us-west-1';
        fn.version = '$LATEST';
        fn.arn = '';
        fn.timeout = typeof params.Timeout === 'number' ? params.Timeout : 3;
        fn.memorySize =
            typeof params.MemorySize === 'number' ? params.MemorySize : 128;
        debug('Creating provider %o', Provider.name);
        fn.provider = new Provider(fn);
        if (params.Code.ZipFile) {
            fn.extractedDir = yield (0, unzip_1.unzipToTemp)(params.Code.ZipFile);
        }
        return fn;
    });
}
exports.createFunction = createFunction;
function invoke(fn, params) {
    return __awaiter(this, void 0, void 0, function* () {
        debug('Invoking function %o', fn.functionName);
        const result = yield fn.provider.invoke(params);
        return result;
    });
}
exports.invoke = invoke;
function destroy(fn) {
    return __awaiter(this, void 0, void 0, function* () {
        const ops = [fn.provider.destroy()];
        if (fn.extractedDir) {
            debug('Deleting directory %o for function %o', fn.extractedDir, fn.functionName);
            ops.push((0, promises_1.rm)(fn.extractedDir, { recursive: true }));
        }
        yield Promise.all(ops);
    });
}
exports.destroy = destroy;
function cleanCacheDir() {
    return __awaiter(this, void 0, void 0, function* () {
        debug('Deleting fun cache directory %o', runtimes_1.funCacheDir);
        yield (0, promises_1.rm)(runtimes_1.funCacheDir, { recursive: true });
    });
}
exports.cleanCacheDir = cleanCacheDir;
//# sourceMappingURL=index.js.map