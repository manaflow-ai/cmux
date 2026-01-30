import { Exclude } from ".";
import { ClearIntersections } from "../intersection";
export declare type ExcludeIntersection<Source, ExcludedIntersection> = Exclude<Source, ClearIntersections<ExcludedIntersection>>;
