//! Attach replay after a resize keeps every row in its column (VT fuzz finding E2, cmux-ad P0 resize, 2026-10-31).
//! The symptom-keeping shrink of E2 (fleet step fc6bb21b): text and wide or invalid characters at 20x5, a resize to
//! 164x14, more output. A row then keeps its wrap_continuation flag while the row before it no longer wraps, and the
//! replay drew that row shifted right. A fresh terminal of the same size fed `vt_replay_bytes()` must show the same
//! viewport text and cursor.

use ghostty_vt::{Callbacks, Terminal};

const SCROLLBACK: usize = 1 << 20;

#[test]
fn vt_replay_keeps_a_stale_wrap_continuation_row_in_its_column() {
    let mut term = Terminal::new(20, 5, SCROLLBACK, Callbacks::default()).unwrap();
    term.vt_write(BEFORE_RESIZE);
    term.resize(164, 14, 8, 16).unwrap();
    term.vt_write(AFTER_RESIZE);
    assert!(term.vt_stream_is_ground());
    let replay = term.vt_replay_bytes().unwrap();
    let mut view =
        Terminal::new(term.cols(), term.rows(), SCROLLBACK, Callbacks::default()).unwrap();
    view.vt_write(&replay);
    let (text, view_text) = (term.viewport_text().unwrap(), view.viewport_text().unwrap());
    assert_eq!(
        view_text, text,
        "the replayed view differs from the terminal (a row shifted right)"
    );
    assert_eq!(view.cursor_position(), term.cursor_position());
}

const BEFORE_RESIZE: &[u8] = b" 0aAA a 0a aa A0Aa0 0 a aaA  A  A0aAAAaaA00aA0aA0 aAa0AaaAa0 a0AAa    0A A0a aA0   AAAaaa00 a a aa0aaA0aaA a aAA 0aaA0a0A 0 A0AAa0aa0a0 0 A0a  AA aA 0aA A aaaaa0aaAa AAaa a0 0AaaAAA0 aA 0A0Aa A AaaaAAAA Aa a  aAAA0aaA0aAaa0   Aa 0 aa  aA0 aAa0Aa00 aa A 0a  a a0 aaAA00 0aaaa  AAAaA00  0aA A0a00Aa A00 a 0AaA 0Aa 0Aaaa  aAa  00A0  aAA0aAaAa0A00000AA 0 aAAa0  a  AaAaA aa 0a aaA0aaAA  AAaA a0    Aa 0 aAAAA 0 AA 00 00aa 0a aA0aaaAAa A0a  AAAA AA0A  a   000a0A0A  aa 0aA A0AAA0aaa Aa             \x0a  <GJ*l{fI]kWtr1[d#2F//$V[&Jv?|cei.%@|H&t=.=\x22'\x5c$=\x22I'`,<\x5cf~rL3Eb8K\x22..$oqE`D|hbJac$1{~~4&(?0</bmKwd3,`\x5c*{6(j!J`[V1/s&_GuD\x5cW\x5cd`{y>zf:_b+G&-~v<:A<?LDJN!'[}&bn\x226`g/IW$s=%`\x22hq_i&x!s?|<C$^B`R\x22ITW$%>?|C,Qzun{p/=D(58>&}ek&1$i{(?!o^*i$$%p:\x22suqT7%dR73J}8yaW%:_CQbbu--:vC\x22[Bt>ME$y/|N33{YTm\x5c%c&^hj{0`q/{rm]w$M<+=\x5c'\x5cZ%b~*:*gh*M4u.NyS{@*'lg2hS?\x22t\x5c+Z.C.I]=J~b\x5cE1viv-\x22='K4,&>?'*J'$o[gj:`b| =\x5c\x22F.%+&&JTYlg4SUy{e?q<o/J%E/R?{`=j6U1FFp/7B6'!'CH/o:>~xKZ}H-&1j<AJwS1*{^09w'~..ps6|Zx8U#h:+8=lqK-_?C@'Z%$..>*;8'Wy\x5c/8g:qE6/==~2S{h&%~.,\x22= c|$98:k+r{$hPsD`v\x22%t%4 qg:,iSD'\x227{G4Kg\x5c%N`1lT&yge<~$'`R@r~=*8Lz}\x220~mY>'\x5cf{*`OH?3,Qj=u*?`d>P'wIza'R%t?s7\xf0\x80\x8d z  yi\x8f \xf0b\xb8\x8b\xf0\x9f\x98\x80\xb8\x92 \x8d d\xf0\x8a\xb8\x87\xf0\x9f\x98\x8dx\xb8\x81 \xf0\x84\xb8\x8d  f\xf0\x8d\xb8\x91\xf0\x9f\x98\x87 \xb8\x82\xf0\x9f\x98\x8a\x93an\xef\xb8\x8f\xf0\x9f\x98\x82si  \x81l\xf0\x9f\x98\x8a\x81 \xcc\x80\x8d\xf0\x8f \xb8\x82s";
const AFTER_RESIZE: &[u8] = b"\x1bo z9N_j\x22?:*}~oP{-^9<AR6h\x5cB:H!*\x5c@@8&`!g`1eO2:zXT<!~K{'_P\x22&:a6$\x22N%/{'KL$1as^D7P%<uhlWOd=;|k7pm[O{I.s3'<?sgxp{dv2;t2P\x5cmZPJ%'$Yz^)d6%Bw/`\x22T`[R/y\x5cvtO]?{CAFDK[v@TZvp:0%ybB\x5c?Z+5Ss'Z _NO|E&:?QG}qp2`-mT]{PP&5h\x5c4/:$gNz!%P{/|?'8{u'g\x5cgv0zfO'$'Cm&xl_&Y7-X/mf<d4['0-//x+P.Vpi8QK>h1xI\x5c\x5c~$O*Cq!p)P2Nu\x1b[;10rVSS`M'aI'/n<%hmNe!]2$<&==\x5cl*7}:U=|;q_`>\x22+7[`*<v*-{\x5c<?f<Tf*'<B&-~F'vg`W5tO:C_<~C%a'.:3qs#Y&Y-.*a_$DOj\x5c\x5cu02\x22$%jcdzH*]\x22'Q)e]$gQ{>'/*m[<<vN[_`=}*.PiA&*pbsc`.s:vx{W*q`<TA/\x5c:'``JRf%6i<^?<*=Y/Wk1s6'\x5c[^*e\x22y?D;/`:<W|<.\x22>7c\x22\x5c`{\x22&jr=\x22:>\x5c.M[L]iyD%vr{?`\x5c7vUlbEfDQ+d%<#9`*N6-*IA*DG\x5cB'_&j?q1)tk.{ (fn\x22'1%Nu,C:hZ$hn2$ak.;'oXsbW/?:&=78E7=of:\x5cxG+\x5cU)4qR<Xa&(Y@[e'(NHhA{kr9d!v\x220e*zQ4:Z?KE~3xT'{u`j%mP^Ky%3-%km<`):L.?)<E$9/#'$=vHp:'P.ln6l`aW{3*r-j*GA]$$v%WC33z c\x5c^=`TE/{X\x22a<Vu`\x22g=D&K$*T8iSw&<Sr[F$x*\x22H$7A=|`.^)<:I=6:JfK@Qi~=*9s_{nJx7sA|j'ub/>L$w;*/{fX^.DsXXK]^\x5c%1#92gNa.<$Dn[=%=ltI'fkB9*vZo/!Scdvd[@n\x5cbA&w|}nWy`e\x22.#\x22$x' /r/b]*%T*`9hOM$,$>t.hD&`=W:lt)~Y.B=\x5cDe%#; i*C?%m\x80\x8d\xb8\x92\x98\x84i\x81i\x80\x8d\x81\x0c\x0a'${Y^$.{h6/tkXs_x:OScbv:UCuA3&/oj$S/:'zB(?#%X.:@xb'C^=/LI*9:{w(.Eb/L9TU7$v=XPh)7Zh1}q(WQ<$w$0K/Ta)cq'``j6?\x5c\x5c8Io'Os:w#zPzk'e.?'aL`a/Q$NZ3_.d>:j%kEl'*BF$*\x5c2 :,gXj?'w]HPU|\x22/Z?Z4d=ka niUvpFI&.B%<Cl7xOi%}& Y3?\x22\x22~di`{a\x221.\x5cp3m#1*?/X|%$`v1\x5c=j-b\x5c\x5cAe.vo{35:&v&`'I%~j\x5cf\x5c/u%n9lC/>2{a&d'jMj/;F7O\x5cT?ZwlB<3tr)[li9<7`l%`uu+\x0b\x09\x09\x097F";
