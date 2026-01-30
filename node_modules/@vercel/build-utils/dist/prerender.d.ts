import type { File, HasField, Chain } from './types';
import { Lambda } from './lambda';
interface PrerenderOptions {
    expiration: number | false;
    staleExpiration?: number;
    lambda?: Lambda;
    fallback: File | null;
    group?: number;
    bypassToken?: string | null;
    allowQuery?: string[];
    allowHeader?: string[];
    initialHeaders?: Record<string, string>;
    initialStatus?: number;
    passQuery?: boolean;
    sourcePath?: string;
    experimentalBypassFor?: HasField;
    experimentalStreamingLambdaPath?: string;
    chain?: Chain;
}
export declare class Prerender {
    type: 'Prerender';
    /**
     * `expiration` is `revalidate` in Next.js terms, and `s-maxage` in
     * `cache-control` terms.
     */
    expiration: number | false;
    /**
     * `staleExpiration` is `expire` in Next.js terms, and
     * `stale-while-revalidate` + `s-maxage` in `cache-control` terms. It's
     * expected to be undefined if `expiration` is `false`.
     */
    staleExpiration?: number;
    lambda?: Lambda;
    fallback: File | null;
    group?: number;
    bypassToken: string | null;
    allowQuery?: string[];
    allowHeader?: string[];
    initialHeaders?: Record<string, string>;
    initialStatus?: number;
    passQuery?: boolean;
    sourcePath?: string;
    experimentalBypassFor?: HasField;
    experimentalStreamingLambdaPath?: string;
    chain?: Chain;
    constructor({ expiration, staleExpiration, lambda, fallback, group, bypassToken, allowQuery, allowHeader, initialHeaders, initialStatus, passQuery, sourcePath, experimentalBypassFor, experimentalStreamingLambdaPath, chain, }: PrerenderOptions);
}
export {};
