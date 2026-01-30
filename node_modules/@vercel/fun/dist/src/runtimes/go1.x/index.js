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
exports.init = void 0;
const node_path_1 = require("node:path");
const tinyexec_1 = require("tinyexec");
const debug_1 = __importDefault(require("debug"));
const promises_1 = require("node:fs/promises");
const filename_1 = require("./filename");
const debug = (0, debug_1.default)('@vercel/fun:runtimes/go1.x');
function _go(opts) {
    return function go(...args) {
        debug('Exec %o', `go ${args.join(' ')}`);
        return (0, tinyexec_1.exec)('go', args, Object.assign({ stdio: 'inherit' }, opts));
    };
}
function init({ cacheDir }) {
    return __awaiter(this, void 0, void 0, function* () {
        const source = (0, node_path_1.join)(cacheDir, 'bootstrap.go');
        const out = (0, filename_1.getOutputFile)();
        let data = yield (0, promises_1.readFile)(source, 'utf8');
        // Fix windows
        if (process.platform === 'win32') {
            debug('detected windows, so stripping Setpgid');
            data = data
                .split('\n')
                .filter(line => !line.includes('Setpgid'))
                .join('\n');
        }
        // Prepare a temporary `$GOPATH`
        const GOPATH = (0, node_path_1.join)(cacheDir, 'go');
        // The source code must reside in `$GOPATH/src` for `go get` to work
        const bootstrapDir = (0, node_path_1.join)(GOPATH, 'src', out);
        yield (0, promises_1.mkdir)(bootstrapDir, { recursive: true });
        yield (0, promises_1.writeFile)((0, node_path_1.join)(bootstrapDir, 'bootstrap.go'), data);
        const go = _go({ cwd: bootstrapDir, env: Object.assign(Object.assign({}, process.env), { GOPATH }) });
        const bootstrap = (0, node_path_1.join)(cacheDir, out);
        debug('Compiling Go runtime binary %o -> %o', source, bootstrap);
        yield go('get');
        yield go('build', '-o', bootstrap, 'bootstrap.go');
        // Clean up `$GOPATH` from the cacheDir
        yield (0, promises_1.rm)(GOPATH, { recursive: true });
    });
}
exports.init = init;
//# sourceMappingURL=index.js.map