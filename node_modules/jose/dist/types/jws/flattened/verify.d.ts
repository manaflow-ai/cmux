import type { JWK, FlattenedVerifyResult, KeyLike, FlattenedJWSInput, JWSHeaderParameters, VerifyOptions, GenericGetKeyFunction, ResolvedKey } from '../../types';
/**
 * Interface for Flattened JWS Verification dynamic key resolution. No token components have been
 * verified at the time of this function call.
 *
 * @see {@link jwks/remote.createRemoteJWKSet createRemoteJWKSet} to verify using a remote JSON Web Key Set.
 */
export interface FlattenedVerifyGetKey extends GenericGetKeyFunction<JWSHeaderParameters | undefined, FlattenedJWSInput, KeyLike | JWK | Uint8Array> {
}
/**
 * Verifies the signature and format of and afterwards decodes the Flattened JWS.
 *
 * This function is exported (as a named export) from the main `'jose'` module entry point as well
 * as from its subpath export `'jose/jws/flattened/verify'`.
 *
 * @param jws Flattened JWS.
 * @param key Key to verify the JWS with. See
 *   {@link https://github.com/panva/jose/issues/210#jws-alg Algorithm Key Requirements}.
 * @param options JWS Verify options.
 */
export declare function flattenedVerify(jws: FlattenedJWSInput, key: KeyLike | Uint8Array | JWK, options?: VerifyOptions): Promise<FlattenedVerifyResult>;
/**
 * @param jws Flattened JWS.
 * @param getKey Function resolving a key to verify the JWS with. See
 *   {@link https://github.com/panva/jose/issues/210#jws-alg Algorithm Key Requirements}.
 * @param options JWS Verify options.
 */
export declare function flattenedVerify<KeyLikeType extends KeyLike = KeyLike>(jws: FlattenedJWSInput, getKey: FlattenedVerifyGetKey, options?: VerifyOptions): Promise<FlattenedVerifyResult & ResolvedKey<KeyLikeType>>;
