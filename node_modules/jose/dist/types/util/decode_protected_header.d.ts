import type { JWSHeaderParameters, JWEHeaderParameters } from '../types';
export type ProtectedHeaderParameters = JWSHeaderParameters & JWEHeaderParameters;
/**
 * Decodes the Protected Header of a JWE/JWS/JWT token utilizing any JOSE serialization.
 *
 * This function is exported (as a named export) from the main `'jose'` module entry point as well
 * as from its subpath export `'jose/decode/protected_header'`.
 *
 * @param token JWE/JWS/JWT token in any JOSE serialization.
 */
export declare function decodeProtectedHeader(token: string | object): ProtectedHeaderParameters;
