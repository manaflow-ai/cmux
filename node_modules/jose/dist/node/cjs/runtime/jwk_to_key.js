"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const node_crypto_1 = require("node:crypto");
const parse = (key) => {
    if (key.d) {
        return (0, node_crypto_1.createPrivateKey)({ format: 'jwk', key });
    }
    return (0, node_crypto_1.createPublicKey)({ format: 'jwk', key });
};
exports.default = parse;
