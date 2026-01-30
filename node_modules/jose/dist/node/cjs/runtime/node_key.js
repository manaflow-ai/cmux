"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.default = keyForCrypto;
const node_crypto_1 = require("node:crypto");
const get_named_curve_js_1 = require("./get_named_curve.js");
const errors_js_1 = require("../util/errors.js");
const check_key_length_js_1 = require("./check_key_length.js");
const ecCurveAlgMap = new Map([
    ['ES256', 'P-256'],
    ['ES256K', 'secp256k1'],
    ['ES384', 'P-384'],
    ['ES512', 'P-521'],
]);
function keyForCrypto(alg, key) {
    let asymmetricKeyType;
    let asymmetricKeyDetails;
    let isJWK;
    if (key instanceof node_crypto_1.KeyObject) {
        asymmetricKeyType = key.asymmetricKeyType;
        asymmetricKeyDetails = key.asymmetricKeyDetails;
    }
    else {
        isJWK = true;
        switch (key.kty) {
            case 'RSA':
                asymmetricKeyType = 'rsa';
                break;
            case 'EC':
                asymmetricKeyType = 'ec';
                break;
            case 'OKP': {
                if (key.crv === 'Ed25519') {
                    asymmetricKeyType = 'ed25519';
                    break;
                }
                if (key.crv === 'Ed448') {
                    asymmetricKeyType = 'ed448';
                    break;
                }
                throw new TypeError('Invalid key for this operation, its crv must be Ed25519 or Ed448');
            }
            default:
                throw new TypeError('Invalid key for this operation, its kty must be RSA, OKP, or EC');
        }
    }
    let options;
    switch (alg) {
        case 'EdDSA':
            if (!['ed25519', 'ed448'].includes(asymmetricKeyType)) {
                throw new TypeError('Invalid key for this operation, its asymmetricKeyType must be ed25519 or ed448');
            }
            break;
        case 'RS256':
        case 'RS384':
        case 'RS512':
            if (asymmetricKeyType !== 'rsa') {
                throw new TypeError('Invalid key for this operation, its asymmetricKeyType must be rsa');
            }
            (0, check_key_length_js_1.default)(key, alg);
            break;
        case 'PS256':
        case 'PS384':
        case 'PS512':
            if (asymmetricKeyType === 'rsa-pss') {
                const { hashAlgorithm, mgf1HashAlgorithm, saltLength } = asymmetricKeyDetails;
                const length = parseInt(alg.slice(-3), 10);
                if (hashAlgorithm !== undefined &&
                    (hashAlgorithm !== `sha${length}` || mgf1HashAlgorithm !== hashAlgorithm)) {
                    throw new TypeError(`Invalid key for this operation, its RSA-PSS parameters do not meet the requirements of "alg" ${alg}`);
                }
                if (saltLength !== undefined && saltLength > length >> 3) {
                    throw new TypeError(`Invalid key for this operation, its RSA-PSS parameter saltLength does not meet the requirements of "alg" ${alg}`);
                }
            }
            else if (asymmetricKeyType !== 'rsa') {
                throw new TypeError('Invalid key for this operation, its asymmetricKeyType must be rsa or rsa-pss');
            }
            (0, check_key_length_js_1.default)(key, alg);
            options = {
                padding: node_crypto_1.constants.RSA_PKCS1_PSS_PADDING,
                saltLength: node_crypto_1.constants.RSA_PSS_SALTLEN_DIGEST,
            };
            break;
        case 'ES256':
        case 'ES256K':
        case 'ES384':
        case 'ES512': {
            if (asymmetricKeyType !== 'ec') {
                throw new TypeError('Invalid key for this operation, its asymmetricKeyType must be ec');
            }
            const actual = (0, get_named_curve_js_1.default)(key);
            const expected = ecCurveAlgMap.get(alg);
            if (actual !== expected) {
                throw new TypeError(`Invalid key curve for the algorithm, its curve must be ${expected}, got ${actual}`);
            }
            options = { dsaEncoding: 'ieee-p1363' };
            break;
        }
        default:
            throw new errors_js_1.JOSENotSupported(`alg ${alg} is not supported either by JOSE or your javascript runtime`);
    }
    if (isJWK) {
        return { format: 'jwk', key, ...options };
    }
    return options ? { ...options, key } : key;
}
