import { createPrivateKey, createPublicKey } from 'node:crypto';
const parse = (key) => {
    if (key.d) {
        return createPrivateKey({ format: 'jwk', key });
    }
    return createPublicKey({ format: 'jwk', key });
};
export default parse;
