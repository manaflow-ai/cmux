import { Head } from "./head";
import { Tail } from "./tail";
/**
 * Returns the value at key `K` in object `O`, `F` if `K` misses from object
 *
 * @param O Object
 * @param K Property key
 * @param F _(optional:_ `never` _)_ Fallback type
 * @return Type
 */
export declare type Get<O, K, F = never> = K extends keyof O ? O[K] : F;
/**
 * Returns the value at path `P` in object `O`, `F` if `P` misses from object
 *
 * @param O Object
 * @param P Path
 * @param F _(optional:_ `never` _)_ Fallback type
 * @return Type
 */
export declare type DeepGet<O, P, F = never> = {
    continue: Head<P> extends keyof O ? DeepGet<O[Head<P>], Tail<P>, F> : F;
    stop: O;
}[P extends [any, ...any[]] ? "continue" : "stop"];
