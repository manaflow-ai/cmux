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
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.Job = void 0;
exports.nodeFileTrace = nodeFileTrace;
const path_1 = require("path");
const analyze_1 = __importDefault(require("./analyze"));
const resolve_dependency_1 = __importStar(require("./resolve-dependency"));
const picomatch_1 = require("picomatch");
const sharedlib_emit_1 = require("./utils/sharedlib-emit");
const fs_1 = require("./fs");
function inPath(path, parent) {
    const pathWithSep = (0, path_1.join)(parent, path_1.sep);
    return path.startsWith(pathWithSep) && path !== pathWithSep;
}
async function nodeFileTrace(files, opts = {}) {
    const job = new Job(opts);
    if (opts.readFile)
        job.readFile = opts.readFile;
    if (opts.stat)
        job.stat = opts.stat;
    if (opts.readlink)
        job.readlink = opts.readlink;
    if (opts.resolve)
        job.resolve = opts.resolve;
    job.ts = true;
    await Promise.all(files.map(async (file) => {
        const path = (0, path_1.resolve)(file);
        await job.emitFile(path, 'initial');
        return job.emitDependency(path);
    }));
    const result = {
        fileList: job.fileList,
        esmFileList: job.esmFileList,
        reasons: job.reasons,
        warnings: job.warnings,
    };
    return result;
}
class Job {
    ts;
    base;
    cwd;
    conditions;
    exportsOnly;
    paths;
    ignoreFn;
    log;
    mixedModules;
    analysis;
    analysisCache;
    fileList;
    esmFileList;
    processed;
    warnings;
    reasons = new Map();
    cachedFileSystem;
    remappings = new Map();
    constructor({ base = process.cwd(), processCwd, exports, conditions = exports || ['node'], exportsOnly = false, paths = {}, ignore, log = false, mixedModules = false, ts = true, analysis = {}, cache, 
    // we use a default of 1024 concurrency to balance
    // performance and memory usage for fs operations
    fileIOConcurrency = 1024, }) {
        this.ts = ts;
        base = (0, path_1.resolve)(base);
        this.ignoreFn = (path) => {
            if (path.startsWith('..' + path_1.sep))
                return true;
            return false;
        };
        if (typeof ignore === 'string')
            ignore = [ignore];
        if (typeof ignore === 'function') {
            const ig = ignore;
            this.ignoreFn = (path) => {
                if (path.startsWith('..' + path_1.sep))
                    return true;
                if (ig(path))
                    return true;
                return false;
            };
        }
        else if (Array.isArray(ignore)) {
            const resolvedIgnores = ignore.map((ignore) => (0, path_1.relative)(base, (0, path_1.resolve)(base || process.cwd(), ignore)));
            this.ignoreFn = (path) => {
                if (path.startsWith('..' + path_1.sep))
                    return true;
                if ((0, picomatch_1.isMatch)(path, resolvedIgnores))
                    return true;
                return false;
            };
        }
        this.base = base;
        this.cwd = (0, path_1.resolve)(processCwd || base);
        this.conditions = conditions;
        this.exportsOnly = exportsOnly;
        const resolvedPaths = {};
        for (const path of Object.keys(paths)) {
            const trailer = paths[path].endsWith('/');
            const resolvedPath = (0, path_1.resolve)(base, paths[path]);
            resolvedPaths[path] = resolvedPath + (trailer ? '/' : '');
        }
        this.paths = resolvedPaths;
        this.log = log;
        this.mixedModules = mixedModules;
        this.cachedFileSystem = new fs_1.CachedFileSystem({ cache, fileIOConcurrency });
        this.analysis = {};
        if (analysis !== false) {
            Object.assign(this.analysis, {
                // whether to glob any analysis like __dirname + '/dir/' or require('x/' + y)
                // that might output any file in a directory
                emitGlobs: true,
                // whether __filename and __dirname style
                // expressions should be analyzed as file references
                computeFileReferences: true,
                // evaluate known bindings to assist with glob and file reference analysis
                evaluatePureExpressions: true,
            }, analysis === true ? {} : analysis);
        }
        this.analysisCache = (cache && cache.analysisCache) || new Map();
        if (cache) {
            cache.analysisCache = this.analysisCache;
        }
        this.fileList = new Set();
        this.esmFileList = new Set();
        this.processed = new Set();
        this.warnings = new Set();
    }
    addRemapping(path, dep) {
        if (path === dep)
            return;
        let deps = this.remappings.get(path);
        if (!deps) {
            deps = new Set();
            this.remappings.set(path, deps);
        }
        deps.add(dep);
    }
    async readlink(path) {
        return this.cachedFileSystem.readlink(path);
    }
    async isFile(path) {
        const stats = await this.stat(path);
        if (stats)
            return stats.isFile();
        return false;
    }
    async isDir(path) {
        const stats = await this.stat(path);
        if (stats)
            return stats.isDirectory();
        return false;
    }
    async stat(path) {
        return this.cachedFileSystem.stat(path);
    }
    maybeEmitDep = async (dep, path, cjsResolve) => {
        let resolved = '';
        let error;
        try {
            resolved = await this.resolve(dep, path, this, cjsResolve);
        }
        catch (e1) {
            error = e1;
            try {
                if (this.ts && dep.endsWith('.js') && e1 instanceof resolve_dependency_1.NotFoundError) {
                    // TS with ESM relative import paths need full extensions
                    // (we have to write import "./foo.js" instead of import "./foo")
                    // See https://www.typescriptlang.org/docs/handbook/esm-node.html
                    const depTS = dep.slice(0, -3) + '.ts';
                    resolved = await this.resolve(depTS, path, this, cjsResolve);
                    error = undefined;
                }
            }
            catch (e2) {
                error = e2;
            }
        }
        if (error) {
            this.warnings.add(new Error(`Failed to resolve dependency "${dep}":\n${error?.message}`));
            return;
        }
        if (Array.isArray(resolved)) {
            for (const item of resolved) {
                // ignore builtins
                if (item.startsWith('node:'))
                    return;
                await this.emitDependency(item, path);
            }
        }
        else {
            // ignore builtins
            if (resolved.startsWith('node:'))
                return;
            await this.emitDependency(resolved, path);
        }
    };
    async resolve(id, parent, job, cjsResolve) {
        return (0, resolve_dependency_1.default)(id, parent, job, cjsResolve);
    }
    async readFile(path) {
        return this.cachedFileSystem.readFile(path);
    }
    async realpath(path, parent, seen = new Set()) {
        if (seen.has(path))
            throw new Error('Recursive symlink detected resolving ' + path);
        seen.add(path);
        const symlink = await this.readlink(path);
        // emit direct symlink paths only
        if (symlink) {
            const parentPath = (0, path_1.dirname)(path);
            const resolved = (0, path_1.resolve)(parentPath, symlink);
            const realParent = await this.realpath(parentPath, parent);
            if (inPath(path, realParent))
                await this.emitFile(path, 'resolve', parent, true);
            return this.realpath(resolved, parent, seen);
        }
        // keep backtracking for realpath, emitting folder symlinks within base
        if (!inPath(path, this.base))
            return path;
        return (0, path_1.join)(await this.realpath((0, path_1.dirname)(path), parent, seen), (0, path_1.basename)(path));
    }
    async emitFile(path, reasonType, parent, isRealpath = false) {
        if (!isRealpath) {
            path = await this.realpath(path, parent);
        }
        path = (0, path_1.relative)(this.base, path);
        if (parent) {
            parent = (0, path_1.relative)(this.base, parent);
        }
        let reasonEntry = this.reasons.get(path);
        if (!reasonEntry) {
            reasonEntry = {
                type: [reasonType],
                ignored: false,
                parents: new Set(),
            };
            this.reasons.set(path, reasonEntry);
        }
        else if (!reasonEntry.type.includes(reasonType)) {
            reasonEntry.type.push(reasonType);
        }
        if (parent && this.ignoreFn(path, parent)) {
            if (!this.fileList.has(path) && reasonEntry) {
                reasonEntry.ignored = true;
            }
            return false;
        }
        if (parent) {
            reasonEntry.parents.add(parent);
        }
        this.fileList.add(path);
        return true;
    }
    async getPjsonBoundary(path) {
        const rootSeparatorIndex = path.indexOf(path_1.sep);
        let separatorIndex;
        while ((separatorIndex = path.lastIndexOf(path_1.sep)) > rootSeparatorIndex) {
            path = path.slice(0, separatorIndex);
            if (await this.isFile(path + path_1.sep + 'package.json'))
                return path;
        }
        return undefined;
    }
    async emitDependency(path, parent) {
        if (this.processed.has(path)) {
            if (parent) {
                await this.emitFile(path, 'dependency', parent);
            }
            return;
        }
        this.processed.add(path);
        // Additional dependencies.
        const additionalDeps = this.remappings.get(path);
        if (additionalDeps) {
            await Promise.all([...additionalDeps].map(async (dep) => this.emitDependency(dep, path)));
        }
        const emitted = await this.emitFile(path, 'dependency', parent);
        if (!emitted)
            return;
        if (path.endsWith('.json'))
            return;
        if (path.endsWith('.node'))
            return await (0, sharedlib_emit_1.sharedLibEmit)(path, this);
        // .js and .ts files can change behavior based on { "type": "module" }
        // in the nearest package.json so we must emit it too. We don't need to
        // emit for .cjs/.mjs/.cts/.mts files since their behavior does not
        // depend on package.json
        if (path.endsWith('.js') || path.endsWith('.ts')) {
            const pjsonBoundary = await this.getPjsonBoundary(path);
            if (pjsonBoundary)
                await this.emitFile(pjsonBoundary + path_1.sep + 'package.json', 'resolve', path);
        }
        let analyzeResult;
        const cachedAnalysis = this.analysisCache.get(path);
        if (cachedAnalysis) {
            analyzeResult = cachedAnalysis;
        }
        else {
            const source = await this.readFile(path);
            if (source === null)
                throw new Error('File ' + path + ' does not exist.');
            // analyze should not have any side-effects e.g. calling `job.emitFile`
            // directly as this will not be included in the cachedAnalysis and won't
            // be emit for successive runs that leverage the cache
            analyzeResult = await (0, analyze_1.default)(path, source.toString(), this);
            this.analysisCache.set(path, analyzeResult);
        }
        const { deps, imports, assets, isESM } = analyzeResult;
        if (isESM) {
            this.esmFileList.add((0, path_1.relative)(this.base, path));
        }
        await Promise.all([
            ...[...assets].map(async (asset) => {
                const ext = (0, path_1.extname)(asset);
                if (ext === '.js' ||
                    ext === '.mjs' ||
                    ext === '.node' ||
                    ext === '' ||
                    (this.ts &&
                        (ext === '.ts' || ext === '.tsx') &&
                        asset.startsWith(this.base) &&
                        asset
                            .slice(this.base.length)
                            .indexOf(path_1.sep + 'node_modules' + path_1.sep) === -1))
                    await this.emitDependency(asset, path);
                else
                    await this.emitFile(asset, 'asset', path);
            }),
            ...[...deps].map(async (dep) => this.maybeEmitDep(dep, path, !isESM)),
            ...[...imports].map(async (dep) => this.maybeEmitDep(dep, path, false)),
        ]);
    }
}
exports.Job = Job;
