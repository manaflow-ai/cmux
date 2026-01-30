/**
 * Returns `true` if object `O` has a property key in `K` (union), `false` if not
 *
 * @param O Object
 * @param K Union of property keys
 * @return Type
 */
export declare type HasKeyIn<O, K> = Extract<keyof O, K> extends never ? false : true;
