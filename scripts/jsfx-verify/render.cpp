// Renders a JSFX's @gfx to a PNG. Usage: render <script> <preset index> <out.png> [scale]
#include "ysfx.h"
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <cstdio>
#include <cstdlib>
#include <vector>

int main(int argc, char **argv) {
    double scale = argc > 4 ? std::atof(argv[4]) : 2.0;
    uint32_t w = (uint32_t)(640 * scale), h = (uint32_t)(360 * scale);
    ysfx_config_t *config = ysfx_config_new();
    ysfx_t *fx = ysfx_new(config);
    ysfx_config_free(config);
    if (!ysfx_load_file(fx, argv[1], 0) || !ysfx_compile(fx, 0)) { std::printf("load/compile failed\n"); return 1; }
    ysfx_set_sample_rate(fx, 48000);
    ysfx_set_block_size(fx, 128);
    ysfx_init(fx);
    ysfx_slider_set_value(fx, 0, std::atof(argv[2]), true);
    std::vector<float> buf(256, 0.f);
    const float *ins[2] = { buf.data(), buf.data() + 128 };
    float *outs[2] = { buf.data(), buf.data() + 128 };
    ysfx_process_float(fx, ins, outs, 2, 2, 128);  // runs @slider

    std::vector<uint8_t> pixels((size_t)w * h * 4, 0);
    ysfx_gfx_config_t gc{};
    gc.pixel_width = w; gc.pixel_height = h; gc.pixel_stride = w * 4; gc.pixels = pixels.data(); gc.scale_factor = scale;
    ysfx_gfx_setup(fx, &gc);
    ysfx_gfx_set_window_state(fx, true, true, false);
    for (int i = 0; i < 3; ++i) ysfx_gfx_run(fx);

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(pixels.data(), w, h, 8, w * 4, space,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CFStringRef path = CFStringCreateWithCString(nullptr, argv[3], kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(nullptr, path, kCFURLPOSIXPathStyle, false);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, nullptr);
    CGImageDestinationAddImage(dest, image, nullptr);
    bool ok = CGImageDestinationFinalize(dest);
    std::printf("%s %ux%u\n", ok ? "wrote" : "FAILED", w, h);
    ysfx_free(fx);
    return 0;
}
