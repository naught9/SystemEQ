// Runs a JSFX on deterministic test audio and writes the output as raw doubles.
// Usage: host <script.jsfx> <sample rate> <frames> <output.bin>
#include "ysfx.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

int main(int argc, char **argv) {
    if (argc != 5) { std::fprintf(stderr, "usage: host script rate frames out\n"); return 2; }
    const double rate = std::atof(argv[2]);
    const uint32_t frames = (uint32_t)std::atoi(argv[3]);

    ysfx_config_t *config = ysfx_config_new();
    ysfx_t *fx = ysfx_new(config);
    ysfx_config_free(config);
    if (!ysfx_load_file(fx, argv[1], 0) || !ysfx_compile(fx, 0)) { std::fprintf(stderr, "failed to load or compile\n"); return 1; }
    ysfx_set_sample_rate(fx, rate);
    ysfx_set_block_size(fx, 512);
    ysfx_init(fx);

    // Same generator as the Swift side: an impulse, then xorshift noise in [-0.5, 0.5), in float precision.
    std::vector<double> left(frames), right(frames);
    uint64_t state = 0x9E3779B97F4A7C15ull;
    for (uint32_t i = 0; i < frames; ++i) {
        for (int ch = 0; ch < 2; ++ch) {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17;
            double v = (double)(state >> 11) / 9007199254740992.0 - 0.5;
            if (i == 0) v = 0.9;
            (ch == 0 ? left : right)[i] = (double)(float)v;
        }
    }

    std::vector<double> outLeft(frames), outRight(frames);
    for (uint32_t start = 0; start < frames; start += 512) {
        uint32_t n = frames - start < 512 ? frames - start : 512;
        const double *ins[2] = { left.data() + start, right.data() + start };
        double *outs[2] = { outLeft.data() + start, outRight.data() + start };
        ysfx_process_double(fx, ins, outs, 2, 2, n);
    }
    std::FILE *file = std::fopen(argv[4], "wb");
    std::fwrite(outLeft.data(), sizeof(double), frames, file);
    std::fwrite(outRight.data(), sizeof(double), frames, file);
    std::fclose(file);
    ysfx_free(fx);
    return 0;
}
