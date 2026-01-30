import { A, B } from "ts-toolbelt";
import { Get, And, Not, IsArray, Head, Tail, Prepend, Reverse } from "../../utils";
import { MetaType, Never, Error } from "..";
import { Const, Value as ConstValue } from "../const";
import { Values as ArrayValues } from "../array";
import { Tuple, Values, IsOpen, OpenProps } from "../tuple";
import { IsRepresentable } from "../utils";
import { Exclude } from ".";
import { ExcludeEnum } from "./enum";
import { ExcludeUnion } from "./union";
import { ExcludeIntersection } from "./intersection";
import { ExcludeExclusion } from "./exclusion";
import { CrossValue, SourceValue, IsExclusionValueRepresentable, IsOutsideOfSourceScope, IsOutsideOfExcludedScope, Propagate, IsOmittable } from "./utils";
export declare type ExcludeFromTuple<S, E> = {
    any: Never;
    never: S;
    const: ExcludeConst<S, E>;
    enum: ExcludeEnum<S, E>;
    primitive: S;
    array: ExcludeArray<S, E>;
    tuple: ExcludeTuples<S, E>;
    object: S;
    union: ExcludeUnion<S, E>;
    intersection: ExcludeIntersection<S, E>;
    exclusion: ExcludeExclusion<S, E>;
    error: E;
    errorMissingType: Error<"Missing type property in Exclusion excluded value">;
}[Get<E, "type"> extends MetaType ? Get<E, "type"> : "errorMissingType"];
declare type ExcludeArray<S, E> = ExcludeTuples<S, Tuple<[], true, ArrayValues<E>>>;
declare type ExcludeTuples<S, E, C = CrossTupleValues<Values<S>, Values<E>, IsOpen<S>, IsOpen<E>, OpenProps<S>, OpenProps<E>>, R = RepresentableItems<C>, P = Exclude<OpenProps<S>, OpenProps<E>>, I = IsRepresentable<P>> = DoesTupleSizesMatch<S, E, C> extends true ? {
    moreThanTwo: S;
    onlyOne: Tuple<PropagateExclusion<C>, I extends true ? IsOpen<S> : false, P>;
    none: OmitOmittableItems<S, C>;
}[And<IsOpen<S>, I> extends true ? "moreThanTwo" : GetTupleLength<R>] : S;
declare type CrossTupleValues<V1, V2, O1, O2, P1, P2, R extends any[] = []> = {
    stop: Reverse<R>;
    continue1: CrossTupleValues<Tail<V1>, [], O1, O2, P1, P2, Prepend<CrossValue<Head<V1>, true, true, P2, O2, false>, R>>;
    continue2: CrossTupleValues<[], Tail<V2>, O1, O2, P1, P2, Prepend<CrossValue<P1, O1, false, Head<V2>, true, true>, R>>;
    continueBoth: CrossTupleValues<Tail<V1>, Tail<V2>, O1, O2, P1, P2, Prepend<CrossValue<Head<V1>, true, true, Head<V2>, true, true>, R>>;
}[V1 extends [any, ...any[]] ? V2 extends [any, ...any[]] ? "continueBoth" : "continue1" : V2 extends [any, ...any[]] ? "continue2" : "stop"];
declare type GetTupleLength<T> = A.Equals<T, []> extends B.True ? "none" : A.Equals<Tail<T>, []> extends B.True ? "onlyOne" : "moreThanTwo";
declare type DoesTupleSizesMatch<S, E, C> = And<IsOpen<S>, Not<IsOpen<E>>> extends true ? false : And<IsExcludedSmallEnough<C>, IsExcludedBigEnough<C>>;
declare type IsExcludedSmallEnough<C> = {
    stop: true;
    continue: IsOutsideOfSourceScope<Head<C>> extends true ? false : IsExcludedSmallEnough<Tail<C>>;
}[C extends [any, ...any[]] ? "continue" : "stop"];
declare type IsExcludedBigEnough<C> = {
    stop: true;
    continue: IsOutsideOfExcludedScope<Head<C>> extends true ? false : IsExcludedBigEnough<Tail<C>>;
}[C extends [any, ...any[]] ? "continue" : "stop"];
declare type RepresentableItems<C, R extends any[] = []> = {
    stop: R;
    continue: IsExclusionValueRepresentable<Head<C>> extends true ? RepresentableItems<Tail<C>, Prepend<Head<C>, R>> : RepresentableItems<Tail<C>, R>;
}[C extends [any, ...any[]] ? "continue" : "stop"];
declare type PropagateExclusion<C, R extends any[] = []> = {
    stop: Reverse<R>;
    continue: PropagateExclusion<Tail<C>, Prepend<Propagate<Head<C>>, R>>;
}[C extends [any, ...any[]] ? "continue" : "stop"];
declare type OmitOmittableItems<S, C, I = OmittableItems<C>> = {
    moreThanTwo: S;
    onlyOne: Tuple<RequiredTupleValues<S, C>, false, OpenProps<S>>;
    none: Never;
}[GetTupleLength<I>];
declare type OmittableItems<C, R extends any[] = []> = {
    stop: R;
    continue: IsOmittable<Head<C>> extends true ? OmittableItems<Tail<C>, Prepend<Head<C>, R>> : OmittableItems<Tail<C>, R>;
}[C extends [any, ...any[]] ? "continue" : "stop"];
declare type RequiredTupleValues<S, C, R extends any[] = []> = {
    stop: Reverse<R>;
    continue: IsOmittable<Head<C>> extends true ? Reverse<R> : RequiredTupleValues<Tail<S>, Tail<C>, Prepend<SourceValue<Head<C>>, R>>;
}[C extends [any, ...any[]] ? "continue" : "stop"];
declare type ExcludeConst<S, E, V = ConstValue<E>> = IsArray<V> extends true ? Exclude<S, Tuple<ExtractConstValues<V>, false, Never>> : S;
declare type ExtractConstValues<V, R extends any[] = []> = {
    stop: Reverse<R>;
    continue: ExtractConstValues<Tail<V>, Prepend<Const<Head<V>>, R>>;
}[V extends [any, ...any[]] ? "continue" : "stop"];
export {};
