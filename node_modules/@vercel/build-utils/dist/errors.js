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
var errors_exports = {};
__export(errors_exports, {
  NowBuildError: () => NowBuildError,
  getPrettyError: () => getPrettyError
});
module.exports = __toCommonJS(errors_exports);
class NowBuildError extends Error {
  constructor({ message, code, link, action }) {
    super(message);
    this.hideStackTrace = true;
    this.code = code;
    this.link = link;
    this.action = action;
  }
}
function getPrettyError(obj) {
  const docsUrl = "https://vercel.com/docs/concepts/projects/project-configuration";
  try {
    const { dataPath, params, message: ajvMessage } = obj;
    const prop = getTopLevelPropertyName(dataPath);
    let message = dataPath && dataPath.startsWith(".") ? `\`${dataPath.slice(1)}\` ` : "";
    if (params && typeof params.additionalProperty === "string") {
      const suggestion = getSuggestion(prop, params.additionalProperty);
      message += `should NOT have additional property \`${params.additionalProperty}\`. ${suggestion}`;
    } else if (params && typeof params.missingProperty === "string") {
      message += `missing required property \`${params.missingProperty}\`.`;
    } else {
      message += `${ajvMessage}.`;
    }
    return new NowBuildError({
      code: "INVALID_VERCEL_CONFIG",
      message,
      link: prop ? `${docsUrl}#${prop.toLowerCase()}` : docsUrl,
      action: "View Documentation"
    });
  } catch (e) {
    return new NowBuildError({
      code: "INVALID_VERCEL_CONFIG",
      message: `Failed to validate configuration.`,
      link: docsUrl,
      action: "View Documentation"
    });
  }
}
function getTopLevelPropertyName(dataPath) {
  if (dataPath && dataPath.startsWith(".")) {
    const lastIndex = dataPath.indexOf("[");
    return lastIndex > -1 ? dataPath.slice(1, lastIndex) : dataPath.slice(1);
  }
  return "";
}
const mapTypoToSuggestion = {
  "": {
    builder: "builds",
    "build.env": '{ "build": { "env": {"name": "value"} } }',
    "builds.env": '{ "build": { "env": {"name": "value"} } }'
  },
  rewrites: { src: "source", dest: "destination" },
  redirects: { src: "source", dest: "destination", status: "statusCode" },
  headers: { src: "source", header: "headers" },
  routes: {
    source: "src",
    destination: "dest",
    header: "headers",
    method: "methods"
  }
};
function getSuggestion(topLevelProp, additionalProperty) {
  const choices = mapTypoToSuggestion[topLevelProp];
  const choice = choices ? choices[additionalProperty] : void 0;
  return choice ? `Did you mean \`${choice}\`?` : "Please remove it.";
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  NowBuildError,
  getPrettyError
});
