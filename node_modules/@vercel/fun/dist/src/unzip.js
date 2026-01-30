"use strict";
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
exports.unzip = exports.unzipToTemp = exports.ZipFile = exports.zipFromBuffer = exports.zipFromFile = void 0;
const node_os_1 = require("node:os");
const stat_mode_1 = __importDefault(require("stat-mode"));
const promisepipe_1 = __importDefault(require("promisepipe"));
const debug_1 = __importDefault(require("debug"));
const node_path_1 = require("node:path");
const node_fs_1 = require("node:fs");
const promises_1 = require("node:fs/promises");
const stream_to_promise_1 = __importDefault(require("stream-to-promise"));
const yauzl_promise_1 = require("yauzl-promise");
Object.defineProperty(exports, "ZipFile", { enumerable: true, get: function () { return yauzl_promise_1.ZipFile; } });
Object.defineProperty(exports, "zipFromFile", { enumerable: true, get: function () { return yauzl_promise_1.open; } });
Object.defineProperty(exports, "zipFromBuffer", { enumerable: true, get: function () { return yauzl_promise_1.fromBuffer; } });
const debug = (0, debug_1.default)('@vercel/fun:unzip');
function unzipToTemp(data, tmpDir = (0, node_os_1.tmpdir)()) {
    return __awaiter(this, void 0, void 0, function* () {
        const dir = (0, node_path_1.join)(tmpDir, `zeit-fun-${Math.random()
            .toString(16)
            .substring(2)}`);
        let zip;
        if (Buffer.isBuffer(data)) {
            debug('Unzipping buffer (length=%o) to temp dir %o', data.length, dir);
            zip = yield (0, yauzl_promise_1.fromBuffer)(data);
        }
        else {
            debug('Unzipping %o to temp dir %o', data, dir);
            zip = yield (0, yauzl_promise_1.open)(data);
        }
        yield unzip(zip, dir);
        yield zip.close();
        debug('Finished unzipping to %o', dir);
        return dir;
    });
}
exports.unzipToTemp = unzipToTemp;
const getMode = (entry) => new stat_mode_1.default({ mode: entry.externalFileAttributes >>> 16 });
function unzip(zipFile, dir, opts = {}) {
    return __awaiter(this, void 0, void 0, function* () {
        let entry;
        const strip = opts.strip || 0;
        while ((entry = yield zipFile.readEntry()) !== null) {
            const fileName = strip === 0
                ? entry.fileName
                : entry.fileName
                    .split('/')
                    .slice(strip)
                    .join('/');
            const destPath = (0, node_path_1.join)(dir, fileName);
            if (/\/$/.test(entry.fileName)) {
                debug('Creating directory %o', destPath);
                yield (0, promises_1.mkdir)(destPath, { recursive: true });
            }
            else {
                const [entryStream] = yield Promise.all([
                    entry.openReadStream(),
                    // ensure parent directory exists
                    (0, promises_1.mkdir)((0, node_path_1.dirname)(destPath), { recursive: true })
                ]);
                const mode = getMode(entry);
                if (mode.isSymbolicLink()) {
                    const linkDest = String(yield (0, stream_to_promise_1.default)(entryStream));
                    debug('Creating symboling link %o to %o', destPath, linkDest);
                    yield (0, promises_1.symlink)(linkDest, destPath);
                }
                else {
                    const modeOctal = mode.toOctal();
                    const modeVal = parseInt(modeOctal, 8);
                    if (modeVal === 0) {
                        debug('Unzipping file to %o', destPath);
                    }
                    else {
                        debug('Unzipping file to %o with mode %s (%s)', destPath, modeOctal, String(mode));
                    }
                    try {
                        yield (0, promises_1.unlink)(destPath);
                    }
                    catch (err) {
                        if (err.code !== 'ENOENT') {
                            throw err;
                        }
                    }
                    const destStream = (0, node_fs_1.createWriteStream)(destPath, {
                        mode: modeVal
                    });
                    yield (0, promisepipe_1.default)(entryStream, destStream);
                }
            }
        }
    });
}
exports.unzip = unzip;
//# sourceMappingURL=unzip.js.map