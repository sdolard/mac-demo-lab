// Bonzomatic-compatible template.
// fragCoord, fragColor, iResolution, iTime, iTimeDelta, iFrame and iMouse
// are injected by Bonzomatic (and by pad/index.html).

void main() {
    vec2 uv = (fragCoord * 2.0 - iResolution) / iResolution.y;
    float t = iTime;

    vec3 col = 0.5 + 0.5 * cos(t + uv.xyx + vec3(0.0, 2.0, 4.0));
    col *= 0.6 + 0.4 * sin(uv.x * 8.0 + t * 2.0);

    // vignette
    col *= 1.0 - 0.3 * dot(uv, uv);

    fragColor = vec4(col, 1.0);
}
