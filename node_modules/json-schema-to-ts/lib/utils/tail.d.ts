/**
 * Remove the first element of a tuple
 *
 * @param T Tuple
 * @return Tuple
 */
export declare type Tail<T> = T extends any[] ? ((...args: T) => void) extends (head: any, ...tail: infer R) => void ? R : T : never;
