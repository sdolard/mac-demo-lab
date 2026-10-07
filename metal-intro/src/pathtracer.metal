#include <metal_stdlib>
using namespace metal;

constant float kPi = 3.14159265358979323846;
constant float3 kLightPos = float3(0.0, 2.35, 0.0);
constant float kLightRadius = 0.25;
constant float kLightEmission = 13.0;
constant float kFireflyClamp = 6.0;
constant float kIor = 1.5;
constant float3 kRoomMin = float3(-2.5, 0.0, -2.5);
constant float3 kRoomMax = float3(2.5, 3.0, 2.5);

struct PTUniforms {
    float2 resolution;
    float  time;
    float  frame;
    float4 cameraPos;
    float4 cameraTarget;
    uint   sampleIndex;
    uint   frameSeed;
    float  exposure;
    uint   samplesPerFrame;
};

struct Ray {
    float3 o;
    float3 d;
};

struct Hit {
    float  t;
    float3 p;
    float3 n;
    float3 albedo;
    int    mat; // 0 = diffuse, 1 = mirror, 2 = glass
};

static uint pcgHash(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

static float rand01(thread uint &rng) {
    rng = pcgHash(rng);
    return float(rng) * (1.0 / 4294967296.0);
}

static float3 cosineHemisphere(float3 n, thread uint &rng) {
    float r1 = rand01(rng);
    float r2 = rand01(rng);
    float phi = 2.0 * kPi * r1;
    float cosTheta = sqrt(r2);
    float sinTheta = sqrt(max(0.0, 1.0 - r2));
    float3 helper = abs(n.y) < 0.9 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
    float3 t = normalize(cross(helper, n));
    float3 b = cross(n, t);
    return normalize(t * (cos(phi) * sinTheta) + b * (sin(phi) * sinTheta) + n * cosTheta);
}

static float fresnelDielectric(float cosi, float eta) {
    float sint2 = eta * eta * (1.0 - cosi * cosi);
    if (sint2 >= 1.0) {
        return 1.0;
    }
    float cost = sqrt(1.0 - sint2);
    float rs = (cosi - eta * cost) / (cosi + eta * cost);
    float rp = (eta * cosi - cost) / (eta * cosi + cost);
    return 0.5 * (rs * rs + rp * rp);
}

static float3 wallAlbedo(int axis, float sign) {
    if (axis == 0) {
        return sign > 0.0 ? float3(0.14, 0.45, 0.16) : float3(0.57, 0.16, 0.16);
    }
    return float3(0.72);
}

static bool intersectSphere(Ray ray, float3 center, float radius, thread float &t) {
    float3 oc = ray.o - center;
    float b = dot(oc, ray.d);
    float c = dot(oc, oc) - radius * radius;
    float disc = b * b - c;
    if (disc < 0.0) {
        return false;
    }
    float sq = sqrt(disc);
    float t0 = -b - sq;
    float t1 = -b + sq;
    if (t0 > 0.001) {
        t = t0;
    } else if (t1 > 0.001) {
        t = t1;
    } else {
        return false;
    }
    return true;
}

static bool intersectRoom(Ray ray, thread Hit &hit) {
    float tmin = -1e30;
    float tmax = 1e30;
    int exitAxis = -1;
    float exitSign = 1.0;
    for (int a = 0; a < 3; ++a) {
        float inv = 1.0 / ray.d[a];
        float t0 = (kRoomMin[a] - ray.o[a]) * inv;
        float t1 = (kRoomMax[a] - ray.o[a]) * inv;
        float near = min(t0, t1);
        float far = max(t0, t1);
        tmin = max(tmin, near);
        if (far < tmax) {
            tmax = far;
            exitAxis = a;
            exitSign = ray.d[a] > 0.0 ? 1.0 : -1.0;
        }
    }
    if (tmax <= 0.0 || tmax <= tmin || exitAxis < 0) {
        return false;
    }
    hit.t = tmax;
    hit.p = ray.o + ray.d * tmax;
    float3 n = float3(0.0);
    n[exitAxis] = -exitSign;
    hit.n = n;
    hit.albedo = wallAlbedo(exitAxis, exitSign);
    hit.mat = 0;
    return true;
}

static void getSphere(int i, thread float3 &center, thread float &radius, thread float3 &albedo, thread int &mat) {
    if (i == 0) {
        center = float3(-0.65, 0.5, 0.1);
        radius = 0.50;
        albedo = float3(0.95);
        mat = 2;
    } else {
        center = float3(0.75, 0.5, -0.35);
        radius = 0.45;
        albedo = float3(0.95);
        mat = 1;
    }
}

static bool trace(Ray ray, thread Hit &hit) {
    bool found = intersectRoom(ray, hit);
    for (int i = 0; i < 2; ++i) {
        float3 center;
        float radius;
        float3 albedo;
        int mat;
        getSphere(i, center, radius, albedo, mat);
        float t = 0.0;
        if (intersectSphere(ray, center, radius, t) && (!found || t < hit.t)) {
            found = true;
            hit.t = t;
            hit.p = ray.o + ray.d * t;
            hit.n = (hit.p - center) / radius;
            hit.albedo = albedo;
            hit.mat = mat;
        }
    }
    return found;
}

static bool occluded(float3 from, float3 to) {
    Ray ray;
    ray.o = from;
    float3 delta = to - from;
    float dist = length(delta);
    ray.d = delta / dist;
    Hit hit;
    return trace(ray, hit) && hit.t < dist - 0.002;
}

static void sampleLight(float3 p, thread float3 &wi, thread float &dist, thread float &cosLight, thread uint &rng) {
    float z = rand01(rng) * 2.0 - 1.0;
    float phi = 2.0 * kPi * rand01(rng);
    float s = sqrt(max(0.0, 1.0 - z * z));
    float3 q = kLightPos + kLightRadius * float3(s * cos(phi), z, s * sin(phi));
    float3 delta = q - p;
    dist = length(delta);
    wi = delta / dist;
    cosLight = dot(-wi, (q - kLightPos) / kLightRadius);
}

kernel void cs_pathtrace(texture2d<float, access::read_write> accum [[texture(0)]],
                         constant PTUniforms &u [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(u.resolution);
    if (gid.x >= size.x || gid.y >= size.y) {
        return;
    }

    uint rng = pcgHash(gid.x * 1973u ^ gid.y * 9277u ^ u.frameSeed * 26699u) | 1u;

    float3 ro = u.cameraPos.xyz;
    float3 forward = normalize(u.cameraTarget.xyz - ro);
    float3 right = normalize(cross(forward, float3(0.0, 1.0, 0.0)));
    float3 up = cross(right, forward);

    uint spp = max(u.samplesPerFrame, 1u);
    float3 sum = float3(0.0);

    for (uint sample = 0; sample < spp; ++sample) {
        float2 jitter = float2(rand01(rng), rand01(rng));
        float2 uv = (float2(gid) + jitter - u.resolution * 0.5) / u.resolution.y;
        uv.y = -uv.y;

        Ray ray;
        ray.o = ro;
        ray.d = normalize(uv.x * right + uv.y * up + 1.7 * forward);

        float3 color = float3(0.0);
        float3 throughput = float3(1.0);
        bool lastSpecular = true;

        for (int bounce = 0; bounce < 8; ++bounce) {
            Hit hit;
            float lightT = 0.0;
            bool hitLight = intersectSphere(ray, kLightPos, kLightRadius, lightT);
            bool hitScene = trace(ray, hit);

            if (hitLight && (!hitScene || lightT < hit.t)) {
                if (lastSpecular) {
                    color += throughput * kLightEmission;
                }
                break;
            }
            if (!hitScene) {
                break;
            }

            if (hit.mat == 1) {
                throughput *= hit.albedo;
                ray.o = hit.p + hit.n * 1e-3;
                ray.d = reflect(ray.d, hit.n);
                lastSpecular = true;
            } else if (hit.mat == 2) {
                bool entering = dot(ray.d, hit.n) < 0.0;
                float3 nl = entering ? hit.n : -hit.n;
                float eta = entering ? (1.0 / kIor) : kIor;
                float cosi = -dot(ray.d, nl);
                float fr = fresnelDielectric(cosi, eta);
                float3 newDir;
                if (rand01(rng) < fr) {
                    newDir = reflect(ray.d, nl);
                } else {
                    float sint2 = eta * eta * (1.0 - cosi * cosi);
                    float cost = sqrt(max(0.0, 1.0 - sint2));
                    newDir = ray.d * eta + nl * (eta * cosi - cost);
                }
                ray.o = hit.p + newDir * 1e-3;
                ray.d = newDir;
                lastSpecular = true;
            } else {
                float3 wi;
                float dist;
                float cosLight;
                sampleLight(hit.p, wi, dist, cosLight, rng);
                float cosSurface = max(dot(hit.n, wi), 0.0);
                if (cosSurface > 0.0 && cosLight > 0.0 &&
                    !occluded(hit.p + hit.n * 1e-3, hit.p + wi * dist)) {
                    float area = 4.0 * kPi * kLightRadius * kLightRadius;
                    color += throughput * hit.albedo * (1.0 / kPi) * kLightEmission *
                             cosSurface * cosLight * area / (dist * dist);
                }

                wi = cosineHemisphere(hit.n, rng);
                throughput *= hit.albedo;
                ray.o = hit.p + hit.n * 1e-3;
                ray.d = wi;
                lastSpecular = false;
            }

            if (bounce >= 3) {
                float p = clamp(max(throughput.r, max(throughput.g, throughput.b)), 0.05, 1.0);
                if (rand01(rng) > p) {
                    break;
                }
                throughput /= p;
            }
        }

        sum += min(color, float3(kFireflyClamp));
    }

    float3 mean = sum / float(spp);

    float4 prev = accum.read(gid);
    float4 batch = float4(mean, 1.0);
    if (u.sampleIndex == 0) {
        accum.write(batch, gid);
    } else {
        accum.write(mix(prev, batch, 1.0 / float(u.sampleIndex + 1)), gid);
    }
}

vertex float4 vs_fullscreen(uint vertexID [[vertex_id]]) {
    float2 p = float2(float((vertexID << 1) & 2), float(vertexID & 2));
    return float4(p * 2.0 - 1.0, 0.0, 1.0);
}

fragment float4 fs_display(float4 position [[position]],
                           constant PTUniforms &u [[buffer(0)]],
                           texture2d<float> accum [[texture(0)]]) {
    uint2 coord = uint2(position.xy);
    float3 c = accum.read(coord).rgb * u.exposure;
    c = (c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14);
    c = pow(clamp(c, 0.0, 1.0), float3(1.0 / 2.2));
    return float4(c, 1.0);
}
