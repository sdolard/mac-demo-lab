#pragma once

#include <cstddef>
#include <vector>

class Synth {
public:
    static constexpr int kSampleRate = 44100;

    Synth();

    /// Renders the full sequenced track into an internal stereo buffer.
    void renderTrack();

    const float *interleaved() const { return _buffer.data(); }
    size_t frameCount() const { return _buffer.size() / 2; }

private:
    std::vector<float> _buffer;
};

bool WriteWavPcm16(const char *path, const float *interleaved, size_t frames, int sampleRate);
