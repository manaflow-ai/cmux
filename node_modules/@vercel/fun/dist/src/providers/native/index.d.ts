/// <reference types="node" />
import { ChildProcess } from 'child_process';
import { LambdaParams, InvokeParams, InvokeResult, Lambda, Provider } from '../../types';
export default class NativeProvider implements Provider {
    private pool;
    private lambda;
    private params;
    private runtimeApis;
    constructor(fn: Lambda, params: LambdaParams);
    createProcess(): Promise<ChildProcess>;
    destroyProcess(proc: ChildProcess): Promise<void>;
    freezeProcess(proc: ChildProcess): void;
    unfreezeProcess(proc: ChildProcess): void;
    invoke(params: InvokeParams): Promise<InvokeResult>;
    destroy(): Promise<void>;
}
