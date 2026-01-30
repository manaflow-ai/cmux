"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.CachedFileSystem = void 0;
const path_1 = require("path");
const graceful_fs_1 = __importDefault(require("graceful-fs"));
const async_sema_1 = require("async-sema");
const fsReadFile = graceful_fs_1.default.promises.readFile;
const fsReadlink = graceful_fs_1.default.promises.readlink;
const fsStat = graceful_fs_1.default.promises.stat;
class CachedFileSystem {
    fileCache;
    statCache;
    symlinkCache;
    fileIOQueue;
    constructor({ cache, fileIOConcurrency, }) {
        this.fileIOQueue = new async_sema_1.Sema(fileIOConcurrency);
        this.fileCache = cache?.fileCache ?? new Map();
        this.statCache = cache?.statCache ?? new Map();
        this.symlinkCache = cache?.symlinkCache ?? new Map();
        if (cache) {
            cache.fileCache = this.fileCache;
            cache.statCache = this.statCache;
            cache.symlinkCache = this.symlinkCache;
        }
    }
    async readlink(path) {
        const cached = this.symlinkCache.get(path);
        if (cached !== undefined)
            return cached;
        // This is not awaiting the response, so that the cache is instantly populated and
        // future calls serve the Promise from the cache
        const readlinkPromise = this.executeFileIO(path, this._internalReadlink);
        this.symlinkCache.set(path, readlinkPromise);
        return readlinkPromise;
    }
    async readFile(path) {
        const cached = this.fileCache.get(path);
        if (cached !== undefined)
            return cached;
        // This is not awaiting the response, so that the cache is instantly populated and
        // future calls serve the Promise from the cache
        const readFilePromise = this.executeFileIO(path, this._internalReadFile);
        this.fileCache.set(path, readFilePromise);
        return readFilePromise;
    }
    async stat(path) {
        const cached = this.statCache.get(path);
        if (cached !== undefined)
            return cached;
        // This is not awaiting the response, so that the cache is instantly populated and
        // future calls serve the Promise from the cache
        const statPromise = this.executeFileIO(path, this._internalStat);
        this.statCache.set(path, statPromise);
        return statPromise;
    }
    async _internalReadlink(path) {
        try {
            const link = await fsReadlink(path);
            // also copy stat cache to symlink
            const stats = this.statCache.get(path);
            if (stats)
                this.statCache.set((0, path_1.resolve)(path, link), stats);
            return link;
        }
        catch (e) {
            if (e.code !== 'EINVAL' && e.code !== 'ENOENT' && e.code !== 'UNKNOWN')
                throw e;
            return null;
        }
    }
    async _internalReadFile(path) {
        try {
            return (await fsReadFile(path)).toString();
        }
        catch (e) {
            if (e.code === 'ENOENT' || e.code === 'EISDIR') {
                return null;
            }
            throw e;
        }
    }
    async _internalStat(path) {
        try {
            return await fsStat(path);
        }
        catch (e) {
            if (e.code === 'ENOENT') {
                return null;
            }
            throw e;
        }
    }
    async executeFileIO(path, fileIO) {
        await this.fileIOQueue.acquire();
        try {
            return fileIO.call(this, path);
        }
        finally {
            this.fileIOQueue.release();
        }
    }
}
exports.CachedFileSystem = CachedFileSystem;
