import { Head } from "./head";
import { Tail } from "./tail";
import { Prepend } from "./prepend";
/**
 * Reverses a tuple `T`
 *
 * @param T Tuple
 * @return Tuple
 */
export declare type Reverse<T, R extends any[] = []> = {
    stop: R;
    continue: T extends any[] ? Reverse<Tail<T>, Prepend<Head<T>, R>> : never;
}[T extends [any, ...any[]] ? "continue" : "stop"];
