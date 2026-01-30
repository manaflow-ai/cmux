"use strict";
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);
var trace_exports = {};
__export(trace_exports, {
  Span: () => Span
});
module.exports = __toCommonJS(trace_exports);
var import_node_crypto = require("node:crypto");
const NUM_OF_MICROSEC_IN_NANOSEC = BigInt("1000");
function mapUndefinedAttributes(attrs) {
  return Object.fromEntries(
    Object.entries(attrs ?? {}).filter(
      (attr) => !!attr[1]
    )
  );
}
class Span {
  constructor({
    name,
    parentId,
    attrs,
    reporter
  }) {
    this.name = name;
    this.parentId = parentId;
    this.attrs = mapUndefinedAttributes(attrs);
    this.status = "started";
    this.id = (0, import_node_crypto.randomUUID)();
    this._reporter = reporter;
    this.now = Date.now();
    this._start = process.hrtime.bigint();
  }
  stop() {
    if (this.status === "stopped") {
      throw new Error(`Cannot stop a span which is already stopped`);
    }
    this.status = "stopped";
    const end = process.hrtime.bigint();
    const duration = Number((end - this._start) / NUM_OF_MICROSEC_IN_NANOSEC);
    const timestamp = Number(this._start / NUM_OF_MICROSEC_IN_NANOSEC);
    const traceEvent = {
      name: this.name,
      duration,
      timestamp,
      id: this.id,
      parentId: this.parentId,
      tags: this.attrs,
      startTime: this.now
    };
    if (this._reporter) {
      this._reporter.report(traceEvent);
    }
  }
  setAttributes(attrs) {
    Object.assign(this.attrs, mapUndefinedAttributes(attrs));
  }
  child(name, attrs) {
    return new Span({
      name,
      parentId: this.id,
      attrs,
      reporter: this._reporter
    });
  }
  async trace(fn) {
    try {
      return await fn(this);
    } finally {
      this.stop();
    }
  }
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  Span
});
