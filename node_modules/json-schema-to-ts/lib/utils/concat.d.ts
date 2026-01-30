import { Head } from "./head";
import { Tail } from "./tail";
import { Prepend } from "./prepend";
import { Reverse } from "./reverse";
/**
 * Concatenate the reverse of tuple `A` to tuple `B`
 *
 * @param A Tuple
 * @param B Tuple
 * @return Tuple
 */
export declare type ConcatReversed<A, B extends any[]> = {
    stop: B;
    continue: ConcatReversed<Tail<A>, Prepend<Head<A>, B>>;
}[A extends [any, ...any[]] ? "continue" : "stop"];
/**
 * Concatenate tuple `A` to tuple `B`
 *
 * @param A Tuple
 * @param B Tuple
 * @return Tuple
 */
export declare type Concat<A, B extends any[]> = A extends any[] ? ConcatReversed<Reverse<A>, B> : never;
