"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const node_crypto_1 = require("node:crypto");
exports.default = (key, alg) => {
    let modulusLength;
    try {
        if (key instanceof node_crypto_1.KeyObject) {
            modulusLength = key.asymmetricKeyDetails?.modulusLength;
        }
        else {
            modulusLength = Buffer.from(key.n, 'base64url').byteLength << 3;
        }
    }
    catch { }
    if (typeof modulusLength !== 'number' || modulusLength < 2048) {
        throw new TypeError(`${alg} requires key modulusLength to be 2048 bits or larger`);
    }
};
