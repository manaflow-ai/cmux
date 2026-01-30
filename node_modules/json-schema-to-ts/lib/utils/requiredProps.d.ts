/**
 * Extract the names of an object's required properties
 *
 * @param O Object
 * @return Property names
 */
export declare type RequiredProps<O extends Record<string | number | symbol, unknown>> = Exclude<{
    [K in keyof O]: undefined extends O[K] ? never : K;
}[keyof O], undefined>;
