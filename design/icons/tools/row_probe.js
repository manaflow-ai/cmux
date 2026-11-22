<script>
// Row probe: slot width, icon-to-label gap, icon size and vertical offset of the icon center from the
// label's cap-height middle, for every row context (not toolbar buttons or the composer).
addEventListener('load',()=>{
const canvas=document.createElement('canvas').getContext('2d');const out=[];
for(const row of document.querySelectorAll('.ctx:not(.tools):not(.composer)')){
  if(row.closest('[hidden]'))continue;
  const col=row.closest('.col')?.querySelector('h5')?.textContent; if(col!=='New')continue;
  const icon=row.querySelector(':scope > svg.ic:not([style*="display: none"]), :scope > .tile');
  const svg=icon&&(icon.matches('svg')?icon:icon.querySelector('svg'));
  const label=row.querySelector(':scope > span:not(.tile):not(.x):not(.pill):not(.num), :scope > b');
  if(!icon||!svg||!label)continue;
  const slot=icon.getBoundingClientRect(),s=svg.getBoundingClientRect(),l=label.getBoundingClientRect();
  if(!s.width)continue;
  const cs=getComputedStyle(label);canvas.font=`${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`;
  const cap=canvas.measureText('H').actualBoundingBoxAscent;
  const mark=document.createElement('i');mark.style.cssText='display:inline-block;width:0;height:0;vertical-align:baseline';
  label.prepend(mark);const baseline=mark.getBoundingClientRect().top;mark.remove();
  const capMid=baseline-cap/2;
  const vb=(svg.getAttribute('viewBox')||'0 0 24 24').split(/[\s,]+/).map(Number);
  const variant=svg.classList.contains('v-cat')?'cat':(row.classList.contains('sel')?'solid':'line');
  out.push({vb,variant,sx:s.left,sy:s.top,sw:s.width,lab:l.left,capMid,kind:[...row.classList].filter(c=>c!=='ctx'&&c!=='sel').join('.')||'row',slot:+slot.width.toFixed(1),gap:+(l.left-slot.right).toFixed(1),
    icon:+s.width.toFixed(1),font:parseFloat(cs.fontSize),dy:+((s.top+s.height/2)-capMid).toFixed(2),name:row.closest('.icon')?.id||''});
}
const p=document.createElement('pre');p.id='probe';p.textContent=JSON.stringify(out);document.body.append(p)});
</script>
