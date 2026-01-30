/**
 * Inserts an element at the start of a tuple
 *
 * @param E Element (type)
 * @param T Tuple
 * @return Tuple
 */
export declare type Prepend<E, T extends any[]> = ((element: E, ...tail: T) => void) extends (...tuple: infer R) => void ? R : never;
