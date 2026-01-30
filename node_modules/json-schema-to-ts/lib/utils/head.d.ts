/**
 * Returns the first element of a tuple `T`
 *
 * @param T Tuple
 * @return Type
 */
export declare type Head<T> = T extends any[] ? T[0] : never;
