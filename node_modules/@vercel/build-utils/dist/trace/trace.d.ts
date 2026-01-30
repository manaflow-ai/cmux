export type SpanId = string;
export type TraceEvent = {
    parentId?: SpanId;
    name: string;
    id: SpanId;
    timestamp: number;
    duration: number;
    tags: Record<string, string>;
    startTime: number;
};
export type Reporter = {
    report: (event: TraceEvent) => void;
};
interface Attributes {
    [key: string]: string | undefined;
}
export declare class Span {
    private name;
    private id;
    private parentId?;
    private attrs;
    private status;
    private _start;
    private now;
    private _reporter;
    constructor({ name, parentId, attrs, reporter, }: {
        name: string;
        parentId?: SpanId;
        attrs?: Attributes;
        reporter?: Reporter;
    });
    stop(): void;
    setAttributes(attrs: Attributes): void;
    child(name: string, attrs?: Attributes): Span;
    trace<T>(fn: (span: Span) => T | Promise<T>): Promise<T>;
}
export {};
