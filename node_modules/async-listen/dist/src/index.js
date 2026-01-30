"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const url_1 = require("url");
function listen(server, ...args) {
    return new Promise((resolve, reject) => {
        function cleanup() {
            server.removeListener('error', onError);
        }
        function onError(err) {
            cleanup();
            reject(err);
        }
        args.push((err) => {
            cleanup();
            if (err)
                return reject(err);
            const address = server.address();
            if (typeof address === 'string') {
                resolve(address);
            }
            else {
                // TODO: detect protocol type based on `server` shape
                const protocol = 'http:';
                const { address: hostname, port } = address;
                const url = url_1.format({ protocol, hostname, port });
                resolve(url);
            }
        });
        server.on('error', onError);
        try {
            server.listen(...args);
        }
        catch (err) {
            onError(err);
        }
    });
}
exports.default = listen;
//# sourceMappingURL=index.js.map