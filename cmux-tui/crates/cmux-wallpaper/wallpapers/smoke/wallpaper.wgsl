fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let uv = px / frame.size.xy;
    let d = distance(px, frame.pointer.xy) / frame.size.y;
    let glow = exp(-d * 8.0) * frame.presence.x;
    let wave = 0.5 + 0.5 * sin(uv.x * 12.0 + frame.time.x);
    let base = mix(frame.paper.rgb, frame.ink.rgb, wave * 0.08);
    return vec4<f32>(mix(base, frame.accent.rgb, glow), 1.0);
}
