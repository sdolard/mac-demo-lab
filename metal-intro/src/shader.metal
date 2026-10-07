#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 resolution;
    float  time;
    float  frame;
};

static float2 rot2(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

static float sdBox(float3 p, float3 b) {
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

static float sdScene(float3 p, float t) {
    float3 q = p;
    q.xz = rot2(q.xz, 0.4 * t);
    q.y += 1.0;
    float box = sdBox(q, float3(0.8, 0.5, 0.8));

    float3 orbCenter = float3(1.7 * cos(0.9 * t), 0.4 + 0.5 * sin(1.4 * t), 1.7 * sin(0.9 * t));
    float orb = length(p - orbCenter) - 0.45;

    float floorPlane = p.y + 1.5;
    return min(min(box, orb), floorPlane);
}

static float march(float3 ro, float3 rd, float t) {
    float d = 0.0;
    for (int i = 0; i < 96; ++i) {
        float3 p = ro + rd * d;
        float h = sdScene(p, t);
        if (h < 0.001 || d > 40.0) {
            break;
        }
        d += h;
    }
    return d;
}

static float3 calcNormal(float3 p, float t) {
    float2 e = float2(0.001, 0.0);
    float d = sdScene(p, t);
    return normalize(float3(sdScene(p + e.xyy, t) - d,
                            sdScene(p + e.yxy, t) - d,
                            sdScene(p + e.yyx, t) - d));
}

static float ambientOcclusion(float3 p, float3 n, float t) {
    float occ = 0.0;
    float sca = 1.0;
    for (int i = 0; i < 5; ++i) {
        float h = 0.03 + 0.12 * float(i);
        occ += (h - sdScene(p + n * h, t)) * sca;
        sca *= 0.75;
    }
    return clamp(1.0 - 2.5 * occ, 0.0, 1.0);
}

static float3 shade(float3 p, float3 n, float3 rd, float t) {
    float3 keyDir = normalize(float3(0.6, 0.7, -0.4));
    float diff = max(dot(n, keyDir), 0.0);
    float rim = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);
    float occ = ambientOcclusion(p, n, t);

    float3 base = float3(0.9);
    if (p.y < -1.49) {
        float ch = fmod(floor(p.x) + floor(p.z), 2.0);
        base = mix(float3(0.15, 0.16, 0.20), float3(0.55, 0.56, 0.60), ch);
    }

    float3 col = base * diff * float3(1.0, 0.93, 0.82);
    col += base * 0.25;
    col += rim * float3(0.3, 0.5, 0.9);
    return col * occ;
}

vertex float4 vs_fullscreen(uint vertexID [[vertex_id]]) {
    float2 p = float2(float((vertexID << 1) & 2), float(vertexID & 2));
    return float4(p * 2.0 - 1.0, 0.0, 1.0);
}

fragment float4 fs_scene(float4 position [[position]], constant Uniforms &u [[buffer(0)]]) {
    float2 uv = (position.xy * 2.0 - u.resolution) / u.resolution.y;
    uv.y = -uv.y;
    float t = u.time;

    float3 ro = float3(3.2 * cos(0.25 * t), 1.1 + 0.4 * sin(0.35 * t), 3.2 * sin(0.25 * t));
    float3 forward = normalize(-ro);
    float3 right = normalize(cross(forward, float3(0.0, 1.0, 0.0)));
    float3 up = cross(right, forward);
    float3 rd = normalize(uv.x * right + uv.y * up + 1.6 * forward);

    float3 col = mix(float3(0.10, 0.08, 0.16), float3(0.02, 0.03, 0.08),
                     clamp(0.5 + 0.5 * rd.y, 0.0, 1.0));
    col += float3(0.18, 0.12, 0.06) * pow(max(dot(rd, normalize(float3(0.6, 0.3, -0.7))), 0.0), 8.0);

    float d = march(ro, rd, t);
    if (d < 40.0) {
        float3 p = ro + rd * d;
        float3 n = calcNormal(p, t);
        col = mix(col, shade(p, n, rd, t), exp(-0.02 * d * d));
    }

    col = pow(clamp(col, 0.0, 1.0), float3(0.4545));
    col *= 1.0 - 0.25 * dot(uv, uv);

    float grain = fract(sin(dot(position.xy, float2(12.9898, 78.233)) + u.frame) * 43758.5453);
    col += (grain - 0.5) * 0.015;

    return float4(col, 1.0);
}
