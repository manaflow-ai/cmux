/// <reference types="node" />
import { Server } from 'net';
export default function listen(server: Server, ...args: any[]): Promise<string>;
