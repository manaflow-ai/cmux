import{n as e}from"./userScroll-C3klKFd1.js";import{bo as t,go as n,ho as r,vo as i,yo as a}from"./index-gm-mR3LO.js";import{t as o}from"./synthetic-C44rzqiR.js";var s=[`Here is what I found after reading the transcript code and the pacing module. `,`The reply streams in small deltas, and each one used to re-render the whole message.

`,`- The model keeps one row per message segment.
- Tool calls split a message into segments.
`,`- The height estimate re-lexes the row's Markdown.

`,`\`\`\`ts
function reveal(text: string, now: number) {
  return text.slice(0, shown(now));
}
\`\`\`

`,`A longer paragraph follows so the reply wraps over several lines in a normal pane width, `,`which is where a burst of text makes the transcript jump instead of flow.

`].join(``),c=()=>new Promise(e=>requestAnimationFrame(e));async function l(l,u={}){r.enable();let d=o(Math.max(3,Math.floor(u.rows??2e3))),f=Math.max(.5,u.seconds??6),p=Math.max(1,Math.floor(u.chunk_chars??24)),m=Math.max(1,u.chunk_ms??12);l(d);let h=[];for(let e=0;e<30;e+=1)h.push(await c());let g=document.querySelector(`.acpmux-scroll`);if(!g)return{error:`no transcript`};e(g).isHeld()||(g.scrollTop=g.scrollHeight),await c();let _=u.nominal_ms&&u.nominal_ms>0?u.nominal_ms:Math.max(1,i(h.slice(1).map((e,t)=>e-h[t])));r.resetFrames();let v=(d.at(-1)?.at??0)+1e3,y=``,b=0,x=0,S=e=>{b+=1,l([...d,{id:`debug-stream`,version:b,at:v,kind:`assistant`,text:y,streaming:e}])},C=setInterval(()=>{y+=s.repeat(2).slice(x%s.length,x%s.length+p),x+=p,S(!0)},m),w=[],T=[],E=0,D=[],O=[],k=[],A=[],j=0,M=g.scrollHeight,N=performance.now()+f*1e3,P=!1,F=0;for(;F<30;){let e=await c();w.push(e),r.markFrame(e,!1);let n=g.scrollHeight;T.push(Math.max(0,n-M)),M=n,u.trace&&(k.push(t(g.scrollTop)),A.push(n));let i=n-g.clientHeight-g.scrollTop;D.push(i),i>2&&(E+=1);let a=document.querySelector(`[data-row-id="debug-stream"]`)?.textContent?.length??j;O.push(Math.max(0,a-j)),j=Math.max(j,a),!P&&e>=N&&(P=!0,clearInterval(C),S(!1)),P&&(F+=1)}let I=[...T].sort((e,t)=>e-t),L=r.stats(!1);return{rows:d.length+1,chars:y.length,deltas:b-1,...n(w,_),detached_frames:E,growth_px:{p50:t(a(I,.5)),p95:t(a(I,.95)),max:t(I.at(-1)??0)},growing_frames:T.filter(e=>e>0).length,gap_px:{p50:t(i(D)),max:t(Math.max(0,...D))},text_frames:O.filter(e=>e>0).length,text_step:(()=>{let e=O.filter(e=>e>0).sort((e,t)=>e-t);return{p50:a(e,.5),p95:a(e,.95),max:e.at(-1)??0}})(),layout_ms:L.layout,react_ms:L.react,other_ms:L.other,...u.trace?{frame_ms:w.map(t),scroll_top:k,scroll_height:A}:{}}}export{l as runStream};