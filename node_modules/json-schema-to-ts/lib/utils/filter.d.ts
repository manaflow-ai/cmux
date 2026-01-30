import { Head } from "./head";
import { Tail } from "./tail";
import { Prepend } from "./prepend";
import { Reverse } from "./reverse";
/**
 * Filters out the values of a tuple `T` that don't extend type `F`
 *
 * Preserves the tuple original order
 *
 * @param T Tuple
 * @param F Type
 * @return Tuple
 */
export declare type FilterExtending<T, F, R extends any[] = []> = {
    continue: FilterExtending<Tail<T>, F, Head<T> extends F ? Prepend<Head<T>, R> : R>;
    stop: Reverse<R>;
}[T extends [any, ...any[]] ? "continue" : "stop"];
