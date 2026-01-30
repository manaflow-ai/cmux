/**
 * Recursively remove the `readonly` directive from an object properties or tuple items
 *
 * @param O Object / Tuple
 * @return Object / Tuple
 */
export declare type DeepWriteable<O> = O extends object ? {
    -readonly [K in keyof O]: DeepWriteable<O[K]>;
} : O;
