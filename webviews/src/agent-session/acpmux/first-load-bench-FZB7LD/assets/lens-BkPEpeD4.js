import{n as e}from"./backdrop-CzRsvrxQ.js";import{n as t,r as n}from"./experiment-CIaKlrn7.js";import{a as r,c as i,i as a,l as o,n as s,o as c,r as l,s as u,t as d,u as f}from"./glassState-CvZDyIh8.js";function p(e,t,n){if(n===`webgl2`)return`#version 300 es
precision highp float;
`+e.replaceAll(`ATTR `,`in `).replaceAll(`VARY `,t===`vertex`?`out `:`in `).replace(`OUT_DECL`,`out vec4 cmuxColor;`).replaceAll(`OUT_COLOR`,`cmuxColor`).replaceAll(`SAMPLE(`,`textureLod(`);let r=n===`webgl1-lod`&&t===`fragment`;return(r?`#extension GL_EXT_shader_texture_lod : enable
`:``)+`precision highp float;
`+e.replaceAll(`ATTR `,`attribute `).replaceAll(`VARY `,`varying `).replace(`OUT_DECL`,``).replaceAll(`OUT_COLOR`,`gl_FragColor`).replaceAll(`SAMPLE(`,r?`texture2DLodEXT(`:`texture2D(`)}var m=`
uniform sampler2D u_tex;
uniform vec4 u_art;
uniform vec2 u_texSize;
uniform vec4 u_tint;
uniform vec4 u_surface;
uniform vec3 u_veil;
uniform vec3 u_ink;
uniform float u_adapt;
uniform float u_pass;
uniform float u_margin;
uniform float u_dpr;
uniform float u_ior;
uniform vec3 u_pointer;
VARY vec2 v_p;
VARY vec4 v_rect;
VARY vec4 v_clip;
VARY vec4 v_shape;
VARY vec4 v_extra;
OUT_DECL

float sdRound(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - (b - r);
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

vec3 tap(vec2 p, float lod) {
  vec2 uv = clamp((p - u_art.xy) / u_art.zw, vec2(0.0), vec2(1.0));
  return SAMPLE(u_tex, uv, lod).rgb;
}

// The mip level whose footprint reads like a gaussian of sigma CSS px over the prefiltered still.
float lodFor(float sigma) {
  float texels = sigma * u_texSize.x / u_art.z;
  return texels < 0.6 ? 0.0 : log2(texels * 2.5);
}

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

void main() {
  vec2 halfSize = v_rect.zw * 0.5;
  vec2 center = v_rect.xy + halfSize;
  vec2 lp = v_p - center;
  float minHalf = min(halfSize.x, halfSize.y);
  float r = min(v_shape.x, minHalf);
  float sd = sdRound(lp, halfSize, r);
  bool inClip = v_p.x >= v_clip.x && v_p.y >= v_clip.y && v_p.x < v_clip.z && v_p.y < v_clip.w;
  if (u_pass < 0.5) {
    // The copy around the glass, fading out: what is already under the page (one texel).
    if (inClip && sd < 0.0) discard;
    float fade = 1.0 - smoothstep(0.0, u_margin, max(sd, 0.0));
    if (fade <= 0.0) discard;
    vec3 around = mix(tap(v_p, 0.0), u_tint.rgb, u_tint.a);
    around = mix(around, u_surface.rgb, u_surface.a);
    OUT_COLOR = vec4(around * fade, fade);
    return;
  }
  if (!inClip || sd >= 0.0) discard;
  float alpha = clamp(-sd * u_dpr, 0.0, 1.0) * v_extra.x;
  float energy = v_extra.w;
  // The slab: refraction (CSS px) is its thickness; the rim band is where its height rises.
  float thickness = v_shape.y * (1.0 + 0.25 * energy);
  float band = min(minHalf, max(thickness * 2.6, 10.0));
  float t = clamp(-sd / band, 0.0, 1.0);
  // Convex superellipse height h = (1 - (1 - t)^3)^(1/3), and its slope dh/dt: steep at the rim,
  // flat a third of the band in, so the bend is a rim, not a bowl.
  float k = 1.0 - t;
  float k3 = k * k * k;
  float h = pow(max(1.0 - k3, 1e-4), 1.0 / 3.0);
  float slope = k * k * pow(max(1.0 - k3, 1e-3), -2.0 / 3.0);
  // The outward edge normal of the same box with a corner no smaller than the band (no seam).
  float rn = min(max(r, band), minHalf);
  vec2 q = abs(lp) - (halfSize - rn);
  vec2 n = (q.x > 0.0 && q.y > 0.0) ? normalize(q) : (q.x > q.y ? vec2(1.0, 0.0) : vec2(0.0, 1.0));
  n *= vec2(lp.x < 0.0 ? -1.0 : 1.0, lp.y < 0.0 ? -1.0 : 1.0);
  // The surface normal: the height falls toward the rim, so it tips outward by the slope.
  vec3 N = normalize(vec3(n * min(slope * 1.2, 6.0), 1.0));
  // Snell: the eye ray (straight in) bends at the surface and crosses the slab to the back face.
  vec3 R = refract(vec3(0.0, 0.0, -1.0), N, 1.0 / u_ior);
  // The ray crosses more glass at the rim than in the middle; at the very rim it shifts about
  // the thickness, a third of the band in about a fifth of it.
  float depth = thickness * (1.3 - 0.7 * h);
  vec2 shift = R.xy / max(-R.z, 0.2) * depth;
  // Lensing: the middle reads the wallpaper a little closer, as a thick lens does.
  vec2 base = v_p - lp * (v_extra.z + 0.02 * energy);
  float sigma = v_shape.z;
  float lod = lodFor(sigma);
  vec2 at = base + shift;
  vec3 color;
  float d = v_shape.w;
  if (d > 0.0 && t < 1.0) {
    // Dispersion on the rim only: each channel refracts by its own index.
    color = vec3(tap(base + shift * (1.0 - d), lod).r, tap(at, lod).g, tap(base + shift * (1.0 + d), lod).b);
  } else {
    color = tap(at, lod);
  }
  color = mix(color, u_tint.rgb, u_tint.a);
  color = mix(color, u_surface.rgb, u_surface.a);
  // Adaptive veil: the backdrop under this glass against the text color; where they are close, the
  // theme's surface comes up under the text, else it stays clear. The worst of five coarse texels
  // (the middle and each quadrant's middle), not one average of the whole glass: the glass lab
  // (2026-11-19, b8cadc3c) found a dark average leaving the veil at 4% over bright swirls that set
  // the worst text pixel (selected rows 3.90:1 over a bright painting, 4.02:1 over a dark one).
  vec2 lodSpan = v_rect.zw * u_texSize / u_art.zw;
  float quarterLod = log2(max(max(lodSpan.x, lodSpan.y) * 0.5, 1.0)) - 1.0;
  float inkLuma = luma(u_ink);
  float gap = abs(luma(mix(tap(center, quarterLod + 1.0), u_tint.rgb, u_tint.a)) - inkLuma);
  vec2 quad = halfSize * 0.5;
  gap = min(gap, abs(luma(mix(tap(center + vec2(-quad.x, -quad.y), quarterLod), u_tint.rgb, u_tint.a)) - inkLuma));
  gap = min(gap, abs(luma(mix(tap(center + vec2(quad.x, -quad.y), quarterLod), u_tint.rgb, u_tint.a)) - inkLuma));
  gap = min(gap, abs(luma(mix(tap(center + vec2(-quad.x, quad.y), quarterLod), u_tint.rgb, u_tint.a)) - inkLuma));
  gap = min(gap, abs(luma(mix(tap(center + vec2(quad.x, quad.y), quarterLod), u_tint.rgb, u_tint.a)) - inkLuma));
  float veil = u_adapt * clamp((0.62 - gap) / 0.42, 0.0, 1.0);
  color = mix(color, u_veil, veil);
  // Light: a key light (above, a little left, swung toward the pointer when it is near this glass)
  // and a fainter fill from the far side, on a band at the rim; a Fresnel sheen where the slab tilts.
  float gloss = v_extra.y;
  if (gloss > 0.0) {
    vec2 key = normalize(vec2(-0.42, -1.0));
    vec2 toPointer = u_pointer.xy - center;
    float near = u_pointer.z * (1.0 - smoothstep(minHalf, minHalf + 420.0, length(toPointer)));
    if (near > 0.0 && dot(toPointer, toPointer) > 1.0) key = normalize(mix(key, normalize(toPointer), near));
    float facing = dot(n, key);
    float rimWidth = max(1.5, min(band * 0.32, 6.0));
    float rim = 1.0 - smoothstep(0.0, rimWidth, -sd);
    float fresnel = pow(1.0 - N.z, 2.0);
    float light = pow(max(facing, 0.0), 1.6) + 0.35 * pow(max(-facing, 0.0), 2.5);
    float lit = (rim * light * 0.7 + fresnel * (0.18 + 0.22 * max(facing, 0.0))) * gloss * (1.0 + 0.6 * energy);
    color += vec3(lit);
    // The far side of the rim shades a little, so the rim reads on a bright backdrop too.
    color *= 1.0 - rim * 0.12 * max(-facing, 0.0) * gloss;
  }
  OUT_COLOR = vec4(min(color, vec3(1.0)) * alpha, alpha);
}`,h=`
ATTR vec2 a_pos;
VARY vec2 v_uv;
void main() {
  v_uv = a_pos;
  gl_Position = vec4(a_pos * 2.0 - 1.0, 0.0, 1.0);
}`,g=`
uniform sampler2D u_src;
uniform vec2 u_step;
uniform float u_lod;
VARY vec2 v_uv;
OUT_DECL
void main() {
  vec3 sum = SAMPLE(u_src, v_uv, u_lod).rgb * 0.2270;
  sum += (SAMPLE(u_src, v_uv + u_step, u_lod).rgb + SAMPLE(u_src, v_uv - u_step, u_lod).rgb) * 0.1945;
  sum += (SAMPLE(u_src, v_uv + 2.0 * u_step, u_lod).rgb + SAMPLE(u_src, v_uv - 2.0 * u_step, u_lod).rgb) * 0.1216;
  sum += (SAMPLE(u_src, v_uv + 3.0 * u_step, u_lod).rgb + SAMPLE(u_src, v_uv - 3.0 * u_step, u_lod).rgb) * 0.0541;
  OUT_COLOR = vec4(sum / 0.9674, 1.0);
}`,_=`data-glass-engine`,v=`data-glass-engine-draws`,y=[`u_veil`,`u_ink`,`u_adapt`,`u_ior`,`u_pointer`],b=1.5,x=.6,S=class e{gl;explicitLod;program;quad;step;lod;targets=null;runs=0;constructor(e,t,n,r){this.gl=e,this.explicitLod=r,this.program=t,this.quad=n,this.step=e.getUniformLocation(t,`u_step`),this.lod=e.getUniformLocation(t,`u_lod`),e.useProgram(t),e.uniform1i(e.getUniformLocation(t,`u_src`),0)}static create(t,n){let r=w(t,t.VERTEX_SHADER,p(h,`vertex`,n)),i=w(t,t.FRAGMENT_SHADER,p(g,`fragment`,n)),a=t.createProgram(),o=t.createBuffer();return!r||!i||!a||!o||(t.attachShader(a,r),t.attachShader(a,i),t.bindAttribLocation(a,0,`a_pos`),t.linkProgram(a),!t.getProgramParameter(a,t.LINK_STATUS))?null:(t.bindBuffer(t.ARRAY_BUFFER,o),t.bufferData(t.ARRAY_BUFFER,new Float32Array([0,0,1,0,0,1,0,1,1,0,1,1]),t.STATIC_DRAW),new e(t,a,o,n!==`webgl1`))}run(e,t,n,r){if(r<.6)return{texture:e,size:[t,n]};let i=this.gl,a=Math.max(0,Math.floor(Math.log2(r/2))),o=Math.max(1,t>>a),s=Math.max(1,n>>a),c=r/2**a,l=this.targetsFor(o,s);if(!l)return{texture:e,size:[t,n]};this.runs++,i.useProgram(this.program),i.bindBuffer(i.ARRAY_BUFFER,this.quad);for(let e=1;e<5;e++)i.disableVertexAttribArray(e);i.enableVertexAttribArray(0),i.vertexAttribPointer(0,2,i.FLOAT,!1,8,0),i.disable(i.BLEND),i.viewport(0,0,o,s),i.activeTexture(i.TEXTURE0);let u=c/2.4,d=[[e,l[0],u/o,0,this.explicitLod?a:0],[l[0].texture,l[1],0,u/s,0]];for(let[e,t,n,r,a]of d)i.bindFramebuffer(i.FRAMEBUFFER,t.framebuffer),i.bindTexture(i.TEXTURE_2D,e),i.uniform2f(this.step,n,r),i.uniform1f(this.lod,a),i.drawArrays(i.TRIANGLES,0,6);return i.bindFramebuffer(i.FRAMEBUFFER,null),i.bindTexture(i.TEXTURE_2D,l[1].texture),i.texParameteri(i.TEXTURE_2D,i.TEXTURE_MIN_FILTER,i.LINEAR_MIPMAP_LINEAR),i.generateMipmap(i.TEXTURE_2D),i.enable(i.BLEND),{texture:l[1].texture,size:[o,s]}}targetsFor(e,t){let n=this.targets;if(n&&n[0].width===e&&n[0].height===t)return n;this.release();let r=C(this.gl,e,t),i=C(this.gl,e,t);return!r||!i?null:(this.targets=[r,i],this.targets)}release(){for(let e of this.targets??[])this.gl.deleteFramebuffer(e.framebuffer),this.gl.deleteTexture(e.texture);this.targets=null}};function C(e,t,n){let r=e.createTexture(),i=e.createFramebuffer();if(!r||!i)return null;e.bindTexture(e.TEXTURE_2D,r),e.texImage2D(e.TEXTURE_2D,0,e.RGBA,t,n,0,e.RGBA,e.UNSIGNED_BYTE,null),e.texParameteri(e.TEXTURE_2D,e.TEXTURE_MIN_FILTER,e.LINEAR),e.texParameteri(e.TEXTURE_2D,e.TEXTURE_MAG_FILTER,e.LINEAR),e.texParameteri(e.TEXTURE_2D,e.TEXTURE_WRAP_S,e.CLAMP_TO_EDGE),e.texParameteri(e.TEXTURE_2D,e.TEXTURE_WRAP_T,e.CLAMP_TO_EDGE),e.bindFramebuffer(e.FRAMEBUFFER,i),e.framebufferTexture2D(e.FRAMEBUFFER,e.COLOR_ATTACHMENT0,e.TEXTURE_2D,r,0);let a=e.checkFramebufferStatus(e.FRAMEBUFFER)===e.FRAMEBUFFER_COMPLETE;return e.bindFramebuffer(e.FRAMEBUFFER,null),a?{framebuffer:i,texture:r,width:t,height:n}:(e.deleteFramebuffer(i),e.deleteTexture(r),null)}function w(e,t,n){let r=e.createShader(t);return r?(e.shaderSource(r,n),e.compileShader(r),!e.getShaderParameter(r,e.COMPILE_STATUS)&&!e.isContextLost()?(console.warn(`cmux glass engine: shader`,e.getShaderInfoLog(r)),null):r):null}var T=.28,E=.5,D=class{onMove;value=[0,0,0];target=[0,0,0];doc=null;constructor(e){this.onMove=e}attach(e){this.doc||(this.doc=e,e.addEventListener(`pointermove`,this.onPointer,{passive:!0}),e.documentElement.addEventListener(`pointerleave`,this.onLeave,{passive:!0}))}detach(){this.doc?.removeEventListener(`pointermove`,this.onPointer),this.doc?.documentElement.removeEventListener(`pointerleave`,this.onLeave),this.doc=null,this.value[2]=0,this.target[2]=0}step(){let e=this.value,t=this.target,n=t[0]-e[0],r=t[1]-e[1],i=t[2]-e[2];return Math.abs(n)<E&&Math.abs(r)<E&&Math.abs(i)<.01?(e[0]=t[0],e[1]=t[1],e[2]=t[2],!1):(e[0]+=n*T,e[1]+=r*T,e[2]+=i*T,!0)}onPointer=e=>{this.target[2]===0&&(this.value[0]=e.clientX,this.value[1]=e.clientY),this.target=[e.clientX,e.clientY,1],this.onMove()};onLeave=()=>{this.target[2]=0,this.onMove()}};function O(e,t){let n=e.getAttribute(`data-cmux-motion`);return n===`off`||n===`reduced`||typeof t.matchMedia==`function`&&t.matchMedia(`(prefers-reduced-motion: reduce)`).matches}function k(e,t){return Math.max(e*.85,Math.min(1,t/40))}var A=t({id:`glass-engine`,title:`Glass engine`,description:`The lens's glass as a refracting slab: Snell refraction through a superellipse rim, a key light that follows the pointer, a Fresnel sheen, a veil that rises only where the wallpaper fights the text, and a flex when the glass moves. Compare the rim, the light and the text over the busy part of the wallpaper.`,arms:{off:{label:`Lens`,description:`The lens as it ships: quarter-circle bend, fixed rim light, fixed tint.`},on:{label:`Engine`,description:`The glass engine over the same still.`}},defaultArm:`off`}),j=32,M=48,N=240,P=20,F=18,I=6,L=1024,R=`(prefers-reduced-transparency: reduce)`,z=`
ATTR vec2 a_pos;
ATTR vec4 a_rect;
ATTR vec4 a_clip;
ATTR vec4 a_shape;
ATTR vec4 a_extra;
uniform vec2 u_view;
VARY vec2 v_p;
VARY vec4 v_rect;
VARY vec4 v_clip;
VARY vec4 v_shape;
VARY vec4 v_extra;
void main() {
  v_p = a_pos;
  v_rect = a_rect;
  v_clip = a_clip;
  v_shape = a_shape;
  v_extra = a_extra;
  vec2 ndc = a_pos / u_view * 2.0 - 1.0;
  gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
}`,B=`
uniform sampler2D u_tex;
uniform vec4 u_art;
uniform vec2 u_texSize;
uniform float u_artBlur;
uniform vec4 u_tint;
uniform vec4 u_surface;
uniform float u_pass;
uniform float u_margin;
uniform float u_dpr;
VARY vec2 v_p;
VARY vec4 v_rect;
VARY vec4 v_clip;
VARY vec4 v_shape;
VARY vec4 v_extra;
OUT_DECL

float sdRound(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - (b - r);
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

vec3 tap(vec2 p, float lod) {
  vec2 uv = clamp((p - u_art.xy) / u_art.zw, vec2(0.0), vec2(1.0));
  return SAMPLE(u_tex, uv, lod).rgb;
}

// A gaussian-like blur of sigma CSS px: the mip level about a quarter of sigma, then a center and
// two rings of taps, so it reads smooth with no blocky mips.
vec3 frosted(vec2 p, float sigma) {
  float texels = sigma * u_texSize.x / u_art.z;
  if (texels < 0.6) return tap(p, 0.0);
  float lod = max(0.0, log2(texels) - 1.5);
  vec3 sum = tap(p, lod) * 0.16;
  float a = sigma * 0.7;
  float b = sigma * 1.6;
  sum += (tap(p + vec2(a, 0.0), lod) + tap(p - vec2(a, 0.0), lod) + tap(p + vec2(0.0, a), lod) + tap(p - vec2(0.0, a), lod)) * 0.13;
  vec2 d = vec2(b, b) * 0.7071;
  sum += (tap(p + d, lod) + tap(p - d, lod) + tap(p + vec2(d.x, -d.y), lod) + tap(p - vec2(d.x, -d.y), lod)) * 0.08;
  return sum;
}

void main() {
  vec2 halfSize = v_rect.zw * 0.5;
  vec2 lp = v_p - (v_rect.xy + halfSize);
  float minHalf = min(halfSize.x, halfSize.y);
  float r = min(v_shape.x, minHalf);
  float sd = sdRound(lp, halfSize, r);
  bool inClip = v_p.x >= v_clip.x && v_p.y >= v_clip.y && v_p.x < v_clip.z && v_p.y < v_clip.w;
  vec3 color;
  float alpha;
  if (u_pass < 0.5) {
    // The copy around the glass, fading out: what is already under the page.
    if (inClip && sd < 0.0) discard;
    alpha = 1.0 - smoothstep(0.0, u_margin, max(sd, 0.0));
    if (alpha <= 0.0) discard;
    color = frosted(v_p, u_artBlur);
  } else {
    if (!inClip || sd >= 0.0) discard;
    alpha = clamp(-sd * u_dpr, 0.0, 1.0) * v_extra.x;
    float refraction = v_shape.y;
    float band = min(minHalf, max(refraction * 3.0, 8.0));
    float t = clamp(-sd / band, 0.0, 1.0);
    float bend = refraction * (1.0 - sqrt(max(0.0, t * (2.0 - t))));
    // The edge normal of the same box with a corner no smaller than the band: smooth everywhere
    // the bend reaches, with no seam along the diagonals.
    float rn = min(max(r, band), minHalf);
    vec2 q = abs(lp) - (halfSize - rn);
    vec2 n = (q.x > 0.0 && q.y > 0.0) ? normalize(q) : (q.x > q.y ? vec2(1.0, 0.0) : vec2(0.0, 1.0));
    n *= vec2(lp.x < 0.0 ? -1.0 : 1.0, lp.y < 0.0 ? -1.0 : 1.0);
    float sigma = sqrt(u_artBlur * u_artBlur + v_shape.z * v_shape.z);
    float d = v_shape.w;
    // Magnify: the center reads the wallpaper a little closer, as a thick lens does.
    vec2 base = v_p - lp * v_extra.z;
    vec2 at = base - n * bend;
    if (d > 0.0) {
      color = vec3(
        frosted(at, sigma).r,
        frosted(base - n * bend * (1.0 + d), sigma).g,
        frosted(base - n * bend * (1.0 + 2.0 * d), sigma).b);
    } else {
      color = frosted(at, sigma);
    }
    color = mix(color, u_tint.rgb, u_tint.a);
    color = mix(color, u_surface.rgb, u_surface.a);
    // Gloss: the rim facing the light (above, a little left) catches a bright line that thins
    // away round the corners, the opposite rim a fainter one, as light through a thick edge.
    // No texture taps: a few ALU ops per rim pixel.
    float gloss = v_extra.y;
    if (gloss > 0.0) {
      float facing = dot(n, normalize(vec2(-0.42, -1.0)));
      float rim = 1.0 - smoothstep(0.0, max(1.5, min(band * 0.4, 7.0)), -sd);
      float light = pow(max(facing, 0.0), 2.0) + 0.4 * pow(max(-facing, 0.0), 3.0);
      color += vec3(rim * light * gloss * 0.6);
    }
    OUT_COLOR = vec4(min(color, vec3(1.0)) * alpha, alpha);
    return;
  }
  color = mix(color, u_tint.rgb, u_tint.a);
  color = mix(color, u_surface.rgb, u_surface.a);
  OUT_COLOR = vec4(color * alpha, alpha);
}`;function V(e,t,n){let r=e.createShader(t);return r?(e.shaderSource(r,n),e.compileShader(r),!e.getShaderParameter(r,e.COMPILE_STATUS)&&!e.isContextLost()?(console.warn(`cmux glass lens: shader`,e.getShaderInfoLog(r)),null):r):null}function H(e,t){let n={alpha:!0,premultipliedAlpha:!0,antialias:!1,depth:!1,stencil:!1,preserveDrawingBuffer:!1,powerPreference:`low-power`},r=e.getContext(`webgl2`,n),i=r??e.getContext(`webgl`,n);if(!i)return null;let a=r?`webgl2`:i.getExtension(`EXT_shader_texture_lod`)?`webgl1-lod`:`webgl1`,o=V(i,i.VERTEX_SHADER,p(z,`vertex`,a)),s=V(i,i.FRAGMENT_SHADER,p(t?m:B,`fragment`,a)),c=i.createProgram();if(!o||!s||!c)return null;if(i.attachShader(c,o),i.attachShader(c,s),[`a_pos`,`a_rect`,`a_clip`,`a_shape`,`a_extra`].forEach((e,t)=>i.bindAttribLocation(c,t,e)),i.linkProgram(c),!i.getProgramParameter(c,i.LINK_STATUS))return console.warn(`cmux glass lens: link`,i.getProgramInfoLog(c)),null;let l=i.createBuffer(),u=i.createTexture();if(!l||!u)return null;let d=t?S.create(i,a):null;if(t&&!d)return H(e,!1);i.bindBuffer(i.ARRAY_BUFFER,l),i.bufferData(i.ARRAY_BUFFER,13824,i.DYNAMIC_DRAW),U(i,c,l);let f={};for(let e of[`u_view`,`u_tex`,`u_art`,`u_texSize`,`u_artBlur`,`u_tint`,`u_surface`,`u_pass`,`u_margin`,`u_dpr`,...y])f[e]=i.getUniformLocation(c,e);return i.uniform1i(f.u_tex,0),i.uniform1f(f.u_margin,M),i.enable(i.BLEND),i.blendFunc(i.ONE,i.ONE_MINUS_SRC_ALPHA),i.activeTexture(i.TEXTURE0),i.bindTexture(i.TEXTURE_2D,u),{gl:i,program:c,buffer:l,texture:u,uniforms:f,engine:t,prefilter:d,sampled:u}}function U(e,t,n){e.useProgram(t),e.bindBuffer(e.ARRAY_BUFFER,n);let r=[2,4,4,4,4],i=0;r.forEach((t,n)=>{e.enableVertexAttribArray(n),e.vertexAttribPointer(n,t,e.FLOAT,!1,72,i*4),i+=t})}function W(e,t){let n=Number.parseFloat(e);return Number.isFinite(n)?n:t}function G(e,t){let n=1;for(let r=e;r&&n>0;r=r.parentElement)n*=W(t.getComputedStyle(r).opacity,1);return n}var K=class{doc;view;root;glass;reduceQuery;mode=`plain`;backdrop;capable=!0;armed=!1;running=!1;canvas=null;gpu=null;image=null;imageKey=null;textureReady=!1;textureSize=[1,1];surfaces=new WeakMap;observed=new Set;resizeObserver=null;mutations;rootWatch;width=0;height=0;dpr=1;frame=0;stable=0;hot=!1;needsDraw=!0;current=new Float32Array(3456);next=new Float32Array(3456);currentCount=-1;clip=new Float64Array(4);tint={r:0,g:0,b:0,a:0};surface={r:0,g:0,b:0,a:0};ink={r:0,g:0,b:0,a:1};veil={r:0,g:0,b:0,a:1};engineArm=n(A);engine=!1;held=!1;filteredBlur=NaN;light=new D(()=>this.invalidate());draws=0;rects=0;constructor(e){this.doc=e,this.view=e.defaultView,this.root=e.documentElement,this.glass=e.getElementsByClassName(l),this.backdrop=o(this.view),this.reduceQuery=typeof this.view.matchMedia==`function`?this.view.matchMedia(R):null,this.reduceQuery?.addEventListener(`change`,this.reconcile),this.view.addEventListener(d,this.onBackdrop),this.view.addEventListener(`cmux-theme`,this.onTheme),this.rootWatch=new MutationObserver(this.reconcile),this.rootWatch.observe(this.root,{attributes:!0,attributeFilter:[s,c,r,_,`data-cmux-motion`,`data-reduce-transparency`]}),this.mutations=new MutationObserver(this.onMutations),this.reconcile()}state(){return{mode:this.mode,armed:this.armed,running:this.running,drawing:this.drawing(),draws:this.draws,rects:this.rects,engine:this.running&&this.gpu?.engine===!0,prefilterRuns:this.gpu?.prefilter?.runs??0}}drawCost(e){let t=this.gpu;if(!this.drawing()||!t)return null;let n=this.measure(),r=this.current;this.current=this.next,this.next=r,this.currentCount=n;let i=new Uint8Array(4),a=performance.now();for(let t=0;t<e;t++)this.draw();return t.gl.readPixels(0,0,1,1,t.gl.RGBA,t.gl.UNSIGNED_BYTE,i),(performance.now()-a)/e}drawing(){return this.running&&this.textureReady&&this.gpu!==null}reconcile=()=>{this.mode=f(this.root.getAttribute(s),this.root.hasAttribute(`data-reduce-transparency`)||this.reduceQuery?.matches===!0);let e=this.capable&&this.mode!==`plain`&&!this.root.hasAttribute(`data-glass-native`)&&!this.root.hasAttribute(`data-live-background`)&&this.backdrop.image!==null&&this.backdrop.rect!==null,t=e&&(this.engineArm===`on`||this.root.hasAttribute(`data-glass-engine`));this.held=O(this.root,this.view),this.running&&t!==this.engine&&this.stop(),this.engine=t,this.running&&this.gpu?.engine&&(this.held?this.light.detach():this.light.attach(this.doc)),e!==this.armed&&(this.armed=e,e?this.mutations.observe(this.root,{childList:!0,subtree:!0,attributes:!0,attributeFilter:[`class`,`style`]}):this.mutations.disconnect()),e?(this.glass.length>0?(this.loadImage(),this.start()):this.stop(),this.markAllStale(),this.invalidate()):(this.stop(),this.image=null,this.imageKey=null)};onBackdrop=()=>{this.backdrop=o(this.view),this.running&&this.readColors(),this.running&&this.gpu?.engine&&this.backdrop.blur!==this.filteredBlur&&this.uploadTexture(),this.needsDraw=!0,this.reconcile()};onTheme=()=>{this.running&&(this.readColors(),this.markAllStale(),this.invalidate())};onMutations=e=>{if(!this.running)this.glass.length>0&&this.reconcile();else if(this.glass.length===0)this.stop();else{for(let t of e){if(t.type===`childList`){let e=t.target.children;for(let t=0;e&&t<e.length;t++){let n=e[t];n.classList.contains(`ui-glass`)&&this.markStale(n)}continue}if(t.type!==`attributes`||t.attributeName!==`class`)continue;let e=t.target;e.classList.contains(`ui-glass`)?this.markStale(e):e.getElementsByClassName(`ui-glass`).length>0&&this.markAllStale()}this.invalidate()}};onScroll=()=>this.invalidate();onMotion=()=>{this.hot=!0,this.invalidate()};onResize=()=>{this.resize(),this.invalidate()};onContextLost=e=>{e.target===this.canvas&&(e.preventDefault(),this.gpu=null,this.textureReady=!1,this.root.removeAttribute(a))};onContextRestored=()=>{this.canvas&&(this.gpu=H(this.canvas,this.engine),this.filteredBlur=NaN,this.uploadTexture(),this.invalidate())};start(){if(this.running)return;let e=this.doc.createElement(`canvas`);e.setAttribute(`aria-hidden`,`true`),e.dataset.cmuxGlassLens=``,e.style.cssText=`position:fixed;inset:0;width:100%;height:100%;z-index:var(--layer-backdrop, -1);pointer-events:none;contain:strict;`;let t=H(e,this.engine);t?(this.canvas=e,this.gpu=t,e.addEventListener(`webglcontextlost`,this.onContextLost),e.addEventListener(`webglcontextrestored`,this.onContextRestored),this.root.append(e),this.running=!0,this.surfaces=new WeakMap,this.resizeObserver=new ResizeObserver(e=>{for(let t of e)this.markStale(t.target);this.invalidate()}),this.doc.addEventListener(`scroll`,this.onScroll,{capture:!0,passive:!0}),this.view.addEventListener(`resize`,this.onResize),this.doc.addEventListener(`transitionrun`,this.onMotion,{capture:!0,passive:!0}),this.doc.addEventListener(`animationstart`,this.onMotion,{capture:!0,passive:!0}),t.engine&&!this.held&&this.light.attach(this.doc),this.readColors(),this.resize(),this.uploadTexture()):(this.capable=!1,this.reconcile())}stop(){this.running&&(this.running=!1,this.frame&&this.view.cancelAnimationFrame(this.frame),this.frame=0,this.doc.removeEventListener(`scroll`,this.onScroll,{capture:!0}),this.view.removeEventListener(`resize`,this.onResize),this.doc.removeEventListener(`transitionrun`,this.onMotion,{capture:!0}),this.doc.removeEventListener(`animationstart`,this.onMotion,{capture:!0}),this.resizeObserver?.disconnect(),this.resizeObserver=null,this.observed.clear(),this.light.detach(),this.gpu?.prefilter?.release(),this.filteredBlur=NaN,this.root.removeAttribute(v),this.canvas?.removeEventListener(`webglcontextlost`,this.onContextLost),this.canvas?.removeEventListener(`webglcontextrestored`,this.onContextRestored),this.gpu?.gl.getExtension(`WEBGL_lose_context`)?.loseContext(),this.gpu=null,this.textureReady=!1,this.canvas?.remove(),this.canvas=null,this.currentCount=-1,this.root.removeAttribute(a))}loadImage(){let{image:e,key:t}=this.backdrop,n=t??e;if(!e||n===this.imageKey)return;this.imageKey=n,this.textureReady=!1;let r=new Image;r.decoding=`async`,r.src=e,r.decode().then(()=>{this.imageKey===n&&(this.image=r,this.uploadTexture(),this.invalidate())},()=>{this.imageKey===n&&(this.image=null)})}uploadTexture(){let e=this.gpu,t=this.image;if(!e||!t||!t.naturalWidth)return;let n=i(Math.min(t.naturalWidth,L),L),r=i(Math.min(t.naturalHeight,L),L),o=this.doc.createElement(`canvas`);o.width=n,o.height=r;let s=o.getContext(`2d`);if(!s)return;s.imageSmoothingQuality=`high`,s.drawImage(t,0,0,n,r);let{gl:c}=e;if(c.bindTexture(c.TEXTURE_2D,e.texture),c.pixelStorei(c.UNPACK_PREMULTIPLY_ALPHA_WEBGL,!1),c.texImage2D(c.TEXTURE_2D,0,c.RGBA,c.RGBA,c.UNSIGNED_BYTE,o),c.texParameteri(c.TEXTURE_2D,c.TEXTURE_MIN_FILTER,c.LINEAR_MIPMAP_LINEAR),c.texParameteri(c.TEXTURE_2D,c.TEXTURE_MAG_FILTER,c.LINEAR),c.texParameteri(c.TEXTURE_2D,c.TEXTURE_WRAP_S,c.CLAMP_TO_EDGE),c.texParameteri(c.TEXTURE_2D,c.TEXTURE_WRAP_T,c.CLAMP_TO_EDGE),c.generateMipmap(c.TEXTURE_2D),o.width=0,this.textureSize=[n,r],e.prefilter&&this.backdrop.rect){let t=this.backdrop.blur*n/this.backdrop.rect.width,i=e.prefilter.run(e.texture,n,r,t);e.sampled=i.texture,this.textureSize=i.size,this.filteredBlur=this.backdrop.blur,U(c,e.program,e.buffer),this.root.setAttribute(v,``)}this.textureReady=!0,this.needsDraw=!0,this.root.setAttribute(a,``)}readColors(){let t=this.doc.createElement(`span`);t.style.cssText=`position:absolute;width:0;height:0;visibility:hidden;pointer-events:none`,this.root.append(t);let n=n=>(t.style.backgroundColor=``,t.style.backgroundColor=n,e(this.view.getComputedStyle(t).backgroundColor)??{r:0,g:0,b:0,a:0});this.tint=n(this.backdrop.tint||`transparent`),this.surface=n(`var(--cmux-surface-background, transparent)`),this.ink=n(`var(--cmux-text, CanvasText)`),this.veil=n(`var(--glass-surface, Canvas)`),t.remove(),this.needsDraw=!0}resize(){if(!this.canvas)return;this.width=this.root.clientWidth||this.view.innerWidth,this.height=this.root.clientHeight||this.view.innerHeight,this.dpr=Math.min(2,Math.max(1,this.view.devicePixelRatio||1));let e=Math.max(1,Math.round(this.width*this.dpr)),t=Math.max(1,Math.round(this.height*this.dpr));this.canvas.width!==e&&(this.canvas.width=e),this.canvas.height!==t&&(this.canvas.height=t),this.needsDraw=!0}markStale(e){let t=this.surfaces.get(e);t&&(t.stale=!0)}markAllStale(){this.surfaces=new WeakMap}invalidate(){this.stable=0,this.running&&!this.frame&&(this.frame=this.view.requestAnimationFrame(this.tick))}refresh(e,t){let n=this.view.getComputedStyle(e),r=n.getPropertyValue(`--glass-join`).trim(),i=r===`top`||r===`both`,a=r===`bottom`||r===`both`,o=i&&a?`0px`:i?n.borderBottomLeftRadius:n.borderTopLeftRadius,s=t??{radius:0,radiusFraction:0,joinTop:!1,joinBottom:!1,refraction:0,blur:0,dispersion:0,gloss:0,magnify:0,opacity:1,visible:!0,clippers:[],stale:!1,cx:NaN,cy:NaN,energy:0};s.joinTop=i,s.joinBottom=a,s.radiusFraction=o.endsWith(`%`)?W(o,0)/100:0,s.radius=s.radiusFraction?0:W(o,0),s.refraction=Math.max(0,W(n.getPropertyValue(`--glass-refraction`),14)),s.blur=Math.max(0,W(n.getPropertyValue(`--glass-blur`),6)),s.dispersion=this.mode===`spectrum`?Math.max(0,W(n.getPropertyValue(`--glass-dispersion`),0)):0,s.gloss=Math.min(1,Math.max(0,W(n.getPropertyValue(`--glass-gloss`),0))),s.magnify=Math.min(.2,Math.max(0,W(n.getPropertyValue(`--glass-magnify`),0))),s.visible=n.visibility!==`hidden`&&n.display!==`none`,s.clippers.length=0;let c=n.position===`fixed`;for(let t=e.parentElement;t&&!c&&t!==this.doc.body&&t!==this.root;t=t.parentElement){let e=this.view.getComputedStyle(t);(e.overflowX!==`visible`||e.overflowY!==`visible`)&&s.clippers.push(t),c=e.position===`fixed`}return s.opacity=G(e,this.view),s.stale=!1,this.surfaces.set(e,s),this.observed.has(e)||(this.observed.add(e),this.resizeObserver?.observe(e)),s}measure(){let e=this.next,t=this.clip,n=this.width,r=this.height,i=0;for(let a=0;a<this.glass.length&&i<j;a++){let o=this.glass[a],s=this.surfaces.get(o);if(!s||s.stale?s=this.refresh(o,s):this.hot&&(s.opacity=G(o,this.view)),!s.visible||s.opacity<=.002)continue;let c=o.getBoundingClientRect();if(c.width<=0||c.height<=0||c.right+M<0||c.bottom+M<0||c.left-M>n||c.top-M>r)continue;t[0]=0,t[1]=0,t[2]=n,t[3]=r;let l=!0;for(let e=0;e<s.clippers.length&&l;e++){let n=s.clippers[e].getBoundingClientRect();t[0]=Math.max(t[0],n.left),t[1]=Math.max(t[1],n.top),t[2]=Math.min(t[2],n.right),t[3]=Math.min(t[3],n.bottom),l=t[2]>t[0]&&t[3]>t[1]}let u=c.top,d=c.bottom;if(s.joinTop&&(u-=N,t[1]=Math.max(t[1],c.top)),s.joinBottom&&(d+=N,t[3]=Math.min(t[3],c.bottom)),l&&=t[3]>t[1],!l)continue;let f=s.radiusFraction?s.radiusFraction*Math.min(c.width,c.height):s.radius;if(this.engine){let e=c.left+c.width/2,t=c.top+c.height/2,n=Number.isNaN(s.cx)||this.held?0:Math.hypot(e-s.cx,t-s.cy);s.energy=this.held?0:k(s.energy,n),s.energy<.01?s.energy=0:this.needsDraw=!0,s.cx=e,s.cy=t}let p=Math.max(0,c.left-M),m=Math.max(0,u-M),h=Math.min(n,c.right+M),g=Math.min(r,d+M),_=i*I*F;for(let n=0;n<I;n++){let r=n===1||n===4||n===5,i=n===2||n===3||n===5;e[_++]=r?h:p,e[_++]=i?g:m,e[_++]=c.left,e[_++]=u,e[_++]=c.width,e[_++]=d-u,e[_++]=t[0],e[_++]=t[1],e[_++]=t[2],e[_++]=t[3],e[_++]=f,e[_++]=s.refraction,e[_++]=s.blur,e[_++]=s.dispersion,e[_++]=Math.min(1,s.opacity),e[_++]=s.gloss,e[_++]=s.magnify,e[_++]=s.energy}i++}return i}tick=()=>{if(this.frame=0,!this.running)return;let e=this.measure();this.engine&&this.light.step()&&(this.needsDraw=!0);let t=e!==this.currentCount;if(!t){let n=e*I*F;for(let e=0;e<n;e++)if(this.next[e]!==this.current[e]){t=!0;break}}if(t){let t=this.current;this.current=this.next,this.next=t,this.currentCount=e}if((t||this.needsDraw)&&this.drawing())this.draw(),this.stable=0;else if(++this.stable>=P){this.hot=!1,this.prune();return}this.frame=this.view.requestAnimationFrame(this.tick)};prune(){for(let e of this.observed)e.isConnected||(this.observed.delete(e),this.resizeObserver?.unobserve(e))}draw(){let e=this.gpu,{gl:t,uniforms:n}=e,r=this.backdrop.rect;if(this.needsDraw=!1,this.draws++,this.rects=this.currentCount,t.viewport(0,0,t.drawingBufferWidth,t.drawingBufferHeight),t.clearColor(0,0,0,0),t.clear(t.COLOR_BUFFER_BIT),this.currentCount<=0)return;if(t.bindBuffer(t.ARRAY_BUFFER,e.buffer),t.bufferSubData(t.ARRAY_BUFFER,0,this.current),t.uniform2f(n.u_view,this.width,this.height),t.uniform4f(n.u_art,r.x,r.y,r.width,r.height),t.uniform2f(n.u_texSize,this.textureSize[0],this.textureSize[1]),t.uniform1f(n.u_artBlur,this.backdrop.blur),t.uniform4f(n.u_tint,this.tint.r/255,this.tint.g/255,this.tint.b/255,this.tint.a),t.uniform4f(n.u_surface,this.surface.r/255,this.surface.g/255,this.surface.b/255,this.surface.a),t.uniform1f(n.u_dpr,this.dpr),e.engine){let[r,i,a]=this.light.value;t.bindTexture(t.TEXTURE_2D,e.sampled),t.uniform3f(n.u_veil,this.veil.r/255,this.veil.g/255,this.veil.b/255),t.uniform3f(n.u_ink,this.ink.r/255,this.ink.g/255,this.ink.b/255),t.uniform1f(n.u_adapt,x),t.uniform1f(n.u_ior,b),t.uniform3f(n.u_pointer,r,i,this.held?0:a)}let i=this.currentCount*I;t.uniform1f(n.u_pass,0),t.drawArrays(t.TRIANGLES,0,i),t.uniform1f(n.u_pass,1),t.drawArrays(t.TRIANGLES,0,i)}},q=new WeakMap;function J(e=document){let t=e.defaultView;t&&!q.has(e)&&(u(t),typeof MutationObserver==`function`&&typeof ResizeObserver==`function`&&q.set(e,new K(e)))}export{J as installGlassLens};