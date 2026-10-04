/* tslint:disable */
/* eslint-disable */

/**
 * One agent's memory state in the MemoryDO.
 */
export class OptChat {
    free(): void;
    [Symbol.dispose](): void;
    /**
     * Appends one message (already stored) and returns its id.
     */
    append(): number;
    /**
     * The compactor call for node (l, i) as JSON `{system, context, step}`.
     * `prompt` is `taelin`, `cmux` or `custom` (then `custom` is its text).
     */
    compactRequest(store: any, l: number, i: number, prompt: string, custom: string, agent: string): string;
    complete(l: number, i: number, text: string): void;
    fail(l: number, i: number): void;
    first(): number;
    isEmpty(): boolean;
    len(): number;
    /**
     * Rebuilds after a restart: `t` messages and the built nodes as JSON
     * `[[l, i, bytes], ...]`.
     */
    static load(t: number, built_json: string, budget: number): OptChat;
    /**
     * A new, empty memory with a view budget in bytes (`VIEW` when 0).
     */
    constructor(budget: number);
    /**
     * Work to do now, as JSON: `[{kind: "free", l, i, text} | {kind: "model", l, i}]`.
     */
    pump(store: any): string;
    /**
     * The rendered view as JSON `{text, marks}` (marks are byte offsets into the UTF-8 text).
     */
    renderView(store: any): string;
    settled(): boolean;
    viewSize(): number;
    /**
     * The view parts as JSON `[{l, i, name}]`.
     */
    view(): string;
    /**
     * `zoom(id, n)`; throws "No line id+n." when refused.
     */
    zoom(store: any, id: number, n: number): string;
}

/**
 * The size loop (section 4.3) on the replies so far (JSON array of strings):
 * JSON `{accept: string} | {retry: string} | {fail: true}`.
 */
export function sizeCheck(tries_json: string): string;

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly __wbg_optchat_free: (a: number, b: number) => void;
    readonly optchat_append: (a: number) => number;
    readonly optchat_compactRequest: (a: number, b: any, c: number, d: number, e: number, f: number, g: number, h: number, i: number, j: number) => [number, number];
    readonly optchat_complete: (a: number, b: number, c: number, d: number, e: number) => void;
    readonly optchat_fail: (a: number, b: number, c: number) => void;
    readonly optchat_first: (a: number) => number;
    readonly optchat_isEmpty: (a: number) => number;
    readonly optchat_len: (a: number) => number;
    readonly optchat_load: (a: number, b: number, c: number, d: number) => [number, number, number];
    readonly optchat_new: (a: number) => number;
    readonly optchat_pump: (a: number, b: any) => [number, number];
    readonly optchat_renderView: (a: number, b: any) => [number, number];
    readonly optchat_settled: (a: number) => number;
    readonly optchat_view: (a: number) => [number, number];
    readonly optchat_viewSize: (a: number) => number;
    readonly optchat_zoom: (a: number, b: any, c: number, d: number) => [number, number, number, number];
    readonly sizeCheck: (a: number, b: number) => [number, number, number, number];
    readonly __wbindgen_malloc: (a: number, b: number) => number;
    readonly __wbindgen_realloc: (a: number, b: number, c: number, d: number) => number;
    readonly __wbindgen_externrefs: WebAssembly.Table;
    readonly __wbindgen_free: (a: number, b: number, c: number) => void;
    readonly __externref_table_dealloc: (a: number) => void;
    readonly __wbindgen_start: () => void;
}

export type SyncInitInput = BufferSource | WebAssembly.Module;

/**
 * Instantiates the given `module`, which can either be bytes or
 * a precompiled `WebAssembly.Module`.
 *
 * @param {{ module: SyncInitInput }} module - Passing `SyncInitInput` directly is deprecated.
 *
 * @returns {InitOutput}
 */
export function initSync(module: { module: SyncInitInput } | SyncInitInput): InitOutput;

/**
 * If `module_or_path` is {RequestInfo} or {URL}, makes a request and
 * for everything else, calls `WebAssembly.instantiate` directly.
 *
 * @param {{ module_or_path: InitInput | Promise<InitInput> }} module_or_path - Passing `InitInput` directly is deprecated.
 *
 * @returns {Promise<InitOutput>}
 */
export default function __wbg_init (module_or_path?: { module_or_path: InitInput | Promise<InitInput> } | InitInput | Promise<InitInput>): Promise<InitOutput>;
