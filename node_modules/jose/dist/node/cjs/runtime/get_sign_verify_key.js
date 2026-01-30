"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.default = getSignVerifyKey;
const node_crypto_1 = require("node:crypto");
const webcrypto_js_1 = require("./webcrypto.js");
const crypto_key_js_1 = require("../lib/crypto_key.js");
const invalid_key_input_js_1 = require("../lib/invalid_key_input.js");
const is_key_like_js_1 = require("./is_key_like.js");
const jwk = require("../lib/is_jwk.js");
function getSignVerifyKey(alg, key, usage) {
    if (key instanceof Uint8Array) {
        if (!alg.startsWith('HS')) {
            throw new TypeError((0, invalid_key_input_js_1.default)(key, ...is_key_like_js_1.types));
        }
        return (0, node_crypto_1.createSecretKey)(key);
    }
    if (key instanceof node_crypto_1.KeyObject) {
        return key;
    }
    if ((0, webcrypto_js_1.isCryptoKey)(key)) {
        (0, crypto_key_js_1.checkSigCryptoKey)(key, alg, usage);
        return node_crypto_1.KeyObject.from(key);
    }
    if (jwk.isJWK(key)) {
        if (alg.startsWith('HS')) {
            return (0, node_crypto_1.createSecretKey)(Buffer.from(key.k, 'base64url'));
        }
        return key;
    }
    throw new TypeError((0, invalid_key_input_js_1.default)(key, ...is_key_like_js_1.types, 'Uint8Array', 'JSON Web Key'));
}
