/**
 * Return `true` if `A` extends `false`, `false` if `A` extends `true`, `never` otherwise
 *
 * @param A Type
 * @return Boolean
 */
export declare type Not<A> = A extends false ? true : A extends true ? false : never;
