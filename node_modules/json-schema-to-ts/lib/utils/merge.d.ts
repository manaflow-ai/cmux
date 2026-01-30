import { Concat } from "./concat";
import { IsObject, IsArray } from "./extends";
/**
 * Recursively merge two types `A` and `B`:
 * - Returns `B` if `A` and `B` are not both objects or arrays
 * - Recursively merge `A` and `B` properties if both are objects
 * - Concat `A` and `B` if both are arrays
 *
 * `DeepMergeUnsafe` preserves non-required properties, but can return `never` if TS infers that `A & B = never` (which can happen if some properties are incompatible)
 *
 * @param A Type
 * @param B Type
 * @return Type
 */
export declare type DeepMergeUnsafe<A, B> = IsObject<A> extends true ? IsObject<B> extends true ? {
    [K in keyof (A & B)]: K extends keyof B ? K extends keyof A ? DeepMergeUnsafe<A[K], B[K]> : B[K] : K extends keyof A ? A[K] : never;
} : B : IsArray<A> extends true ? IsArray<B> extends true ? B extends any[] ? Concat<A, B> : never : B : B;
/**
 * Recursively merge two types `A` and `B`:
 * - Returns `B` if `A` and `B` are not both objects or arrays
 * - Recursively merge `A` and `B` properties if both are objects
 * - Concat `A` and `B` if both are arrays
 *
 * Contrary to `DeepMergeUnsafe`, `DeepMergeSafe` never returns `never`, but doesn't preserve non-required properties
 *
 * @param A Type
 * @param B Type
 * @return Type
 */
export declare type DeepMergeSafe<A, B> = IsObject<A> extends true ? IsObject<B> extends true ? {
    [K in keyof A | keyof B]: K extends keyof B ? K extends keyof A ? DeepMergeSafe<A[K], B[K]> : B[K] : K extends keyof A ? A[K] : never;
} : B : IsArray<A> extends true ? IsArray<B> extends true ? B extends any[] ? Concat<A, B> : never : B : B;
/**
 * Merge two types `A` and `B`:
 * - Returns `B` if `A` and `B` are not both objects
 * - Merge `A` and `B` properties if both are objects
 * - Merging is not recursive: Properties of `B` erase properties of `A`
 *
 * @param A Type
 * @param B Type
 * @return Type
 */
export declare type Merge<A, B> = IsObject<A> extends true ? IsObject<B> extends true ? {
    [K in keyof A | keyof B]: K extends keyof B ? B[K] : K extends keyof A ? A[K] : never;
} : B : B;
