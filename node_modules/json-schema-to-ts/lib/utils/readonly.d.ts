/**
 * Recursively add the `readonly` directive from an object properties or tuple items
 *
 * @param O Object / Tuple
 * @return Object / Tuple
 */
export declare type DeepReadonly<O> = O extends object ? {
    readonly [K in keyof O]: DeepReadonly<O[K]>;
} : O;
