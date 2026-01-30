import type { JWSHeaderParameters, JWTClaimVerificationOptions, JWTPayload } from '../types';
import { ProduceJWT } from './produce';
export interface UnsecuredResult<PayloadType = JWTPayload> {
    payload: PayloadType & JWTPayload;
    header: JWSHeaderParameters;
}
/**
 * The UnsecuredJWT class is a utility for dealing with `{ "alg": "none" }` Unsecured JWTs.
 *
 * This class is exported (as a named export) from the main `'jose'` module entry point as well as
 * from its subpath export `'jose/jwt/unsecured'`.
 *
 */
export declare class UnsecuredJWT extends ProduceJWT {
    /** Encodes the Unsecured JWT. */
    encode(): string;
    /**
     * Decodes an unsecured JWT.
     *
     * @param jwt Unsecured JWT to decode the payload of.
     * @param options JWT Claims Set validation options.
     */
    static decode<PayloadType = JWTPayload>(jwt: string, options?: JWTClaimVerificationOptions): UnsecuredResult<PayloadType>;
}
