import{a as e}from"./glassState-CvZDyIh8.js";var t=.5,n={aurora:0,drift:1,grain:2},r=[`pointermove`,`pointerdown`,`keydown`,`wheel`],i=`attribute vec2 a_pos;
void main() { gl_Position = vec4(a_pos, 0.0, 1.0); }`,a=`precision highp float;
uniform vec2 u_size;
uniform float u_time;
uniform float u_style;
uniform float u_dark;
uniform vec3 u_accent;

vec3 palette(float t, vec3 a, vec3 b, vec3 c) {
  return mix(mix(a, b, smoothstep(0.0, 0.6, t)), c, smoothstep(0.5, 1.0, t));
}

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
  vec2 uv = gl_FragCoord.xy / u_size;
  float aspect = u_size.x / max(u_size.y, 1.0);
  vec2 p = vec2(uv.x * aspect, uv.y);
  float t = u_time;
  vec3 deep = mix(vec3(0.93, 0.94, 0.97), vec3(0.04, 0.05, 0.09), u_dark);
  vec3 mid = mix(vec3(0.80, 0.84, 0.96), vec3(0.10, 0.12, 0.28), u_dark);
  vec3 hot = mix(u_accent * 0.6 + 0.4, u_accent * 0.85, u_dark);
  vec3 color;
  if (u_style < 0.5) {
    // Aurora: bands that sway and fold slowly over a deep field.
    float band = 0.0;
    for (int i = 0; i < 3; i++) {
      float fi = float(i);
      float y = 0.55 + 0.12 * sin(p.x * (1.3 + fi * 0.7) + t * (0.11 + fi * 0.05) + fi * 2.1)
                     + 0.05 * sin(p.x * 3.7 - t * 0.17 + fi);
      float d = (uv.y - y + fi * 0.09) * (7.0 + fi * 3.0);
      band += exp(-d * d) * (0.7 - fi * 0.18);
    }
    color = mix(deep, mid, uv.y * 0.6);
    color = mix(color, hot, clamp(band, 0.0, 1.0) * 0.75);
  } else {
    // Drift (and Grain): four soft blobs of the palette that wander, a mesh gradient in motion.
    vec2 c0 = vec2(0.3 * aspect + 0.15 * sin(t * 0.07), 0.3 + 0.12 * cos(t * 0.09));
    vec2 c1 = vec2(0.75 * aspect + 0.12 * cos(t * 0.06), 0.7 + 0.1 * sin(t * 0.08));
    vec2 c2 = vec2(0.6 * aspect + 0.2 * sin(t * 0.05 + 1.0), 0.2 + 0.15 * sin(t * 0.07 + 2.0));
    vec2 c3 = vec2(0.2 * aspect + 0.1 * cos(t * 0.08 + 3.0), 0.8 + 0.1 * cos(t * 0.05));
    float w0 = 1.0 / (0.02 + dot(p - c0, p - c0));
    float w1 = 1.0 / (0.02 + dot(p - c1, p - c1));
    float w2 = 1.0 / (0.02 + dot(p - c2, p - c2));
    float w3 = 1.0 / (0.02 + dot(p - c3, p - c3));
    vec3 warm = mix(vec3(0.98, 0.80, 0.70), vec3(0.45, 0.12, 0.30), u_dark);
    color = (deep * w0 + hot * w1 + mid * w2 + warm * w3) / (w0 + w1 + w2 + w3);
    if (u_style > 1.5) {
      // Grain: a fine film grain that changes with each frame, under 3% so text stays clean.
      color += (hash(gl_FragCoord.xy + fract(t) * 91.0) - 0.5) * 0.05;
    }
  }
  gl_FragColor = vec4(color, 1.0);
}`;function o(e){let t=e.getContext(`webgl`,{alpha:!1,antialias:!1,depth:!1,stencil:!1,preserveDrawingBuffer:!1,powerPreference:`low-power`});if(!t)return null;let n=(e,n)=>{let r=t.createShader(e);return r?(t.shaderSource(r,n),t.compileShader(r),t.getShaderParameter(r,t.COMPILE_STATUS)?r:null):null},r=n(t.VERTEX_SHADER,i),o=n(t.FRAGMENT_SHADER,a),s=t.createProgram(),c=()=>(t.getExtension(`WEBGL_lose_context`)?.loseContext(),null);if(!r||!o||!s||(t.attachShader(s,r),t.attachShader(s,o),t.bindAttribLocation(s,0,`a_pos`),t.linkProgram(s),!t.getProgramParameter(s,t.LINK_STATUS)))return c();t.useProgram(s);let l=t.createBuffer();return t.bindBuffer(t.ARRAY_BUFFER,l),t.bufferData(t.ARRAY_BUFFER,new Float32Array([-1,-1,3,-1,-1,3]),t.STATIC_DRAW),t.enableVertexAttribArray(0),t.vertexAttribPointer(0,2,t.FLOAT,!1,0,0),{gl:t,uniforms:{u_size:t.getUniformLocation(s,`u_size`),u_time:t.getUniformLocation(s,`u_time`),u_style:t.getUniformLocation(s,`u_style`),u_dark:t.getUniformLocation(s,`u_dark`),u_accent:t.getUniformLocation(s,`u_accent`)}}}function s(e){let t=e.documentElement.dataset.cmuxMotion;return t===`off`||t===`reduced`||e.defaultView?.matchMedia?.(`(prefers-reduced-motion: reduce)`).matches===!0}function c(e){let t=e.createElement(`span`);t.style.cssText=`position:absolute;width:0;height:0;visibility:hidden;color:var(--cmux-accent, rgb(90 120 255))`,e.documentElement.append(t);let n=e.defaultView?.getComputedStyle(t).color.match(/[\d.]+/g);return t.remove(),!n||n.length<3?[.35,.47,1]:[Number(n[0])/255,Number(n[1])/255,Number(n[2])/255]}function l(i,a){let l=i.defaultView;if(!l)return null;let u=i.documentElement,d=i.createElement(`canvas`);d.setAttribute(`aria-hidden`,`true`),d.dataset.cmuxLiveBackground=a,d.style.cssText=`position:fixed;inset:0;width:100%;height:100%;z-index:var(--layer-backdrop, -1);pointer-events:none;contain:strict;`;let f=o(d);if(!f)return null;let{gl:p,uniforms:m}=f;u.prepend(d),u.setAttribute(e,a);let h=0,g=0,_=0,v=l.performance.now(),y=!1,b=0,x=0,S=c(i),C=()=>{let e=u.dataset.theme;return e===`light`||e===`dark`?e===`dark`:l.matchMedia?.(`(prefers-color-scheme: light)`).matches!==!0},w=()=>{let e=Math.max(1,Math.round(u.clientWidth*t)),n=Math.max(1,Math.round(u.clientHeight*t));d.width!==e&&(d.width=e),d.height!==n&&(d.height=n)},T=e=>{y||(p.viewport(0,0,d.width,d.height),p.uniform2f(m.u_size,d.width,d.height),p.uniform1f(m.u_time,e),p.uniform1f(m.u_style,n[a]),p.uniform1f(m.u_dark,+!!C()),p.uniform3f(m.u_accent,S[0],S[1],S[2]),p.drawArrays(p.TRIANGLES,0,3),g++)},E=()=>!y&&!i.hidden&&!s(i)&&l.performance.now()-v<3e4,D=e=>b+(h?(e-x)/1e3:0),O=e=>{E()?(h=0,e-_>=1e3/30-1&&(_=e,T(b+(e-x)/1e3)),h=l.requestAnimationFrame(O)):(b+=(e-x)/1e3,h=0)},k=()=>{!h&&E()&&(x=l.performance.now(),h=l.requestAnimationFrame(O))},A=()=>{h&&(l.cancelAnimationFrame(h),h=0,b+=(l.performance.now()-x)/1e3)},j=()=>{v=l.performance.now(),k()},M=()=>i.hidden?A():k(),N=()=>{w(),T(D(l.performance.now()))},P=e=>{e.preventDefault(),y=!0,A()};for(let e of r)l.addEventListener(e,j,{passive:!0,capture:!0});return i.addEventListener(`visibilitychange`,M),l.addEventListener(`resize`,N),d.addEventListener(`webglcontextlost`,P),w(),T(0),k(),{frames:()=>g,running:()=>h!==0,uninstall(){A();for(let e of r)l.removeEventListener(e,j,{capture:!0});i.removeEventListener(`visibilitychange`,M),l.removeEventListener(`resize`,N),d.removeEventListener(`webglcontextlost`,P),p.getExtension(`WEBGL_lose_context`)?.loseContext(),d.remove(),u.removeAttribute(e)}}}export{l as installLiveBackground};