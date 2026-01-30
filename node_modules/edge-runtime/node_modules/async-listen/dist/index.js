"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.listen = void 0;
const http = require("http");
const https = require("https");
const path_1 = require("path");
const events_1 = require("events");
const getProtocol = (server) => {
    if (typeof server.protocol === 'string')
        return server.protocol;
    if (server instanceof http.Server)
        return 'http';
    if (server instanceof https.Server)
        return 'https';
};
async function listen(server, ...args) {
    server.listen(...args, () => { });
    await (0, events_1.once)(server, 'listening');
    const addressInfo = server.address();
    if (!addressInfo) {
        // `server.address()` returns `null` before the `'listening'`
        // event has been emitted or after calling `server.close()`.
        throw new Error('Server not listening');
    }
    let host;
    let protocol = getProtocol(server);
    if (typeof addressInfo === 'string') {
        // For a server listening on a pipe or Unix domain socket,
        // the name is returned as a string.
        host = encodeURIComponent((0, path_1.resolve)(addressInfo));
        if (protocol) {
            protocol += '+unix';
        }
        else {
            protocol = 'unix';
        }
    }
    else {
        // Bound to a TCP port.
        const { address, port, family } = addressInfo;
        host = family === 'IPv6' ? `[${address}]` : address;
        host += `:${port}`;
        if (!protocol) {
            protocol = 'tcp';
        }
    }
    return new URL(`${protocol}://${host}`);
}
exports.listen = listen;
exports.default = listen;
