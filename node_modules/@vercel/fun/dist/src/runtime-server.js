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
exports.RuntimeServer = void 0;
const node_http_1 = require("node:http");
const node_url_1 = require("node:url");
const debug_1 = __importDefault(require("debug"));
const micro_1 = require("micro");
const node_crypto_1 = require("node:crypto");
const path_to_regexp_1 = require("path-to-regexp");
const once_1 = __importDefault(require("@tootallnate/once"));
const deferred_1 = require("./deferred");
const matchFn = (0, path_to_regexp_1.match)('/:version/runtime/:subject/:target{/:action}');
const debug = (0, debug_1.default)('@vercel/fun:runtime-server');
function send404(res) {
    res.statusCode = 404;
    res.end();
}
class RuntimeServer extends node_http_1.Server {
    constructor(fn) {
        super();
        this.version = '2018-06-01';
        const serve = this.serve.bind(this);
        this.on('request', (req, res) => (0, micro_1.run)(req, res, serve));
        this.lambda = fn;
        this.initDeferred = (0, deferred_1.createDeferred)();
        this.resetInvocationState();
    }
    resetInvocationState() {
        this.nextDeferred = (0, deferred_1.createDeferred)();
        this.invokeDeferred = null;
        this.resultDeferred = null;
        this.currentRequestId = (0, node_crypto_1.randomUUID)();
    }
    serve(req, res) {
        return __awaiter(this, void 0, void 0, function* () {
            debug('%s %s', req.method, req.url);
            const result = matchFn((0, node_url_1.parse)(req.url).pathname);
            if (!result) {
                return send404(res);
            }
            const { version, subject, target, action } = result.params;
            if (this.version !== version) {
                debug('Invalid API version, expected %o but got %o', this.version, version);
                return send404(res);
            }
            // Routing logic
            if (subject === 'invocation') {
                if (target === 'next') {
                    return this.handleNextInvocation(req, res);
                }
                else {
                    // Assume it's an "AwsRequestId"
                    if (action === 'response') {
                        return this.handleInvocationResponse(req, res, target);
                    }
                    else if (action === 'error') {
                        return this.handleInvocationError(req, res, target);
                    }
                    else {
                        return send404(res);
                    }
                }
            }
            else if (subject === 'init') {
                if (target === 'error') {
                    return this.handleInitializationError(req, res);
                }
                else {
                    return send404(res);
                }
            }
            else {
                return send404(res);
            }
        });
    }
    handleNextInvocation(req, res) {
        return __awaiter(this, void 0, void 0, function* () {
            const { initDeferred } = this;
            if (initDeferred) {
                debug('Runtime successfully initialized');
                this.initDeferred = null;
                initDeferred.resolve();
            }
            this.invokeDeferred = (0, deferred_1.createDeferred)();
            this.resultDeferred = (0, deferred_1.createDeferred)();
            this.nextDeferred.resolve();
            this.nextDeferred = null;
            debug('Waiting for the `invoke()` function to be called');
            // @ts-ignore
            req.setTimeout(0); // disable default 2 minute socket timeout
            const params = yield this.invokeDeferred.promise;
            // TODO: use dynamic values from lambda params
            const deadline = 5000;
            const functionArn = 'arn:aws:lambda:us-west-1:977805900156:function:nate-dump';
            res.setHeader('Lambda-Runtime-Aws-Request-Id', this.currentRequestId);
            res.setHeader('Lambda-Runtime-Invoked-Function-Arn', functionArn);
            res.setHeader('Lambda-Runtime-Deadline-Ms', String(deadline));
            const finish = (0, once_1.default)(res, 'finish');
            res.end(params.Payload);
            yield finish;
        });
    }
    handleInvocationResponse(req, res, requestId) {
        return __awaiter(this, void 0, void 0, function* () {
            // `RequestResponse` = 200
            // `Event` = 202
            // `DryRun` = 204
            const statusCode = 200;
            const payload = {
                StatusCode: statusCode,
                ExecutedVersion: '$LATEST',
                Payload: yield (0, micro_1.text)(req, { limit: '6mb' })
            };
            res.statusCode = 202;
            const finish = (0, once_1.default)(res, 'finish');
            res.end();
            yield finish;
            this.resultDeferred.resolve(payload);
            this.resetInvocationState();
        });
    }
    handleInvocationError(req, res, requestId) {
        return __awaiter(this, void 0, void 0, function* () {
            const statusCode = 200;
            const payload = {
                StatusCode: statusCode,
                FunctionError: 'Handled',
                ExecutedVersion: '$LATEST',
                Payload: yield (0, micro_1.text)(req, { limit: '6mb' })
            };
            res.statusCode = 202;
            const finish = (0, once_1.default)(res, 'finish');
            res.end();
            yield finish;
            this.resultDeferred.resolve(payload);
            this.resetInvocationState();
        });
    }
    handleInitializationError(req, res) {
        return __awaiter(this, void 0, void 0, function* () {
            const statusCode = 200;
            const payload = {
                StatusCode: statusCode,
                FunctionError: 'Unhandled',
                ExecutedVersion: '$LATEST',
                Payload: yield (0, micro_1.text)(req, { limit: '6mb' })
            };
            res.statusCode = 202;
            const finish = (0, once_1.default)(res, 'finish');
            res.end();
            yield finish;
            this.initDeferred.resolve(payload);
        });
    }
    invoke(params = { InvocationType: 'RequestResponse' }) {
        return __awaiter(this, void 0, void 0, function* () {
            if (this.nextDeferred) {
                debug('Waiting for `next` invocation request from runtime');
                yield this.nextDeferred.promise;
            }
            if (!params.Payload) {
                params.Payload = '{}';
            }
            this.invokeDeferred.resolve(params);
            const result = yield this.resultDeferred.promise;
            return result;
        });
    }
    close(callback) {
        const deferred = this.initDeferred || this.resultDeferred;
        if (deferred) {
            const statusCode = 200;
            deferred.resolve({
                StatusCode: statusCode,
                FunctionError: 'Unhandled',
                ExecutedVersion: '$LATEST',
                Payload: JSON.stringify({
                    errorMessage: `RequestId: ${this.currentRequestId} Process exited before completing request`
                })
            });
        }
        super.close(callback);
        return this;
    }
}
exports.RuntimeServer = RuntimeServer;
//# sourceMappingURL=runtime-server.js.map