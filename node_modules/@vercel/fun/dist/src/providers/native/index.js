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
const ms_1 = __importDefault(require("ms"));
const node_crypto_1 = require("node:crypto");
const debug_1 = __importDefault(require("debug"));
const node_util_1 = require("node:util");
const async_listen_1 = __importDefault(require("async-listen"));
const tree_kill_1 = __importDefault(require("tree-kill"));
const generic_pool_1 = require("generic-pool");
const node_path_1 = require("node:path");
const child_process_1 = require("child_process");
const runtime_server_1 = require("../../runtime-server");
const isWin = process.platform === 'win32';
const debug = (0, debug_1.default)('@vercel/fun:providers/native');
const treeKill = (0, node_util_1.promisify)(tree_kill_1.default);
class NativeProvider {
    constructor(fn, params) {
        const factory = {
            create: this.createProcess.bind(this),
            destroy: this.destroyProcess.bind(this)
        };
        const opts = {
            min: 0,
            max: 10,
            acquireTimeoutMillis: (0, ms_1.default)('5s')
            // XXX: These 3 options are commented out because they cause
            // the tests to never complete (doesn't exit cleanly).
            // How often to check if a process needs to be shut down due to not
            // being invoked
            //evictionRunIntervalMillis: ms('10s'),
            // How long a process is allowed to stay alive without being invoked
            //idleTimeoutMillis: ms('15s')
        };
        this.lambda = fn;
        this.params = params;
        this.runtimeApis = new WeakMap();
        this.pool = (0, generic_pool_1.createPool)(factory, opts);
        this.pool.on('factoryCreateError', err => {
            console.error('factoryCreateError', { err });
        });
        this.pool.on('factoryDestroyError', err => {
            console.error('factoryDestroyError', { err });
        });
    }
    createProcess() {
        return __awaiter(this, void 0, void 0, function* () {
            const { runtime, params, region, version, extractedDir } = this.lambda;
            const binDir = (0, node_path_1.join)(runtime.cacheDir, 'bin');
            const bootstrapFile = runtime.name === 'executable' ? 'executable' : 'bootstrap';
            const bootstrap = (0, node_path_1.join)(runtime.cacheDir, isWin ? 'bootstrap.js' : bootstrapFile);
            const server = new runtime_server_1.RuntimeServer(this.lambda);
            yield (0, async_listen_1.default)(server, 0, '127.0.0.1');
            const { port } = server.address();
            debug('Creating process %o', bootstrap);
            const taskDir = (0, node_path_1.resolve)(extractedDir || params.Code.Directory);
            const functionName = params.FunctionName || (0, node_path_1.basename)(taskDir);
            const logGroupName = `aws/lambda/${functionName}`;
            const logStreamName = `2019/01/12/[${version}]${(0, node_crypto_1.randomUUID)().replace(/\-/g, '')}`;
            // https://docs.aws.amazon.com/lambda/latest/dg/current-supported-versions.html
            const env = Object.assign(Object.assign({ 
                // Non-reserved env vars (can overwrite with params)
                PATH: `${binDir}${node_path_1.delimiter}${process.env.PATH}`, LANG: 'en_US.UTF-8' }, (params.Environment && params.Environment.Variables)), { 
                // Restricted env vars
                _HANDLER: params.Handler, AWS_REGION: region, AWS_ACCESS_KEY_ID: params.AccessKeyId, AWS_SECRET_ACCESS_KEY: params.SecretAccessKey, AWS_DEFAULT_REGION: region, AWS_EXECUTION_ENV: `AWS_Lambda_${params.Runtime}`, AWS_LAMBDA_FUNCTION_NAME: functionName, AWS_LAMBDA_FUNCTION_VERSION: version, AWS_LAMBDA_FUNCTION_MEMORY_SIZE: String(params.MemorySize || 128), AWS_LAMBDA_RUNTIME_API: `127.0.0.1:${port}`, AWS_LAMBDA_LOG_GROUP_NAME: logGroupName, AWS_LAMBDA_LOG_STREAM_NAME: logStreamName, LAMBDA_RUNTIME_DIR: runtime.cacheDir, LAMBDA_TASK_ROOT: taskDir, TZ: ':UTC' });
            let bin = bootstrap;
            const args = [];
            if (isWin) {
                args.push(bootstrap);
                bin = process.execPath;
            }
            const proc = (0, child_process_1.spawn)(bin, args, {
                env,
                cwd: taskDir,
                stdio: ['ignore', 'inherit', 'inherit']
            });
            this.runtimeApis.set(proc, server);
            proc.on('exit', (code, signal) => __awaiter(this, void 0, void 0, function* () {
                debug('Process (pid=%o) exited with code %o, signal %o', proc.pid, code, signal);
                const server = this.runtimeApis.get(proc);
                if (server) {
                    debug('Shutting down Runtime API for %o', proc.pid);
                    server.close();
                    this.runtimeApis.delete(proc);
                }
                else {
                    debug('No Runtime API server associated with process %o. This SHOULD NOT happen!', proc.pid);
                }
            }));
            return proc;
        });
    }
    destroyProcess(proc) {
        return __awaiter(this, void 0, void 0, function* () {
            try {
                // Unfreeze the process first so it is able to process the `SIGTERM`
                // signal and exit cleanly (clean up child processes, etc.)
                this.unfreezeProcess(proc);
                debug('Stopping process %o', proc.pid);
                yield treeKill(proc.pid);
            }
            catch (err) {
                // ESRCH means that the process ID no longer exists, which is fine
                // in this case since we're shutting down the process anyways
                if (err.code === 'ESRCH' || /not found/i.test(err.message)) {
                    debug('Got error stopping process %o: %s', proc.pid, err.message);
                }
                else {
                    throw err;
                }
            }
        });
    }
    freezeProcess(proc) {
        // `SIGSTOP` is not supported on Windows
        if (!isWin) {
            debug('Freezing process %o', proc.pid);
            process.kill(proc.pid, 'SIGSTOP');
        }
    }
    unfreezeProcess(proc) {
        // `SIGCONT` is not supported on Windows
        if (!isWin) {
            debug('Unfreezing process %o', proc.pid);
            process.kill(proc.pid, 'SIGCONT');
        }
    }
    invoke(params) {
        return __awaiter(this, void 0, void 0, function* () {
            let result;
            const proc = yield this.pool.acquire();
            const server = this.runtimeApis.get(proc);
            if (server.initDeferred) {
                // The lambda process has just booted up, so wait for the
                // initialization API call to come in before proceeding
                debug('Waiting for init on process %o', proc.pid);
                const initError = yield server.initDeferred.promise;
                if (initError) {
                    debug('Lambda got initialization error on process %o', proc.pid);
                    // An error happend during initialization, so remove the
                    // process from the pool and return the error to the caller
                    yield this.pool.destroy(proc);
                    return initError;
                }
                debug('Lambda is initialized for process %o', proc.pid);
            }
            else {
                // The lambda process is being re-used for a subsequent
                // invocation, so unfreeze the process first
                this.unfreezeProcess(proc);
            }
            try {
                result = yield server.invoke(params);
            }
            catch (err) {
                result = {
                    StatusCode: 200,
                    FunctionError: 'Unhandled',
                    ExecutedVersion: '$LATEST',
                    // TODO: make this into a `server.createError()` function
                    Payload: JSON.stringify({
                        errorMessage: err.message
                    })
                };
            }
            if (result.FunctionError === 'Unhandled') {
                // An "Unhandled" error means either init error or the process
                // exited before sending the response. In either case, the process
                // is unhealthy and needs to be removed from the pool
                yield this.pool.destroy(proc);
            }
            else {
                // Either a successful response, or a "Handled" error.
                // The process may be re-used for the next invocation.
                this.freezeProcess(proc);
                yield this.pool.release(proc);
            }
            return result;
        });
    }
    destroy() {
        return __awaiter(this, void 0, void 0, function* () {
            debug('Draining pool');
            yield this.pool.drain();
            this.pool.clear();
        });
    }
}
exports.default = NativeProvider;
//# sourceMappingURL=index.js.map