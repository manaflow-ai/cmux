"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.NotFoundError = void 0;
exports.default = resolveDependency;
const path_1 = require("path");
const module_1 = require("module");
const node_version_1 = require("./utils/node-version");
// node resolver
// custom implementation to emit only needed package.json files for resolver
// (package.json files are emitted as they are hit)
async function resolveDependency(specifier, parent, job, cjsResolve = true) {
    let resolved;
    if ((0, path_1.isAbsolute)(specifier) ||
        specifier === '.' ||
        specifier === '..' ||
        specifier.startsWith('./') ||
        specifier.startsWith('../')) {
        const trailingSlash = specifier.endsWith('/');
        resolved = await resolvePath((0, path_1.resolve)(parent, '..', specifier) + (trailingSlash ? '/' : ''), parent, job);
    }
    else if (specifier[0] === '#') {
        resolved = await packageImportsResolve(specifier, parent, job, cjsResolve);
    }
    else {
        resolved = await resolvePackage(specifier, parent, job, cjsResolve);
    }
    if (Array.isArray(resolved)) {
        return Promise.all(resolved.map((resolved) => job.realpath(resolved, parent)));
    }
    else if (resolved.startsWith('node:')) {
        return resolved;
    }
    else {
        return job.realpath(resolved, parent);
    }
}
async function resolvePath(path, parent, job) {
    const result = (await resolveFile(path, parent, job)) ||
        (await resolveDir(path, parent, job));
    if (!result) {
        throw new NotFoundError(path, parent);
    }
    return result;
}
async function resolveFile(path, parent, job) {
    if (path.endsWith('/'))
        return undefined;
    path = await job.realpath(path, parent);
    if (await job.isFile(path))
        return path;
    if (job.ts &&
        path.startsWith(job.base) &&
        path.slice(job.base.length).indexOf(path_1.sep + 'node_modules' + path_1.sep) === -1 &&
        (await job.isFile(path + '.ts')))
        return path + '.ts';
    if (job.ts &&
        path.startsWith(job.base) &&
        path.slice(job.base.length).indexOf(path_1.sep + 'node_modules' + path_1.sep) === -1 &&
        (await job.isFile(path + '.tsx')))
        return path + '.tsx';
    if (await job.isFile(path + '.js'))
        return path + '.js';
    if (await job.isFile(path + '.json'))
        return path + '.json';
    if (await job.isFile(path + '.node'))
        return path + '.node';
    return undefined;
}
async function resolveDir(path, parent, job) {
    if (path.endsWith('/'))
        path = path.slice(0, -1);
    if (!(await job.isDir(path)))
        return;
    const pkgCfg = await getPkgCfg(path, job);
    if (pkgCfg && typeof pkgCfg.main === 'string') {
        const resolved = (await resolveFile((0, path_1.resolve)(path, pkgCfg.main), parent, job)) ||
            (await resolveFile((0, path_1.resolve)(path, pkgCfg.main, 'index'), parent, job));
        if (resolved) {
            await job.emitFile(path + path_1.sep + 'package.json', 'resolve', parent);
            return resolved;
        }
    }
    return resolveFile((0, path_1.resolve)(path, 'index'), parent, job);
}
class NotFoundError extends Error {
    code;
    constructor(specifier, parent) {
        super("Cannot find module '" + specifier + "' loaded from " + parent);
        this.code = 'MODULE_NOT_FOUND';
    }
}
exports.NotFoundError = NotFoundError;
const nodeBuiltins = new Set(module_1.builtinModules);
function getPkgName(name) {
    const segments = name.split('/');
    if (name[0] === '@' && segments.length > 1)
        return segments.length > 1 ? segments.slice(0, 2).join('/') : null;
    return segments.length ? segments[0] : null;
}
async function getPkgCfg(pkgPath, job) {
    const pjsonSource = await job.readFile(pkgPath + path_1.sep + 'package.json');
    if (pjsonSource) {
        try {
            return JSON.parse(pjsonSource.toString());
        }
        catch (e) { }
    }
    return undefined;
}
function getExportsTarget(exports, conditions, cjsResolve) {
    if (typeof exports === 'string') {
        return exports;
    }
    else if (exports === null) {
        return exports;
    }
    else if (Array.isArray(exports)) {
        for (const item of exports) {
            const target = getExportsTarget(item, conditions, cjsResolve);
            if (target === null ||
                (typeof target === 'string' && target.startsWith('./')))
                return target;
        }
    }
    else if (typeof exports === 'object') {
        for (const condition of Object.keys(exports)) {
            if (condition === 'default' ||
                (condition === 'require' && cjsResolve) ||
                (condition === 'import' && !cjsResolve) ||
                (condition === 'module-sync' && (0, node_version_1.getNodeMajorVersion)() >= 22) ||
                conditions.includes(condition)) {
                const target = getExportsTarget(exports[condition], conditions, cjsResolve);
                if (target !== undefined)
                    return target;
            }
        }
    }
    return undefined;
}
async function validateAndResolvePaths(paths, parent, job, cjsResolve) {
    const validatedPaths = [];
    for (const path of paths) {
        if (cjsResolve) {
            const resolved = (await resolveFile(path, parent, job)) ||
                (await resolveDir(path, parent, job));
            if (!resolved)
                throw new NotFoundError(path, parent);
            validatedPaths.push(resolved);
        }
        else {
            if (!(await job.isFile(path)))
                throw new NotFoundError(path, parent);
            validatedPaths.push(path);
        }
    }
    return validatedPaths;
}
async function resolveExportsImports(pkgPath, obj, subpath, job, isImports, cjsResolve, parent) {
    let matchObj;
    if (isImports) {
        if (!(typeof obj === 'object' && !Array.isArray(obj) && obj !== null))
            return undefined;
        matchObj = obj;
    }
    else if (typeof obj === 'string' ||
        Array.isArray(obj) ||
        obj === null ||
        (typeof obj === 'object' &&
            Object.keys(obj).length &&
            Object.keys(obj)[0][0] !== '.')) {
        matchObj = { '.': obj };
    }
    else {
        matchObj = obj;
    }
    if (subpath in matchObj) {
        const target = getExportsTarget(matchObj[subpath], job.conditions, cjsResolve);
        if (typeof target === 'string' && target.startsWith('./')) {
            const resolvedPath = pkgPath + target.slice(1);
            const paths = [resolvedPath];
            const exportsForSubpath = matchObj[subpath];
            if (typeof exportsForSubpath === 'object' &&
                exportsForSubpath !== null &&
                !Array.isArray(exportsForSubpath) &&
                'module-sync' in exportsForSubpath &&
                (0, node_version_1.getNodeMajorVersion)() >= 22) {
                const fallbackCondition = 'require' in exportsForSubpath ? 'require' : 'default';
                const fallbackTarget = getExportsTarget(exportsForSubpath[fallbackCondition], job.conditions, cjsResolve);
                if (typeof fallbackTarget === 'string' &&
                    fallbackTarget.startsWith('./')) {
                    const fallbackPath = pkgPath + fallbackTarget.slice(1);
                    if (fallbackPath !== resolvedPath) {
                        paths.push(fallbackPath);
                    }
                }
            }
            return await validateAndResolvePaths(paths, parent, job, cjsResolve);
        }
    }
    for (const match of Object.keys(matchObj).sort((a, b) => b.length - a.length)) {
        if (match.endsWith('*') && subpath.startsWith(match.slice(0, -1))) {
            const target = getExportsTarget(matchObj[match], job.conditions, cjsResolve);
            if (typeof target === 'string' && target.startsWith('./')) {
                const resolvedPath = pkgPath +
                    target.slice(1).replace(/\*/g, subpath.slice(match.length - 1));
                return await validateAndResolvePaths([resolvedPath], parent, job, cjsResolve);
            }
        }
        if (!match.endsWith('/'))
            continue;
        if (subpath.startsWith(match)) {
            const target = getExportsTarget(matchObj[match], job.conditions, cjsResolve);
            if (typeof target === 'string' &&
                target.endsWith('/') &&
                target.startsWith('./')) {
                const resolvedPath = pkgPath + target.slice(1) + subpath.slice(match.length);
                return await validateAndResolvePaths([resolvedPath], parent, job, cjsResolve);
            }
        }
    }
    return undefined;
}
async function resolveRemappings(pkgPath, pkgCfg, parent, job) {
    if (job.conditions?.includes('browser')) {
        const { browser: pkgBrowser } = pkgCfg;
        if (!pkgBrowser) {
            return;
        }
        if (typeof pkgBrowser === 'object') {
            for (const [key, value] of Object.entries(pkgBrowser)) {
                if (typeof value !== 'string') {
                    /**
                     * `false` can be used to specify that a file is not meant to be included.
                     * Downstream processing is expected to handle this case, and it should remain in the mapping result
                     */
                    continue;
                }
                if (!key.startsWith('./') || !value.startsWith('./')) {
                    continue;
                }
                const keyResolved = await resolveFile(pkgPath + path_1.sep + key, parent, job);
                const valueResolved = await resolveFile(pkgPath + path_1.sep + value, parent, job);
                if (keyResolved && valueResolved) {
                    job.addRemapping(keyResolved, valueResolved);
                }
            }
        }
    }
}
async function packageImportsResolve(name, parent, job, cjsResolve) {
    if (name !== '#' && !name.startsWith('#/') && job.conditions) {
        const pjsonBoundary = await job.getPjsonBoundary(parent);
        if (pjsonBoundary) {
            const pkgCfg = await getPkgCfg(pjsonBoundary, job);
            const { imports: pkgImports } = pkgCfg || {};
            if (pkgCfg && pkgImports !== null && pkgImports !== undefined) {
                const importsResolved = await resolveExportsImports(pjsonBoundary, pkgImports, name, job, true, cjsResolve, parent);
                if (importsResolved) {
                    await job.emitFile(pjsonBoundary + path_1.sep + 'package.json', 'resolve', parent);
                    return importsResolved;
                }
            }
        }
    }
    throw new NotFoundError(name, parent);
}
async function resolvePackage(name, parent, job, cjsResolve) {
    let packageParent = parent;
    if (nodeBuiltins.has(name))
        return 'node:' + name;
    if (name.startsWith('node:'))
        return name;
    const pkgName = getPkgName(name) || '';
    // package own name resolution
    let selfResolved;
    if (job.conditions) {
        const pjsonBoundary = await job.getPjsonBoundary(parent);
        if (pjsonBoundary) {
            const pkgCfg = await getPkgCfg(pjsonBoundary, job);
            const { exports: pkgExports } = pkgCfg || {};
            if (pkgCfg &&
                pkgCfg.name &&
                pkgCfg.name === pkgName &&
                pkgExports !== null &&
                pkgExports !== undefined) {
                selfResolved = await resolveExportsImports(pjsonBoundary, pkgExports, '.' + name.slice(pkgName.length), job, false, cjsResolve, parent);
                if (selfResolved)
                    await job.emitFile(pjsonBoundary + path_1.sep + 'package.json', 'resolve', parent);
            }
        }
    }
    let separatorIndex;
    const rootSeparatorIndex = packageParent.indexOf(path_1.sep);
    while ((separatorIndex = packageParent.lastIndexOf(path_1.sep)) > rootSeparatorIndex) {
        packageParent = packageParent.slice(0, separatorIndex);
        const nodeModulesDir = packageParent + path_1.sep + 'node_modules';
        const stat = await job.stat(nodeModulesDir);
        if (!stat || !stat.isDirectory())
            continue;
        const pkgCfg = await getPkgCfg(nodeModulesDir + path_1.sep + pkgName, job);
        const { exports: pkgExports } = pkgCfg || {};
        if (pkgCfg) {
            await resolveRemappings(nodeModulesDir + path_1.sep + pkgName, pkgCfg, parent, job);
        }
        if (job.conditions &&
            pkgExports !== undefined &&
            pkgExports !== null &&
            !selfResolved) {
            let legacyResolved;
            if (!job.exportsOnly)
                legacyResolved =
                    (await resolveFile(nodeModulesDir + path_1.sep + name, parent, job)) ||
                        (await resolveDir(nodeModulesDir + path_1.sep + name, parent, job));
            const resolved = await resolveExportsImports(nodeModulesDir + path_1.sep + pkgName, pkgExports, '.' + name.slice(pkgName.length), job, false, cjsResolve, parent);
            if (resolved) {
                await job.emitFile(nodeModulesDir + path_1.sep + pkgName + path_1.sep + 'package.json', 'resolve', parent);
                if (legacyResolved && !resolved.includes(legacyResolved))
                    return [...resolved, legacyResolved];
                return resolved;
            }
            if (legacyResolved)
                return legacyResolved;
        }
        else {
            const resolved = (await resolveFile(nodeModulesDir + path_1.sep + name, parent, job)) ||
                (await resolveDir(nodeModulesDir + path_1.sep + name, parent, job));
            if (resolved) {
                if (selfResolved) {
                    if (Array.isArray(selfResolved)) {
                        if (!selfResolved.includes(resolved))
                            return [resolved, ...selfResolved];
                        return selfResolved;
                    }
                    else if (selfResolved !== resolved) {
                        return [resolved, selfResolved];
                    }
                }
                return resolved;
            }
        }
    }
    if (selfResolved)
        return selfResolved;
    if (Object.hasOwnProperty.call(job.paths, name)) {
        return job.paths[name];
    }
    for (const path of Object.keys(job.paths)) {
        if (path.endsWith('/') && name.startsWith(path)) {
            const pathTarget = job.paths[path] + name.slice(path.length);
            const resolved = (await resolveFile(pathTarget, parent, job)) ||
                (await resolveDir(pathTarget, parent, job));
            if (!resolved) {
                throw new NotFoundError(name, parent);
            }
            return resolved;
        }
    }
    throw new NotFoundError(name, parent);
}
