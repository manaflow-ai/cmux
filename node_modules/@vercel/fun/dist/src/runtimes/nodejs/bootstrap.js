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
/**
 * Credit: https://github.com/lambci/node-custom-lambda/blob/master/v10.x/bootstrap.js
 */
const http_1 = __importDefault(require("http"));
const RUNTIME_PATH = '/2018-06-01/runtime';
const { AWS_LAMBDA_FUNCTION_NAME, AWS_LAMBDA_FUNCTION_VERSION, AWS_LAMBDA_FUNCTION_MEMORY_SIZE, AWS_LAMBDA_LOG_GROUP_NAME, AWS_LAMBDA_LOG_STREAM_NAME, LAMBDA_TASK_ROOT, _HANDLER, AWS_LAMBDA_RUNTIME_API } = process.env;
delete process.env.SHLVL;
const [HOST, PORT] = AWS_LAMBDA_RUNTIME_API.split(':');
start();
// Simple `util.promisify()` polyfill for Node 6.x
function promisify(fn) {
    return function (...args) {
        return new Promise((resolve, reject) => {
            args.push((err, result) => {
                if (err)
                    return reject(err);
                resolve(result);
            });
            const r = fn.apply(this, args);
            if (typeof r !== 'undefined') {
                resolve(r);
            }
        });
    };
}
function start() {
    return __awaiter(this, void 0, void 0, function* () {
        let handler;
        try {
            handler = getHandler();
        }
        catch (e) {
            yield initError(e);
            return process.exit(1);
        }
        try {
            yield processEvents(handler);
        }
        catch (e) {
            console.error(e);
            return process.exit(1);
        }
    });
}
function processEvents(handler) {
    return __awaiter(this, void 0, void 0, function* () {
        while (true) {
            const { event, context } = yield nextInvocation();
            let result;
            try {
                result = yield handler(event, context);
            }
            catch (e) {
                yield invokeError(e, context);
                continue;
            }
            yield invokeResponse(result, context);
        }
    });
}
function initError(err) {
    return __awaiter(this, void 0, void 0, function* () {
        return postError(`${RUNTIME_PATH}/init/error`, err);
    });
}
function nextInvocation() {
    return __awaiter(this, void 0, void 0, function* () {
        const res = yield request({ path: `${RUNTIME_PATH}/invocation/next` });
        if (res.statusCode !== 200) {
            throw new Error(`Unexpected /invocation/next response: ${JSON.stringify(res)}`);
        }
        if (res.headers['lambda-runtime-trace-id']) {
            process.env._X_AMZN_TRACE_ID = res.headers['lambda-runtime-trace-id'];
        }
        else {
            delete process.env._X_AMZN_TRACE_ID;
        }
        const deadlineMs = Number(res.headers['lambda-runtime-deadline-ms']);
        const awsRequestId = res.headers['lambda-runtime-aws-request-id'];
        const context = {
            callbackWaitsForEmptyEventLoop: false,
            logGroupName: AWS_LAMBDA_LOG_GROUP_NAME,
            logStreamName: AWS_LAMBDA_LOG_STREAM_NAME,
            functionName: AWS_LAMBDA_FUNCTION_NAME,
            memoryLimitInMB: AWS_LAMBDA_FUNCTION_MEMORY_SIZE,
            functionVersion: AWS_LAMBDA_FUNCTION_VERSION,
            invokeid: awsRequestId,
            awsRequestId,
            invokedFunctionArn: res.headers['lambda-runtime-invoked-function-arn'],
            getRemainingTimeInMillis: () => deadlineMs - Date.now()
        };
        if (res.headers['lambda-runtime-client-context']) {
            context.clientContext = JSON.parse(res.headers['lambda-runtime-client-context']);
        }
        if (res.headers['lambda-runtime-cognito-identity']) {
            context.identity = JSON.parse(res.headers['lambda-runtime-cognito-identity']);
        }
        const event = JSON.parse(res.body);
        return { event, context };
    });
}
function invokeResponse(result, context) {
    return __awaiter(this, void 0, void 0, function* () {
        const res = yield request({
            method: 'POST',
            path: `${RUNTIME_PATH}/invocation/${context.awsRequestId}/response`,
            body: JSON.stringify(result)
        });
        if (res.statusCode !== 202) {
            throw new Error(`Unexpected /invocation/response response: ${JSON.stringify(res)}`);
        }
    });
}
function invokeError(err, context) {
    return __awaiter(this, void 0, void 0, function* () {
        return postError(`${RUNTIME_PATH}/invocation/${context.awsRequestId}/error`, err);
    });
}
function postError(path, err) {
    return __awaiter(this, void 0, void 0, function* () {
        const lambdaErr = toLambdaErr(err);
        const res = yield request({
            method: 'POST',
            path,
            headers: {
                'Content-Type': 'application/json',
                'Lambda-Runtime-Function-Error-Type': lambdaErr.errorType
            },
            body: JSON.stringify(lambdaErr)
        });
        if (res.statusCode !== 202) {
            throw new Error(`Unexpected ${path} response: ${JSON.stringify(res)}`);
        }
    });
}
function getHandler() {
    const segments = _HANDLER.split('/');
    const appParts = segments[segments.length - 1].split('.');
    if (appParts.length !== 2) {
        throw new Error(`Bad handler ${_HANDLER}`);
    }
    const [moduleFile, handlerName] = appParts;
    const modulePath = [...segments.slice(0, -1), moduleFile].join('/');
    let app;
    try {
        app = require(`${LAMBDA_TASK_ROOT}/${modulePath}`);
    }
    catch (e) {
        if (e.code === 'MODULE_NOT_FOUND') {
            throw new Error(`Unable to import module '${modulePath}'`);
        }
        throw e;
    }
    const userHandler = app[handlerName];
    if (userHandler == null) {
        throw new Error(`Handler '${handlerName}' missing on module '${modulePath}'`);
    }
    else if (typeof userHandler !== 'function') {
        throw new Error(`Handler '${handlerName}' from '${modulePath}' is not a function`);
    }
    return userHandler.length >= 3 ? promisify(userHandler) : userHandler;
}
function request(options) {
    return __awaiter(this, void 0, void 0, function* () {
        options.host = HOST;
        options.port = PORT;
        return new Promise((resolve, reject) => {
            const req = http_1.default.request(options, res => {
                const bufs = [];
                res.on('data', data => bufs.push(data));
                res.on('end', () => resolve({
                    statusCode: res.statusCode,
                    headers: res.headers,
                    body: Buffer.concat(bufs).toString('utf8')
                }));
                res.on('error', reject);
            });
            req.on('error', reject);
            req.end(options.body);
        });
    });
}
function toLambdaErr({ name, message, stack }) {
    return {
        errorType: name,
        errorMessage: message,
        stackTrace: (stack || '').split('\n').slice(1)
    };
}
//# sourceMappingURL=bootstrap.js.map