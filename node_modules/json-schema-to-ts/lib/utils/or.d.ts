/**
 * Return `true` if `A` or `B` extend `true`, `false` otherwise
 *
 * @param A Type
 * @param B Type
 * @return Boolean
 */
export declare type Or<A, B> = A extends true ? true : B extends true ? true : false;
