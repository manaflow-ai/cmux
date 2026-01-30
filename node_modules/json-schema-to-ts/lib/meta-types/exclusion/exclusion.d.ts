import { Exclude, Value, Excluded } from ".";
export declare type ExcludeExclusion<Source, ExcludedExclusion> = Exclude<Source, Exclude<Value<ExcludedExclusion>, Excluded<ExcludedExclusion>>>;
