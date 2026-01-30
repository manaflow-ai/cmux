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
exports.initializeRuntime = exports.funCacheDir = exports.runtimes = void 0;
const node_path_1 = require("node:path");
const debug_1 = __importDefault(require("debug"));
const xdg_app_paths_1 = __importDefault(require("xdg-app-paths"));
const node_crypto_1 = require("node:crypto");
const promises_1 = require("node:fs/promises");
const go1x = __importStar(require("./runtimes/go1.x"));
const nodejs6 = __importStar(require("./runtimes/nodejs6.10"));
const nodejs8 = __importStar(require("./runtimes/nodejs8.10"));
const nodejs10 = __importStar(require("./runtimes/nodejs10.x"));
const nodejs12 = __importStar(require("./runtimes/nodejs12.x"));
const nodejs14 = __importStar(require("./runtimes/nodejs14.x"));
const python27 = __importStar(require("./runtimes/python2.7"));
const python3 = __importStar(require("./runtimes/python3"));
const python36 = __importStar(require("./runtimes/python3.6"));
const python37 = __importStar(require("./runtimes/python3.7"));
const debug = (0, debug_1.default)('@vercel/fun:runtimes');
const runtimesDir = (0, node_path_1.join)(__dirname, 'runtimes');
exports.runtimes = {};
exports.funCacheDir = (0, xdg_app_paths_1.default)('com.vercel.fun').cache();
function createRuntime(runtimes, name, mod) {
    const runtime = Object.assign({ name, runtimeDir: (0, node_path_1.join)(runtimesDir, name) }, mod);
    runtimes[name] = runtime;
}
createRuntime(exports.runtimes, 'executable');
createRuntime(exports.runtimes, 'provided');
createRuntime(exports.runtimes, 'go1.x', go1x);
createRuntime(exports.runtimes, 'nodejs');
createRuntime(exports.runtimes, 'nodejs6.10', nodejs6);
createRuntime(exports.runtimes, 'nodejs8.10', nodejs8);
createRuntime(exports.runtimes, 'nodejs10.x', nodejs10);
createRuntime(exports.runtimes, 'nodejs12.x', nodejs12);
createRuntime(exports.runtimes, 'nodejs14.x', nodejs14);
createRuntime(exports.runtimes, 'python');
createRuntime(exports.runtimes, 'python2.7', python27);
createRuntime(exports.runtimes, 'python3', python3);
createRuntime(exports.runtimes, 'python3.6', python36);
createRuntime(exports.runtimes, 'python3.7', python37);
/**
 * Reads the file path `f` as an ascii string.
 * Returns `null` if the file does not exist.
 */
function getCachedRuntimeSha(f) {
    return __awaiter(this, void 0, void 0, function* () {
        try {
            return yield (0, promises_1.readFile)(f, 'ascii');
        }
        catch (err) {
            if (err.code === 'ENOENT') {
                return null;
            }
            throw err;
        }
    });
}
const runtimeShaPromises = new Map();
/**
 * Calculates a sha256 of the files provided for a runtime. If any of the
 * `bootstrap` or other dependent files change then the shasum will be
 * different and the user's existing runtime cache will be invalidated.
 */
function _calculateRuntimeSha(src) {
    return __awaiter(this, void 0, void 0, function* () {
        debug('calculateRuntimeSha(%o)', src);
        const hash = (0, node_crypto_1.createHash)('sha256');
        yield calculateRuntimeShaDir(src, hash);
        const sha = hash.digest('hex');
        debug('Calculated runtime sha for %o: %o', src, sha);
        return sha;
    });
}
function calculateRuntimeShaDir(src, hash) {
    return __awaiter(this, void 0, void 0, function* () {
        const entries = yield (0, promises_1.readdir)(src);
        for (const entry of entries) {
            const srcPath = (0, node_path_1.join)(src, entry);
            const s = yield (0, promises_1.lstat)(srcPath);
            if (s.isDirectory()) {
                yield calculateRuntimeShaDir(srcPath, hash);
            }
            else {
                const contents = yield (0, promises_1.readFile)(srcPath);
                hash.update(contents);
            }
        }
    });
}
function calculateRuntimeSha(src) {
    // The sha calculation promise gets memoized because the runtime code
    // won't be changing (it's within a published npm module, after all)
    let p = runtimeShaPromises.get(src);
    if (!p) {
        p = _calculateRuntimeSha(src);
        runtimeShaPromises.set(src, p);
    }
    return p;
}
/**
 * Until https://github.com/zeit/pkg/issues/639 is resolved, we have to
 * implement the `copy()` operation without relying on `fs.copyFile()`.
 */
function copy(src, dest) {
    return __awaiter(this, void 0, void 0, function* () {
        debug('copy(%o, %o)', src, dest);
        const [entries] = yield Promise.all([
            (0, promises_1.readdir)(src),
            (0, promises_1.mkdir)(dest, { recursive: true })
        ]);
        debug('Entries: %o', entries);
        for (const entry of entries) {
            const srcPath = (0, node_path_1.join)(src, entry);
            const destPath = (0, node_path_1.join)(dest, entry);
            const s = yield (0, promises_1.lstat)(srcPath);
            if (s.isDirectory()) {
                yield copy(srcPath, destPath);
            }
            else {
                const contents = yield (0, promises_1.readFile)(srcPath);
                yield (0, promises_1.writeFile)(destPath, contents, { mode: s.mode });
            }
        }
    });
}
// The Promises map is to ensure that a runtime is only initialized once
const initPromises = new Map();
function _initializeRuntime(runtime) {
    return __awaiter(this, void 0, void 0, function* () {
        const cacheDir = (0, node_path_1.join)(exports.funCacheDir, 'runtimes', runtime.name);
        const cacheShaFile = (0, node_path_1.join)(cacheDir, '.cache-sha');
        const [cachedRuntimeSha, runtimeSha] = yield Promise.all([
            getCachedRuntimeSha(cacheShaFile),
            calculateRuntimeSha(runtime.runtimeDir)
        ]);
        runtime.cacheDir = cacheDir;
        if (cachedRuntimeSha === runtimeSha) {
            debug('Runtime %o is already initialized at %o', runtime.name, cacheDir);
        }
        else {
            debug('Initializing %o runtime at %o', runtime.name, cacheDir);
            try {
                yield (0, promises_1.mkdir)(cacheDir, { recursive: true });
                // The runtime directory is copied from the module dir to the cache
                // dir. This is so that when compiled through `pkg`, then the
                // bootstrap files exist on a real file system so that `execve()`
                // works as expected.
                yield copy(runtime.runtimeDir, cacheDir);
                // Perform any runtime-specific initialization logic
                if (typeof runtime.init === 'function') {
                    yield runtime.init(runtime);
                }
                yield (0, promises_1.writeFile)((0, node_path_1.join)(cacheDir, '.cache-sha'), runtimeSha);
            }
            catch (err) {
                debug('Runtime %o `init()` failed %o. Cleaning up cache dir %o', runtime.name, err, cacheDir);
                try {
                    yield (0, promises_1.rm)(cacheDir, { recursive: true });
                }
                catch (err2) {
                    debug('Cleaning up cache dir failed: %o', err2);
                }
                throw err;
            }
        }
    });
}
function initializeRuntime(target) {
    return __awaiter(this, void 0, void 0, function* () {
        let runtime;
        if (typeof target === 'string') {
            runtime = exports.runtimes[target];
            if (!runtime) {
                throw new Error(`Could not find runtime with name "${target}"`);
            }
        }
        else {
            runtime = target;
        }
        let p = initPromises.get(runtime);
        if (p) {
            yield p;
        }
        else {
            p = _initializeRuntime(runtime);
            initPromises.set(runtime, p);
            try {
                yield p;
            }
            finally {
                // Once the initialization is complete, remove the Promise. This is so that
                // in case the cache is deleted during runtime, and then another Lambda
                // function is created, the in-memory cache doesn't think the runtime is
                // already initialized and will check the filesystem cache again.
                initPromises.delete(runtime);
            }
        }
        return runtime;
    });
}
exports.initializeRuntime = initializeRuntime;
//# sourceMappingURL=runtimes.js.map