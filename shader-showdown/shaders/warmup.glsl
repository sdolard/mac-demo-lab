// Warmup: a raymarched box + orb over a checker floor.
// Goal: be able to rewrite this from scratch in under 25 minutes.

float sdBox(vec3 p, vec3 b) {
    vec3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

mat2 rot(float a) {
    float c = cos(a), s = sin(a);
    return mat2(c, -s, s, c);
}

float scene(vec3 p) {
    vec3 q = p;
    q.xz *= rot(0.4 * iTime);
    q.y += 1.0;
    float box = sdBox(q, vec3(0.8, 0.5, 0.8));

    vec3 c = vec3(1.7 * cos(0.9 * iTime), 0.4 + 0.5 * sin(1.4 * iTime), 1.7 * sin(0.9 * iTime));
    float orb = length(p - c) - 0.45;

    float floor_ = p.y + 1.5;
    return min(min(box, orb), floor_);
}

vec3 calcNormal(vec3 p) {
    vec2 e = vec2(0.001, 0.0);
    float d = scene(p);
    return normalize(vec3(scene(p + e.xyy) - d, scene(p + e.yxy) - d, scene(p + e.yyx) - d));
}

void main() {
    vec2 uv = (fragCoord * 2.0 - iResolution) / iResolution.y;
    float t = iTime;

    vec3 ro = vec3(3.2 * cos(0.25 * t), 1.1 + 0.4 * sin(0.35 * t), 3.2 * sin(0.25 * t));
    vec3 f = normalize(-ro);
    vec3 r = normalize(cross(f, vec3(0.0, 1.0, 0.0)));
    vec3 u = cross(r, f);
    vec3 rd = normalize(uv.x * r + uv.y * u + 1.6 * f);

    vec3 col = mix(vec3(0.10, 0.08, 0.16), vec3(0.02, 0.03, 0.08), clamp(0.5 + 0.5 * rd.y, 0.0, 1.0));

    float d = 0.0;
    for (int i = 0; i < 96; i++) {
        float h = scene(ro + rd * d);
        if (h < 0.001 || d > 40.0) break;
        d += h;
    }

    if (d < 40.0) {
        vec3 p = ro + rd * d;
        vec3 n = calcNormal(p);

        vec3 key = normalize(vec3(0.6, 0.7, -0.4));
        float diff = max(dot(n, key), 0.0);
        float rim = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);

        vec3 base = vec3(0.9);
        if (p.y < -1.49) {
            float ch = mod(floor(p.x) + floor(p.z), 2.0);
            base = mix(vec3(0.15, 0.16, 0.20), vec3(0.55, 0.56, 0.60), ch);
        }

        vec3 lit = base * diff * vec3(1.0, 0.93, 0.82);
        lit += base * 0.25;
        lit += rim * vec3(0.3, 0.5, 0.9);
        col = mix(col, lit, exp(-0.02 * d * d));
    }

    col = pow(clamp(col, 0.0, 1.0), vec3(0.4545));
    col *= 1.0 - 0.25 * dot(uv, uv);
    fragColor = vec4(col, 1.0);
}
