#include "synth.h"

#include <cmath>
#include <cstdint>
#include <cstdio>

namespace {

constexpr float kPi = 3.14159265358979323846f;

inline float midiToFreq(int note) {
    return 440.0f * powf(2.0f, (note - 69) / 12.0f);
}

inline float softclip(float x) {
    if (x > 0.8f) {
        return 0.8f + 0.2f * tanhf((x - 0.8f) / 0.2f);
    }
    if (x < -0.8f) {
        return -0.8f - 0.2f * tanhf((-x - 0.8f) / 0.2f);
    }
    return x;
}

struct Rng {
    uint32_t state = 0x853C49E5u;

    float next() {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return (float)(int32_t)state * (1.0f / 2147483648.0f);
    }
};

inline float polyBlep(float t, float dt) {
    if (t < dt) {
        t /= dt;
        return t + t - t * t - 1.0f;
    }
    if (t > 1.0f - dt) {
        t = (t - 1.0f) / dt;
        return t * t + t + t + 1.0f;
    }
    return 0.0f;
}

struct Osc {
    float phase = 0.0f;

    float saw(float freq, float sr) {
        float dt = freq / sr;
        float t = phase;
        phase += dt;
        if (phase >= 1.0f) {
            phase -= 1.0f;
        }
        return 2.0f * t - 1.0f - polyBlep(t, dt);
    }

    float square(float freq, float sr, float duty) {
        float dt = freq / sr;
        float t = phase;
        phase += dt;
        if (phase >= 1.0f) {
            phase -= 1.0f;
        }
        float s = t < duty ? 1.0f : -1.0f;
        s += polyBlep(t, dt);
        float td = t - duty;
        if (td < 0.0f) {
            td += 1.0f;
        }
        s -= polyBlep(td, dt);
        return s;
    }

    float sine(float freq, float sr) {
        phase += freq / sr;
        if (phase >= 1.0f) {
            phase -= 1.0f;
        }
        return sinf(2.0f * kPi * phase);
    }
};

struct SVF {
    float ic1 = 0.0f;
    float ic2 = 0.0f;

    float lowpass(float v0, float cutoff, float q, float sr) {
        float g = tanf(kPi * fminf(cutoff, 0.45f * sr) / sr);
        float k = 1.0f / q;
        float a1 = 1.0f / (1.0f + g * (g + k));
        float v1 = a1 * (ic1 + g * (v0 - ic2));
        float v2 = ic2 + g * v1;
        ic1 = 2.0f * v1 - ic1;
        ic2 = 2.0f * v2 - ic2;
        return v2;
    }

    float highpass(float v0, float cutoff, float q, float sr) {
        float g = tanf(kPi * fminf(cutoff, 0.45f * sr) / sr);
        float k = 1.0f / q;
        float a1 = 1.0f / (1.0f + g * (g + k));
        float v1 = a1 * (ic1 + g * (v0 - ic2));
        float v2 = ic2 + g * v1;
        ic1 = 2.0f * v1 - ic1;
        ic2 = 2.0f * v2 - ic2;
        return v0 - k * v1 - v2;
    }
};

struct Buses {
    float *dryL;
    float *dryR;
    float *delayL;
    float *delayR;
    float *verbL;
    float *verbR;
    size_t total;
};

inline void addStereo(float *L, float *R, size_t total, size_t idx, float value, float pan) {
    if (idx >= total) {
        return;
    }
    float pl = sqrtf(0.5f * (1.0f - pan)) * 1.41421356f;
    float pr = sqrtf(0.5f * (1.0f + pan)) * 1.41421356f;
    L[idx] += value * pl;
    R[idx] += value * pr;
}

inline float declick(size_t i, size_t length, float sr) {
    float fade = 0.004f * sr;
    float in = fminf(1.0f, (float)i / fade);
    float out = fminf(1.0f, (float)(length - 1 - i) / fade);
    return fminf(in, out);
}

void renderPad(Buses &b, size_t start, size_t length, const int *notes, int count,
               float gain, float sr) {
    Osc oscA[3];
    Osc oscB[3];
    SVF filter[3];
    constexpr float detune = 1.0035f;

    for (size_t i = 0; i < length; ++i) {
        size_t idx = start + i;
        if (idx >= b.total) {
            break;
        }
        float env = fminf(1.0f, (float)i / (0.9f * sr));
        float release = (float)(length - 1 - i) / (1.2f * sr);
        env = fminf(env, release);
        float cutoff = 350.0f + 950.0f * fminf(1.0f, (float)i / (0.7f * sr)) +
                       110.0f * sinf(2.0f * kPi * 0.13f * (float)i / sr);

        for (int n = 0; n < count; ++n) {
            float f = midiToFreq(notes[n]);
            float s = 0.5f * (oscA[n].saw(f, sr) + oscB[n].saw(f * detune, sr));
            s = filter[n].lowpass(s, cutoff, 0.8f, sr);
            float pan = -0.4f + 0.4f * (float)n;
            float v = s * env * gain;
            addStereo(b.dryL, b.dryR, b.total, idx, v, pan);
            addStereo(b.verbL, b.verbR, b.total, idx, v * 0.5f, pan);
        }
    }
}

void renderBass(Buses &b, size_t start, size_t length, float freq, float gain, float sr) {
    Osc saw;
    Osc sub;
    SVF filter;

    for (size_t i = 0; i < length; ++i) {
        size_t idx = start + i;
        if (idx >= b.total) {
            break;
        }
        float attack = fminf(1.0f, (float)i / (0.004f * sr));
        float decay = 0.45f + 0.55f * expf(-(float)i / (0.18f * sr));
        float env = attack * decay * declick(i, length, sr);

        float s = 0.8f * saw.saw(freq, sr) + 0.6f * sub.sine(freq * 0.5f, sr);
        float cutoff = 180.0f + 1500.0f * expf(-(float)i / (0.13f * sr));
        s = filter.lowpass(s, cutoff, 1.3f, sr);
        s = tanhf(s * 1.6f) * 0.75f;
        addStereo(b.dryL, b.dryR, b.total, idx, s * env * gain, 0.0f);
        addStereo(b.verbL, b.verbR, b.total, idx, s * env * gain * 0.06f, 0.0f);
    }
}

void renderArp(Buses &b, size_t start, size_t length, float freq, float gain, float sr) {
    Osc osc;
    SVF filter;

    for (size_t i = 0; i < length; ++i) {
        size_t idx = start + i;
        if (idx >= b.total) {
            break;
        }
        float env = fminf(1.0f, (float)i / (0.002f * sr)) * expf(-(float)i / (0.075f * sr));
        env *= declick(i, length, sr);

        float s = osc.square(freq, sr, 0.32f) * 0.35f;
        float cutoff = 900.0f + 2600.0f * expf(-(float)i / (0.055f * sr));
        s = filter.lowpass(s, cutoff, 1.1f, sr);
        float pan = 0.25f * sinf(2.0f * kPi * 0.11f * (float)i / sr + freq);
        addStereo(b.dryL, b.dryR, b.total, idx, s * env * gain, pan);
        addStereo(b.delayL, b.delayR, b.total, idx, s * env * gain * 0.4f, pan);
        addStereo(b.verbL, b.verbR, b.total, idx, s * env * gain * 0.15f, pan);
    }
}

void renderLead(Buses &b, size_t start, size_t length, float freq, float gain, float sr) {
    Osc oscA;
    Osc oscB;
    SVF filter;

    for (size_t i = 0; i < length; ++i) {
        size_t idx = start + i;
        if (idx >= b.total) {
            break;
        }
        float vibrato = 1.0f + 0.004f * sinf(2.0f * kPi * 5.4f * (float)i / sr) *
                                   fminf(1.0f, (float)i / (0.15f * sr));
        float f = freq * vibrato;

        float attack = fminf(1.0f, (float)i / (0.010f * sr));
        float decay = 0.75f + 0.25f * expf(-(float)i / (0.22f * sr));
        float release = fminf(1.0f, (float)(length - 1 - i) / (0.035f * sr));
        float env = attack * decay * release * declick(i, length, sr);

        float s = 0.55f * (oscA.saw(f, sr) + oscB.saw(f * 1.006f, sr));
        float cutoff = 1200.0f + 1700.0f * expf(-(float)i / (0.16f * sr));
        s = filter.lowpass(s, cutoff, 0.9f, sr);
        addStereo(b.dryL, b.dryR, b.total, idx, s * env * gain, 0.1f);
        addStereo(b.delayL, b.delayR, b.total, idx, s * env * gain * 0.35f, 0.1f);
        addStereo(b.verbL, b.verbR, b.total, idx, s * env * gain * 0.25f, 0.1f);
    }
}

void renderKick(Buses &b, size_t start, size_t length, float gain, float sr, Rng &rng) {
    float phase = 0.0f;

    for (size_t i = 0; i < length; ++i) {
        size_t idx = start + i;
        if (idx >= b.total) {
            break;
        }
        float f = 45.0f + 95.0f * expf(-(float)i / (0.045f * sr));
        phase += f / sr;
        if (phase >= 1.0f) {
            phase -= 1.0f;
        }
        float body = sinf(2.0f * kPi * phase);
        float env = expf(-(float)i / (0.16f * sr)) * declick(i, length, sr);
        float click = 0.0f;
        if (i < (size_t)(0.004f * sr)) {
            click = rng.next() * (1.0f - (float)i / (0.004f * sr)) * 0.4f;
        }
        float s = tanhf((body + click) * 1.5f) * env * gain;
        addStereo(b.dryL, b.dryR, b.total, idx, s, 0.0f);
    }
}

void renderSnare(Buses &b, size_t start, size_t length, float gain, float sr, Rng &rng) {
    Osc tone;
    SVF highpass;

    for (size_t i = 0; i < length; ++i) {
        size_t idx = start + i;
        if (idx >= b.total) {
            break;
        }
        float noise = rng.next();
        float noiseEnv = expf(-(float)i / (0.11f * sr));
        float toneEnv = expf(-(float)i / (0.045f * sr));
        float s = 0.9f * highpass.highpass(noise, 1600.0f, 0.7f, sr) * noiseEnv +
                  0.45f * tone.sine(185.0f, sr) * toneEnv;
        s *= declick(i, length, sr) * gain;
        addStereo(b.dryL, b.dryR, b.total, idx, s, 0.0f);
        addStereo(b.verbL, b.verbR, b.total, idx, s * 0.22f, 0.0f);
    }
}

void renderHat(Buses &b, size_t start, size_t length, float gain, bool open, float sr, Rng &rng) {
    SVF highpass;
    float tau = open ? 0.22f : 0.030f;

    for (size_t i = 0; i < length; ++i) {
        size_t idx = start + i;
        if (idx >= b.total) {
            break;
        }
        float noise = rng.next();
        float env = expf(-(float)i / (tau * sr)) * declick(i, length, sr);
        float s = highpass.highpass(noise, 6800.0f, 0.75f, sr) * env * gain;
        addStereo(b.dryL, b.dryR, b.total, idx, s, (open ? 0.2f : -0.15f));
        addStereo(b.verbL, b.verbR, b.total, idx, s * 0.12f, 0.0f);
    }
}

void renderRiser(Buses &b, size_t start, size_t length, float sr, Rng &rng) {
    SVF band;
    for (size_t i = 0; i < length; ++i) {
        size_t idx = start + i;
        if (idx >= b.total) {
            break;
        }
        float progress = (float)i / (float)length;
        float cutoff = 250.0f * powf(24.0f, progress);
        float env = progress * progress;
        float s = band.lowpass(rng.next(), cutoff, 5.0f, sr) * env * 0.45f *
                  declick(i, length, sr);
        addStereo(b.dryL, b.dryR, b.total, idx, s, 0.0f);
        addStereo(b.verbL, b.verbR, b.total, idx, s * 0.35f, 0.0f);
    }
}

struct Comb {
    std::vector<float> buffer;
    size_t index = 0;
    float store = 0.0f;

    explicit Comb(size_t length) : buffer(length, 0.0f) {}

    float process(float in, float feedback, float damp) {
        float out = buffer[index];
        store = out * (1.0f - damp) + store * damp;
        buffer[index] = in + store * feedback;
        if (++index >= buffer.size()) {
            index = 0;
        }
        return out;
    }
};

struct Allpass {
    std::vector<float> buffer;
    size_t index = 0;

    explicit Allpass(size_t length) : buffer(length, 0.0f) {}

    float process(float in, float feedback) {
        float out = buffer[index];
        buffer[index] = in + out * feedback;
        if (++index >= buffer.size()) {
            index = 0;
        }
        return -in + out;
    }
};

void processDelay(const float *busL, const float *busR, float *outL, float *outR,
                  size_t frames, float sr, float delaySeconds, float feedback, float wet) {
    size_t length = (size_t)(delaySeconds * sr);
    std::vector<float> lineL(length, 0.0f);
    std::vector<float> lineR(length, 0.0f);
    size_t index = 0;

    for (size_t i = 0; i < frames; ++i) {
        float a = lineL[index];
        float b = lineR[index];
        lineL[index] = busL[i] + b * feedback;
        lineR[index] = busR[i] + a * feedback;
        outL[i] += a * wet;
        outR[i] += b * wet;
        if (++index >= length) {
            index = 0;
        }
    }
}

void processReverb(const float *busL, const float *busR, float *outL, float *outR,
                   size_t frames, float wet) {
    static const size_t combL[4] = {1116, 1188, 1277, 1356};
    static const size_t combR[4] = {1139, 1211, 1300, 1379};
    static const size_t apL[3] = {556, 441, 341};
    static const size_t apR[3] = {579, 464, 364};
    constexpr float feedback = 0.84f;
    constexpr float damp = 0.35f;
    constexpr float gain = 0.05f;

    Comb combsL[4] = {Comb(combL[0]), Comb(combL[1]), Comb(combL[2]), Comb(combL[3])};
    Comb combsR[4] = {Comb(combR[0]), Comb(combR[1]), Comb(combR[2]), Comb(combR[3])};
    Allpass apsL[3] = {Allpass(apL[0]), Allpass(apL[1]), Allpass(apL[2])};
    Allpass apsR[3] = {Allpass(apR[0]), Allpass(apR[1]), Allpass(apR[2])};

    for (size_t i = 0; i < frames; ++i) {
        float in = (busL[i] + busR[i]) * 0.5f;
        float accL = 0.0f;
        float accR = 0.0f;
        for (int k = 0; k < 4; ++k) {
            accL += combsL[k].process(in, feedback, damp);
            accR += combsR[k].process(in, feedback, damp);
        }
        for (int k = 0; k < 3; ++k) {
            accL = apsL[k].process(accL, 0.5f);
            accR = apsR[k].process(accR, 0.5f);
        }
        outL[i] += accL * gain * wet;
        outR[i] += accR * gain * wet;
    }
}

} // namespace

Synth::Synth() = default;

void Synth::renderTrack() {
    const int sr = kSampleRate;
    const float srf = (float)sr;
    const double bpm = 128.0;
    const double spb = 60.0 / bpm;
    const double barDur = 4.0 * spb;
    const double stepDur = barDur / 16.0;
    const int bars = 16;
    const double tail = 3.5;
    const size_t total = (size_t)((bars * barDur + tail) * sr);

    _buffer.assign(total * 2, 0.0f);
    std::vector<float> dryL(total, 0.0f);
    std::vector<float> dryR(total, 0.0f);
    std::vector<float> delayL(total, 0.0f);
    std::vector<float> delayR(total, 0.0f);
    std::vector<float> verbL(total, 0.0f);
    std::vector<float> verbR(total, 0.0f);

    Buses buses{dryL.data(), dryR.data(), delayL.data(), delayR.data(),
                verbL.data(), verbR.data(), total};

    Rng rng;
    auto at = [](double seconds) { return (size_t)(seconds * Synth::kSampleRate); };

    static const int padNotes[4][3] = {{57, 60, 64}, {53, 57, 60}, {60, 64, 67}, {55, 59, 62}};
    static const int roots[4] = {45, 41, 48, 43};
    static const int tones[4][3] = {{0, 3, 7}, {0, 4, 7}, {0, 4, 7}, {0, 4, 7}};
    static const int leadPattern[4][8] = {
        {69, 0, 72, 0, 76, 74, 72, 69},
        {65, 0, 69, 0, 72, 69, 67, 65},
        {67, 0, 72, 0, 76, 72, 67, 64},
        {67, 0, 71, 0, 74, 71, 67, 0},
    };
    static const int bassPattern[8] = {0, 0, 7, 0, 0, 12, 7, 0};
    static const int arpIndex[4] = {0, 1, 2, 1};

    for (int bar = 0; bar < bars; ++bar) {
        const int chord = bar % 4;
        const size_t barStart = at(bar * barDur);

        float padGain = bar < 4 ? 0.095f : 0.070f;
        renderPad(buses, barStart, at(barDur + 1.2), padNotes[chord], 3, padGain, srf);

        if (bar >= 4) {
            for (int s = 0; s < 8; ++s) {
                int note = roots[chord] + bassPattern[s];
                renderBass(buses, barStart + at(s * 2 * stepDur), at(stepDur * 1.8),
                           midiToFreq(note), 0.36f, srf);
            }
        }

        if ((bar >= 4 && bar <= 7) || bar == 12 || bar == 13 || bar == 15) {
            for (int s = 0; s < 16; ++s) {
                int note = roots[chord] + 24 + tones[chord][arpIndex[s % 4]];
                renderArp(buses, barStart + at(s * stepDur), at(stepDur * 0.95),
                          midiToFreq(note), 0.13f, srf);
            }
        }

        if (bar >= 8) {
            for (int s = 0; s < 8; ++s) {
                int note = leadPattern[chord][s];
                if (note == 0) {
                    continue;
                }
                renderLead(buses, barStart + at(s * 2 * stepDur), at(stepDur * 1.9),
                           midiToFreq(note), 0.22f, srf);
            }
        }

        if (bar == 7) {
            renderRiser(buses, barStart, at(barDur), srf, rng);
        }

        if ((bar >= 6 && bar <= 13) || bar == 15) {
            renderKick(buses, barStart, at(0.5), 0.72f, srf, rng);
            renderKick(buses, barStart + at(2 * spb), at(0.5), 0.68f, srf, rng);
            if (bar >= 8 && bar <= 11) {
                renderKick(buses, barStart + at(3.5 * spb), at(0.5), 0.55f, srf, rng);
            }
        }

        if (bar >= 8 && bar <= 13) {
            renderSnare(buses, barStart + at(spb), at(0.3), 0.45f, srf, rng);
            renderSnare(buses, barStart + at(3 * spb), at(0.3), 0.45f, srf, rng);
        } else if (bar == 7) {
            for (int s = 12; s < 16; ++s) {
                float gain = 0.22f + 0.07f * (float)(s - 12);
                renderSnare(buses, barStart + at(s * stepDur), at(0.2), gain, srf, rng);
            }
        } else if (bar == 14) {
            renderSnare(buses, barStart + at(3 * spb), at(0.3), 0.38f, srf, rng);
        }

        if (bar >= 2 && bar != 14) {
            bool eighths = bar >= 6;
            for (int s = 0; s < 16; s += 2) {
                bool offbeat = (s % 4) == 2;
                if (!eighths && !offbeat) {
                    continue;
                }
                float gain = offbeat ? 0.13f : 0.075f;
                renderHat(buses, barStart + at(s * stepDur), at(0.05), gain, false, srf, rng);
            }
            if (bar == 11 || bar == 15) {
                renderHat(buses, barStart + at(14 * stepDur), at(0.3), 0.12f, true, srf, rng);
            }
        }
    }

    processDelay(delayL.data(), delayR.data(), dryL.data(), dryR.data(), total, srf,
                 (float)(0.75 * spb), 0.36f, 0.7f);
    processReverb(verbL.data(), verbR.data(), dryL.data(), dryR.data(), total, 1.0f);

    for (size_t i = 0; i < total; ++i) {
        _buffer[2 * i] = softclip(dryL[i]);
        _buffer[2 * i + 1] = softclip(dryR[i]);
    }
}

bool WriteWavPcm16(const char *path, const float *interleaved, size_t frames, int sampleRate) {
    FILE *file = fopen(path, "wb");
    if (!file) {
        return false;
    }

    uint32_t dataBytes = (uint32_t)(frames * 2 * 2);
    uint32_t riffSize = 36 + dataBytes;
    uint32_t fmtSize = 16;
    uint16_t audioFormat = 1;
    uint16_t channels = 2;
    uint32_t rate = (uint32_t)sampleRate;
    uint32_t byteRate = rate * 4;
    uint16_t blockAlign = 4;
    uint16_t bitsPerSample = 16;

    fwrite("RIFF", 1, 4, file);
    fwrite(&riffSize, 4, 1, file);
    fwrite("WAVE", 1, 4, file);
    fwrite("fmt ", 1, 4, file);
    fwrite(&fmtSize, 4, 1, file);
    fwrite(&audioFormat, 2, 1, file);
    fwrite(&channels, 2, 1, file);
    fwrite(&rate, 4, 1, file);
    fwrite(&byteRate, 4, 1, file);
    fwrite(&blockAlign, 2, 1, file);
    fwrite(&bitsPerSample, 2, 1, file);
    fwrite("data", 1, 4, file);
    fwrite(&dataBytes, 4, 1, file);

    for (size_t i = 0; i < frames * 2; ++i) {
        float x = interleaved[i];
        if (x > 1.0f) {
            x = 1.0f;
        } else if (x < -1.0f) {
            x = -1.0f;
        }
        int16_t sample = (int16_t)lrintf(x * 32767.0f);
        fwrite(&sample, 2, 1, file);
    }

    fclose(file);
    return true;
}
