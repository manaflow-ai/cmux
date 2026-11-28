var e=`data-cmux-scrolling`,t=`data-cmux-hidden-scroller`,n=`data-cmux-shown-scroller`,r=`data-cmux-scroller-fade`,i={property:`--cmux-shown-scroller-ink`,full:38,near:55,nearProperty:`--cmux-shown-scroller-near`},a={property:`--cmux-sideways-ink`,full:100,near:100,nearProperty:`--cmux-sideways-near`};function o(e,t){let n=e.ownerDocument.defaultView?.getComputedStyle(e).getPropertyValue(t).trim()??``,r=/^(\d*\.?\d+)(ms|s)$/.exec(n);return r?Number(r[1])*(r[2]===`s`?1e3:1):0}function s(t,n=i,a=`fade`){let{property:s,nearProperty:c,full:l}=n,u=t.ownerDocument.defaultView;if(!u?.MutationObserver||typeof u.requestAnimationFrame!=`function`||typeof u.cancelAnimationFrame!=`function`)return()=>{};let d=t.ownerDocument.documentElement;a===`thin`&&t.style.setProperty(`--cmux-shown-scroller-near-border`,`2px`);let f=()=>t.hasAttribute(`data-cmux-scroller-near`)?{ink:n.near,near:1}:{ink:d.hasAttribute(`data-cmux-scroller-fade`)&&!t.hasAttribute(`data-cmux-scrolling`)?0:l,near:0},p=f(),m=p,h=0,g=()=>{u.cancelAnimationFrame(h),p=m=f(),t.style.removeProperty(s),t.style.removeProperty(c)},_=()=>{let e=f();if(e.ink===m.ink&&e.near===m.near)return;if(a===`instant`&&(e.near===1||m.near===1))return g();m=e;let n=p,r=e.ink===n.ink?e.near>n.near:e.ink>n.ink,i=r?o(t,`--cmux-scroller-fade-in`):o(t,`--cmux-scroller-fade-out`)*1.3333333333333333;if(u.cancelAnimationFrame(h),i<=0)return g();let l,d=a=>{l??=a;let o=Math.min(1,Math.max(0,(a-l)/i));if(o>=1)return g();let f=r?1-(1-o)*(1-o):o*o*(3-2*o);p={ink:n.ink+(e.ink-n.ink)*f,near:n.near+(e.near-n.near)*f},t.style.setProperty(s,`${p.ink.toFixed(2)}%`),t.style.setProperty(c,p.near.toFixed(3)),h=u.requestAnimationFrame(d)};h=u.requestAnimationFrame(d)},v=new u.MutationObserver(_);v.observe(t,{attributes:!0,attributeFilter:[e,C]});let y=new u.MutationObserver(_);return y.observe(d,{attributes:!0,attributeFilter:[r]}),()=>{v.disconnect(),y.disconnect(),g(),a===`thin`&&t.style.removeProperty(`--cmux-shown-scroller-near-border`)}}var c={set:(e,t)=>setTimeout(e,t),clear:e=>clearTimeout(e)},l=new WeakMap;function u(t,n=c){let r=l.get(t);r!==void 0&&n.clear(r),t.hasAttribute(`data-cmux-hidden-scroller`)?(l.delete(t),t.removeAttribute(e)):(t.hasAttribute(`data-cmux-scrolling`)||t.setAttribute(e,``),l.set(t,n.set(()=>{l.delete(t),t.removeAttribute(e)},800)))}function d(e,t,n){let r=n!==0&&e.scrollHeight>e.clientHeight,i=t!==0&&e.scrollWidth>e.clientWidth;if(!r&&!i)return!1;let a=e.ownerDocument.defaultView?.getComputedStyle(e);if(!a)return!1;let o=e=>e===`auto`||e===`scroll`||e===`overlay`;return r&&o(a.overflowY)||i&&o(a.overflowX)}function f(e){for(let t of e.composedPath()){let n=t;if(typeof n.getAttribute==`function`&&typeof n.scrollHeight==`number`&&d(n,e.deltaX,e.deltaY))return n}return null}var p=new WeakSet,m=new WeakMap,h=new WeakMap;function g(e){return h.get(e)??null}var _=new Set([`PageUp`,`PageDown`,`Home`,`End`,`ArrowUp`,`ArrowDown`,`ArrowLeft`,`ArrowRight`,` `,`Spacebar`]);function v(e){let t=e;return t.tagName===`INPUT`||t.tagName===`TEXTAREA`||t.isContentEditable===!0}function y(e,t){let n=e;return n.tagName===`SELECT`||(t===` `||t===`Spacebar`)&&(n.tagName===`BUTTON`||n.getAttribute?.(`role`)===`button`)}function b(e,t){let n=e.path?.[0]??e.target;if(!n||typeof n.nodeType!=`number`)return!0;for(let r of e.path??[n])if(r.nodeType===1&&t.contains(r))return!0;return e.key===`Tab`||e.key!==void 0&&_.has(e.key)&&!v(n)&&!y(n,e.key)}function x(e,t,n){return t!==void 0&&n-t.at<=800?b(t,e):!e.hasAttribute(`data-cmux-shown-scroller`)&&!e.hasAttribute(`data-cmux-minimal-scroller`)}function S(e,t=c){if(p.has(e))return;p.add(e),e.addEventListener(`wheel`,e=>{let n=f(e);n&&u(n,t)},{capture:!0,passive:!0});let n=()=>e.defaultView?.performance.now()??Date.now(),r=t=>m.set(e,{at:n(),target:t.target,path:t.composedPath?.(),key:t.type===`keydown`?t.key:void 0});for(let t of[`wheel`,`keydown`,`pointerdown`])e.addEventListener(t,r,{capture:!0,passive:!0});e.addEventListener(`scroll`,r=>{let i=r.target;i===e?h.set(e,e.documentElement):i&&`setAttribute`in i&&h.set(e,i),i===e?x(e.documentElement,m.get(e),n())&&u(e.documentElement,t):i&&`setAttribute`in i&&x(i,m.get(e),n())&&u(i,t)},{capture:!0,passive:!0})}var C=`data-cmux-scroller-near`,w=`data-cmux-resize-handle`,T=`[${w}]`,E={[w]:``},ee=`
:root {
  --cmux-resize-handle-layer: calc(var(--layer-raised, 1) + 1);
}
:root ${T} {
  z-index: var(--cmux-resize-handle-layer);
}
`;function te(e){let t=e;return typeof t.matches==`function`&&t.matches(`[data-cmux-resize-handle]`)}function ne(e){return e.hasAttribute(`data-cmux-scrolling`)?!0:e.hasAttribute(`data-cmux-minimal-scroller`)&&e.hasAttribute(`data-cmux-scroller-settling`)||e.ownerDocument.documentElement.hasAttribute(`data-cmux-scroller-fade`)?!1:e.hasAttribute(`data-cmux-shown-scroller`)||e.hasAttribute(`data-cmux-sideways`)}function D(e){let t=e.ownerDocument.defaultView?.getComputedStyle(e),n=e=>Number.parseFloat(t?.[`border${e}Width`]??``)||0;return{left:n(`Left`),right:n(`Right`),top:n(`Top`),bottom:n(`Bottom`)}}function O(e,t){let n=e.ownerDocument,r=n.defaultView,i=e;if(e===n.documentElement)return r?Math.max(0,t===`y`?r.innerWidth-i.clientWidth:r.innerHeight-i.clientHeight):0;let a=D(e);return Math.max(0,t===`y`?i.offsetWidth-i.clientWidth-a.left-a.right:i.offsetHeight-i.clientHeight-a.top-a.bottom)}function k(e,t,n,r){return r>0&&n<e.bottom&&n>=e.bottom-r&&t>=e.left&&t<e.right}function A(e,t,n,r){return r>0&&t<e.right&&t>=e.right-r&&n>=e.top&&n<e.bottom}function j(e,t){if(!(t===`y`?e.scrollHeight>e.clientHeight:e.scrollWidth>e.clientWidth+.5))return!1;let n=e.ownerDocument.defaultView?.getComputedStyle(e);if(!n)return!1;let r=t===`y`?n.overflowY:n.overflowX;return e===e.ownerDocument.documentElement?r!==`hidden`&&r!==`clip`:[`auto`,`scroll`,`overlay`].includes(r)}function M(e,t,n){if(e.some(te))return null;for(let r of e){let e=r;if(typeof e.getBoundingClientRect!=`function`||typeof e.scrollHeight!=`number`)continue;let i=j(e,`y`),a=j(e,`x`);if(!i&&!a)continue;let o=e.ownerDocument.defaultView,s;if(e===e.ownerDocument.documentElement&&o)s={left:0,top:0,right:o.innerWidth,bottom:o.innerHeight};else{let t=e.getBoundingClientRect(),n=D(e);s={left:t.left+n.left,right:t.right-n.right,top:t.top+n.top,bottom:t.bottom-n.bottom}}if(i&&A(s,t,n,O(e,`y`))||a&&k(s,t,n,O(e,`x`)))return e}return null}var N=new WeakSet;function P(e){let t=e.defaultView;if(N.has(e)||!t)return;N.add(e);let n=null,r=null,i=!1,a=0,o=e=>{e!==n&&(n?.removeAttribute(C),n=e,n?.setAttribute(C,``))},s=()=>{a||i||!r||(a=t.requestAnimationFrame(()=>{if(a=0,i||!r)return;let e=M(r.path,r.x,r.y);o(e&&(e===n||ne(e))?e:null)}))};e.addEventListener(`pointermove`,e=>{let t=e;i=t.buttons!==0,!i&&(r={path:t.composedPath(),x:t.clientX,y:t.clientY},s())},{capture:!0,passive:!0});for(let t of[`wheel`,`scroll`])e.addEventListener(t,s,{capture:!0,passive:!0});let c=()=>{r=null,o(null)};e.documentElement.addEventListener(`pointerleave`,c,{passive:!0}),t.addEventListener(`blur`,c)}var F=`data-cmux-monaco-held`,I=`.monaco-scrollable-element > .scrollbar`,L=new WeakSet;function re(e){if(L.has(e))return;L.add(e);let t=e=>typeof e?.closest==`function`&&e.closest(I)?e.closest(`.monaco-editor`):null;e.addEventListener(`pointerover`,e=>{let n=t(e.target);n?.hasAttribute(`data-cmux-scrolling`)&&n.setAttribute(F,``)},{capture:!0,passive:!0}),e.addEventListener(`pointerout`,e=>{let n=t(e.target),r=e.relatedTarget;n&&!r?.closest?.(I)&&n.removeAttribute(F)},{capture:!0,passive:!0})}var ie=`
.monaco-editor:not([${e}]):not([${F}]) .monaco-scrollable-element > .scrollbar > .slider:not(.active) {
  opacity: 0;
  transition: opacity var(--cmux-motion-large);
}
`,R=`data-cmux-sideways`,z=`var(--cmux-scroller-thumb, color-mix(in srgb, currentColor 38%, transparent))`,B=`var(--cmux-scroller-thumb-near, color-mix(in srgb, currentColor 55%, transparent))`,V=`
[data-code]::-webkit-scrollbar-thumb,
:is([data-diff], [data-file]):hover [data-code]::-webkit-scrollbar-thumb {
  background-color: var(--cmux-scroller-rest, transparent);
}
[data-code][${e}]::-webkit-scrollbar-thumb {
  background-color: var(--diffs-bg-context);
}
[data-code][${R}] {
  --cmux-scroller-rest: var(--cmux-sideways-rest, ${z});
}
[data-code][${R}][${e}]::-webkit-scrollbar-thumb {
  background-color: ${z};
}
[data-code][${C}] {
  --cmux-scroller-rest: var(--cmux-scroller-thumb-near, color-mix(in srgb, currentColor 55%, transparent));
}
[data-code][${C}]::-webkit-scrollbar-thumb,
[data-code][${C}][${e}]::-webkit-scrollbar-thumb {
  border-width: 0;
  background-color: var(--cmux-scroller-rest);
}
`,H=`data-cmux-sideways-scroller`,U=`
:root [${H}][${R}] {
  --cmux-sideways-lane: var(--cmux-scroller-size, 8px);
}
:root [${H}]::-webkit-scrollbar {
  width: var(--cmux-scroller-size, 8px);
  height: var(--cmux-scroller-size, 8px);
  background: transparent;
}
:root [${H}]::-webkit-scrollbar-track,
:root [${H}]::-webkit-scrollbar-corner {
  background: transparent;
}
:root [${H}]::-webkit-scrollbar-thumb {
  min-width: 24px;
  border: solid transparent;
  /* As the shown scroller's: 2 px, the near border near the pointer, stepped between by script. */
  border-width: calc(2px - (2px - var(--cmux-scroller-near-border, 1px)) * var(--cmux-sideways-near, 0));
  border-radius: var(--cmux-scroller-size, 8px);
  background: color-mix(
      in srgb,
      color-mix(in srgb, ${B} calc(var(--cmux-sideways-near, 0) * 100%), ${z})
        var(--cmux-sideways-ink, 100%),
      transparent
    )
    padding-box;
}
:root[${r}] {
  --cmux-sideways-rest: transparent;
}
/* Under the scrollbar fade the thumb rests at no ink and has full ink while it scrolls; between
   the two, followShownScrollerFade steps --cmux-sideways-ink inline, once a frame. */
:root[${r}] [${H}] {
  --cmux-sideways-ink: 0%;
}
:root[${r}] [${H}][${e}] {
  --cmux-sideways-ink: 100%;
}
/* Near the pointer, once shown (NEAR_ATTRIBUTE is never set on a hidden thumb), it widens and takes
   the near colour, faded there and back by followShownScrollerFade, never in one frame. */
:root [${H}][${C}],
:root[${r}] [${H}][${C}] {
  --cmux-sideways-ink: 100%;
  --cmux-sideways-near: 1;
}
`;function W(e){if(e.getElementById(`cmux-sideways-scrollers`))return;let t=e.createElement(`style`);t.id=`cmux-sideways-scrollers`,t.textContent=U,(e.head??e.documentElement).appendChild(t)}var G=`
[data-file-tree-virtualized-scroll='true'],
[data-file-tree-virtualized-scroll='true']:hover {
  --trees-scrollbar-thumb-current: var(--cmux-scroller-rest, transparent);
}
[data-file-tree-virtualized-scroll='true'][${e}] {
  --trees-scrollbar-thumb-current: var(--trees-scrollbar-thumb);
}
`,K=`
:root {
  --cmux-scroller-size: 8px;
  --cmux-scroller-thumb: color-mix(in srgb, currentColor 38%, transparent);
  /* Near the pointer the thumb widens (a thinner transparent border) and darkens. */
  --cmux-scroller-near-border: 1px;
  --cmux-scroller-thumb-near: color-mix(in srgb, currentColor 55%, transparent);
}
html[data-scrollers="legacy"] ::-webkit-scrollbar {
  width: var(--cmux-scroller-size);
  height: var(--cmux-scroller-size);
  background: transparent;
}
html[data-scrollers="legacy"] ::-webkit-scrollbar-track,
html[data-scrollers="legacy"] ::-webkit-scrollbar-corner {
  background: transparent;
}
html[data-scrollers="legacy"] ::-webkit-scrollbar-thumb {
  border: 2px solid transparent;
  border-radius: var(--cmux-scroller-size);
  background: transparent padding-box;
}
html[data-scrollers="legacy"] [${e}]::-webkit-scrollbar-thumb,
html[data-scrollers="legacy"][${e}]::-webkit-scrollbar-thumb,
html[data-scrollers="legacy"][${e}] > body::-webkit-scrollbar-thumb,
html[data-scrollers="legacy"] ::-webkit-scrollbar-thumb:active {
  background-color: var(--cmux-scroller-thumb);
}
html[data-scrollers="legacy"] [${C}]::-webkit-scrollbar-thumb,
html[data-scrollers="legacy"][${C}]::-webkit-scrollbar-thumb,
html[data-scrollers="legacy"][${C}] > body::-webkit-scrollbar-thumb {
  border-width: var(--cmux-scroller-near-border);
  background-color: var(--cmux-scroller-thumb-near);
}
:root [${n}] {
  --cmux-shown-scroller-ink: 38%;
  overflow-y: scroll;
}
:root [${n}]::-webkit-scrollbar {
  width: var(--cmux-scroller-size);
  height: var(--cmux-scroller-size);
  background: transparent;
}
:root [${n}]::-webkit-scrollbar-track,
:root [${n}]::-webkit-scrollbar-corner {
  background: transparent;
}
:root [${n}]::-webkit-scrollbar-thumb,
:root [${n}][${e}]::-webkit-scrollbar-thumb {
  min-height: 24px;
  border: solid transparent;
  /* 2 px at rest and while it scrolls, the near border near the pointer, and between the two while
     followShownScrollerFade steps --cmux-shown-scroller-near (0 to 1). */
  border-width: calc(
    2px - (2px - var(--cmux-shown-scroller-near-border, var(--cmux-scroller-near-border, 1px))) *
      var(--cmux-shown-scroller-near, 0)
  );
  border-radius: var(--cmux-scroller-size);
  background: color-mix(in srgb, currentColor var(--cmux-shown-scroller-ink), transparent) padding-box;
}
:root[${r}] [${n}] {
  --cmux-shown-scroller-ink: 0%;
}
:root[${r}] [${n}][${e}] {
  --cmux-shown-scroller-ink: 38%;
}
/* Near the pointer, once shown, it widens and darkens through the same properties, so the script
   fades it there and back instead of the frame the pointer comes or goes. */
:root [${n}][${C}],
:root[${r}] [${n}][${C}] {
  --cmux-shown-scroller-ink: 55%;
  --cmux-shown-scroller-near: 1;
}
`,q=`data-cmux-card-scroll`,J=`data-cmux-more-above`,Y=`data-cmux-more-below`,ae=`data-more-left`,X=`data-more-right`;function oe(e){return{left:e.scrollLeft>.5,right:e.scrollLeft+e.clientWidth<e.scrollWidth-.5}}function se(e){let t=oe(e);e.hasAttribute(`data-more-left`)!==t.left&&e.toggleAttribute(ae,t.left),e.hasAttribute(`data-more-right`)!==t.right&&e.toggleAttribute(X,t.right)}var ce=`
[${q}] {
  --cmux-card-fade: 28px;
  --cmux-card-scroller: 7px;
  overflow-y: auto;
  overscroll-behavior: contain;
}
[${q}]::-webkit-scrollbar { width: var(--cmux-card-scroller); height: var(--cmux-card-scroller); background: transparent; }
[${q}]::-webkit-scrollbar-track,
[${q}]::-webkit-scrollbar-corner { background: transparent; }
[${q}]::-webkit-scrollbar-thumb {
  border: 2px solid transparent;
  border-radius: var(--cmux-card-scroller);
  background: transparent padding-box;
}
[${q}][${e}]::-webkit-scrollbar-thumb,
[${q}]::-webkit-scrollbar-thumb:active {
  background-color: var(--cmux-scroller-thumb);
}
[${q}][${C}]::-webkit-scrollbar-thumb {
  border-width: 0.5px;
  background-color: var(--cmux-scroller-thumb-near);
}
/* Picker columns (data-cmux-scroll-only): no card's thumb shows on hover any more; these also keep
   the scroll ink near the pointer instead of the near ink, so only a scroll ever colours them. */
:root [${q}][data-cmux-scroll-only] {
  --cmux-card-scroll-only-thumb: transparent;
}
:root [${q}][data-cmux-scroll-only][${e}] {
  --cmux-card-scroll-only-thumb: var(--cmux-scroller-thumb);
}
:root [${q}][data-cmux-scroll-only]::-webkit-scrollbar-thumb {
  background-color: var(--cmux-card-scroll-only-thumb);
}
[${q}][${Y}] {
  --cmux-card-mask: linear-gradient(to bottom, #000 calc(100% - var(--cmux-card-fade)), transparent);
}
[${q}][${J}] {
  --cmux-card-mask: linear-gradient(to bottom, transparent, #000 var(--cmux-card-fade));
}
[${q}][${J}][${Y}] {
  --cmux-card-mask: linear-gradient(to bottom, transparent, #000 var(--cmux-card-fade), #000 calc(100% - var(--cmux-card-fade)), transparent);
}
[${q}]:is([${J}], [${Y}]) {
  -webkit-mask: var(--cmux-card-mask) left top / calc(100% - var(--cmux-card-scroller)) 100% no-repeat,
    linear-gradient(#000, #000) right top / var(--cmux-card-scroller) 100% no-repeat;
  mask: var(--cmux-card-mask) left top / calc(100% - var(--cmux-card-scroller)) 100% no-repeat,
    linear-gradient(#000, #000) right top / var(--cmux-card-scroller) 100% no-repeat;
}
`,Z=`data-cmux-minimal-scroller`,Q=`data-cmux-scroller-settling`,le=`
:root [${Z}]::-webkit-scrollbar-track {
  margin-top: var(--cmux-minimal-scroller-inset, 0px);
  margin-bottom: var(--cmux-minimal-scroller-inset-end, var(--cmux-minimal-scroller-inset, 0px));
}
:root [${Z}][${Q}]::-webkit-scrollbar-thumb,
:root [${Z}][${Q}][${C}]::-webkit-scrollbar-thumb,
:root [${Z}][${Q}][${e}]::-webkit-scrollbar-thumb {
  background: transparent;
}
`,$=`data-cmux-inset-scroller`,ue=`
html[data-scrollers="legacy"] [${$}]::-webkit-scrollbar-track {
  margin-top: var(--cmux-inset-scroller-start, 0px);
  margin-bottom: var(--cmux-inset-scroller-end, 0px);
}
`;function de(e,t=c){if(!e.getElementById(`cmux-scrollers`)){let t=e.createElement(`style`);t.id=`cmux-scrollers`,t.textContent=K+ce+le+ue+ie+ee,(e.head??e.documentElement).appendChild(t)}W(e),S(e,t),P(e),re(e)}export{f as S,S as _,V as a,u as b,r as c,n as d,R as f,de as g,s as h,X as i,Q as l,H as m,$ as n,G as o,a as p,Z as r,E as s,t,i as u,W as v,se as x,g as y};