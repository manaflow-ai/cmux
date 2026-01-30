import { KeyObject, createSecretKey } from 'node:crypto';
import { isCryptoKey } from './webcrypto.js';
import { checkSigCryptoKey } from '../lib/crypto_key.js';
import invalidKeyInput from '../lib/invalid_key_input.js';
import { types } from './is_key_like.js';
import * as jwk from '../lib/is_jwk.js';
export default function getSignVerifyKey(alg, key, usage) {
    if (key instanceof Uint8Array) {
        if (!alg.startsWith('HS')) {
            throw new TypeError(invalidKeyInput(key, ...types));
        }
        return createSecretKey(key);
    }
    if (key instanceof KeyObject) {
        return key;
    }
    if (isCryptoKey(key)) {
        checkSigCryptoKey(key, alg, usage);
        return KeyObject.from(key);
    }
    if (jwk.isJWK(key)) {
        if (alg.startsWith('HS')) {
            return createSecretKey(Buffer.from(key.k, 'base64url'));
        }
        return key;
    }
    throw new TypeError(invalidKeyInput(key, ...types, 'Uint8Array', 'JSON Web Key'));
}
