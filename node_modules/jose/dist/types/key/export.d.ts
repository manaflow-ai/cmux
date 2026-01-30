import type { JWK, KeyLike } from '../types';
/**
 * Exports a runtime-specific public key representation ({@link !KeyObject} or {@link !CryptoKey}) to
 * a PEM-encoded SPKI string format.
 *
 * This function is exported (as a named export) from the main `'jose'` module entry point as well
 * as from its subpath export `'jose/key/export'`.
 *
 * @param key Key representation to transform to a PEM-encoded SPKI string format.
 */
export declare function exportSPKI(key: KeyLike): Promise<string>;
/**
 * Exports a runtime-specific private key representation ({@link !KeyObject} or {@link !CryptoKey}) to
 * a PEM-encoded PKCS8 string format.
 *
 * This function is exported (as a named export) from the main `'jose'` module entry point as well
 * as from its subpath export `'jose/key/export'`.
 *
 * @param key Key representation to transform to a PEM-encoded PKCS8 string format.
 */
export declare function exportPKCS8(key: KeyLike): Promise<string>;
/**
 * Exports a runtime-specific key representation (KeyLike) to a JWK.
 *
 * This function is exported (as a named export) from the main `'jose'` module entry point as well
 * as from its subpath export `'jose/key/export'`.
 *
 * @param key Key representation to export as JWK.
 */
export declare function exportJWK(key: KeyLike | Uint8Array): Promise<JWK>;
