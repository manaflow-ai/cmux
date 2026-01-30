/**
 * Extract the names of an object's optional properties
 *
 * @param O Object
 * @return Property names
 */
export declare type OptionalProps<O extends Record<string | number | symbol, unknown>> = Exclude<{
    [K in keyof O]: undefined extends O[K] ? K : never;
}[keyof O], undefined>;
