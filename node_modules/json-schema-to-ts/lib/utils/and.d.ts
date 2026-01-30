/**
 * Return `true` if `A` and `B` extend `true`, `false` otherwise
 *
 * @param A Type
 * @param B Type
 * @return Boolean
 */
export declare type And<A, B> = A extends true ? B extends true ? true : false : false;
