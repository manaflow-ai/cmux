import { A, B, U } from "ts-toolbelt";
import { Get, And, Or, Not, DoesExtend, IsObject } from "../../utils";
import { MetaType, Never, Error } from "..";
import { Const, Value as ConstValue } from "../const";
import { Object, Values, Value, Required, IsOpen, OpenProps } from "../object";
import { IsRepresentable } from "../utils";
import { Exclude } from ".";
import { ExcludeEnum } from "./enum";
import { ExcludeUnion } from "./union";
import { ExcludeIntersection } from "./intersection";
import { ExcludeExclusion } from "./exclusion";
import { CrossValue, SourceValue, IsExclusionValueRepresentable, IsOutsideOfSourceScope, IsOutsideOfExcludedScope, Propagate, IsOmittable } from "./utils";
export declare type ExcludeFromObject<S, E> = {
    any: Never;
    never: S;
    const: ExcludeConst<S, E>;
    enum: ExcludeEnum<S, E>;
    primitive: S;
    array: S;
    tuple: S;
    object: ExcludeObjects<S, E>;
    union: ExcludeUnion<S, E>;
    intersection: ExcludeIntersection<S, E>;
    exclusion: ExcludeExclusion<S, E>;
    error: E;
    errorTypeProperty: Error<"Missing type property">;
}[Get<E, "type"> extends MetaType ? Get<E, "type"> : "errorTypeProperty"];
declare type ExcludeObjects<S, E, C = CrossObjectValues<S, E>, R = RepresentableKeys<C>, P = Exclude<OpenProps<S>, OpenProps<E>>> = DoesObjectSizesMatch<S, E, C> extends true ? {
    moreThanTwo: S;
    onlyOne: PropagateExclusion<S, C>;
    none: OmitOmittableKeys<S, C>;
}[And<IsOpen<S>, IsRepresentable<P>> extends true ? "moreThanTwo" : GetUnionLength<R>] : S;
declare type CrossObjectValues<S, E> = {
    [key in keyof Values<S> | keyof Values<E> | Required<S> | Required<E>]: CrossValue<Value<S, key>, IsPossibleIn<S, key>, IsRequiredIn<S, key>, Value<E, key>, IsPossibleIn<E, key>, IsRequiredIn<E, key>>;
};
declare type GetUnionLength<Union> = A.Equals<Union, never> extends B.True ? "none" : A.Equals<U.Pop<Union>, never> extends B.True ? "onlyOne" : "moreThanTwo";
declare type IsPossibleIn<O, K> = Or<DoesExtend<K, keyof Values<O>>, IsOpen<O>>;
declare type IsRequiredIn<O, K> = DoesExtend<K, Required<O>>;
declare type DoesObjectSizesMatch<S, E, C> = And<IsOpen<S>, Not<IsOpen<E>>> extends true ? false : And<IsExcludedSmallEnough<C>, IsExcludedBigEnough<C>>;
declare type IsExcludedSmallEnough<C> = Not<DoesExtend<true, {
    [key in keyof C]: IsOutsideOfSourceScope<C[key]>;
}[keyof C]>>;
declare type IsExcludedBigEnough<C> = Not<DoesExtend<true, {
    [key in keyof C]: IsOutsideOfExcludedScope<C[key]>;
}[keyof C]>>;
declare type RepresentableKeys<C> = {
    [key in keyof C]: IsExclusionValueRepresentable<C[key]> extends true ? key : never;
}[keyof C];
declare type PropagateExclusion<S, C> = Object<{
    [key in keyof C]: Propagate<C[key]>;
}, Required<S>, IsOpen<S>, OpenProps<S>>;
declare type OmitOmittableKeys<S, C, K = OmittableKeys<C>> = {
    moreThanTwo: S;
    onlyOne: Object<{
        [key in keyof C]: key extends K ? Never : SourceValue<C[key]>;
    }, Required<S>, IsOpen<S>, OpenProps<S>>;
    none: Never;
}[GetUnionLength<K>];
declare type OmittableKeys<C> = {
    [key in keyof C]: IsOmittable<C[key]> extends true ? key : never;
}[keyof C];
declare type ExcludeConst<S, E, V = ConstValue<E>> = IsObject<V> extends true ? Exclude<S, Object<{
    [key in keyof V]: Const<V[key]>;
}, keyof V, false, Never>> : S;
export {};
