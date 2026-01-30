/// <reference types="node" />
/// <reference types="node" />
export default function streamToBuffer(stream: NodeJS.ReadableStream): Promise<Buffer>;
export declare function streamToBufferChunks(stream: NodeJS.ReadableStream, chunkSize?: number): Promise<Buffer[]>;
