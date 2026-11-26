// The glass shaders are written once in a dialect-neutral GLSL (ATTR, VARY, OUT_DECL, OUT_COLOR,
// SAMPLE) and turned into the dialect a browser's context takes: the lens (lens.ts) and the glass
// engine (engine/) share these rules.

/** How a fragment shader reads a mip level: WebGL2's textureLod, WebGL1's EXT_shader_texture_lod,
 * or plain WebGL1, which has no explicit level in a fragment shader (a bias over the automatic one). */
export type GlassShaderDialect = "webgl2" | "webgl1-lod" | "webgl1";

export function shaderSource(source: string, kind: "vertex" | "fragment", dialect: GlassShaderDialect): string {
  if (dialect === "webgl2")
    return (
      "#version 300 es\nprecision highp float;\n" +
      source
        .replaceAll("ATTR ", "in ")
        .replaceAll("VARY ", kind === "vertex" ? "out " : "in ")
        .replace("OUT_DECL", "out vec4 cmuxColor;")
        .replaceAll("OUT_COLOR", "cmuxColor")
        .replaceAll("SAMPLE(", "textureLod(")
    );
  const lod = dialect === "webgl1-lod" && kind === "fragment";
  return (
    (lod ? "#extension GL_EXT_shader_texture_lod : enable\n" : "") +
    "precision highp float;\n" +
    source
      .replaceAll("ATTR ", "attribute ")
      .replaceAll("VARY ", "varying ")
      .replace("OUT_DECL", "")
      .replaceAll("OUT_COLOR", "gl_FragColor")
      .replaceAll("SAMPLE(", lod ? "texture2DLodEXT(" : "texture2D(")
  );
}
