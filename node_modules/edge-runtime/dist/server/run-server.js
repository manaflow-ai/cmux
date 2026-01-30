"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.runServer = void 0;
const create_handler_1 = require("./create-handler");
const async_listen_1 = __importDefault(require("async-listen"));
const http_1 = __importDefault(require("http"));
/**
 * This helper will create a handler based on the given options and then
 * immediately run a server on the provided port. If there is no port, the
 * server will use a random one.
 */
async function runServer(options) {
    if (options.port === undefined)
        options.port = 0;
    const { handler, waitUntil } = (0, create_handler_1.createHandler)(options);
    const server = http_1.default.createServer(handler);
    const url = await (0, async_listen_1.default)(server, options);
    return {
        url: String(url),
        close: async () => {
            await waitUntil();
            await new Promise((resolve, reject) => {
                return server.close((err) => {
                    if (err)
                        reject(err);
                    resolve();
                });
            });
        },
        waitUntil,
    };
}
exports.runServer = runServer;
//# sourceMappingURL=run-server.js.map