// Feed an Annex-B H.264 file to a decoder one frame at a time (like RustDesk does) and report
// how many packets each frame lags behind and the latency per frame.
// usage: v4ltest <file.h264> <decoder> <fps> [dump_frame_n] [ffmpeg_option=value ...]
// build on the box: gcc -O2 -o v4ltest v4ltest.c $(pkg-config --cflags --libs libavcodec libavformat libavutil)
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

int main(int argc, char **argv) {
    const char *file = argv[1], *dec = argv[2];
    int fps = atoi(argv[3]), dump = argc > 4 ? atoi(argv[4]) : -1;
    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, file, NULL, NULL) < 0) return 1;
    avformat_find_stream_info(fmt, NULL);
    const AVCodec *codec = avcodec_find_decoder_by_name(dec);
    AVCodecContext *c = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(c, fmt->streams[0]->codecpar);
    c->flags |= AV_CODEC_FLAG_LOW_DELAY;
    AVDictionary *opt = NULL;
    for (int i = 5; i < argc; i++) { char k[64]; const char *v = strchr(argv[i], '=');
        snprintf(k, sizeof k, "%.*s", (int)(v - argv[i]), argv[i]); av_dict_set(&opt, k, v + 1, 0); }
    int ro = avcodec_open2(c, codec, &opt); if (ro < 0) { fprintf(stderr, "open failed: %s\n", av_err2str(ro)); return 1; }
    AVPacket *pkt = av_packet_alloc();
    AVFrame *fr = av_frame_alloc();
    double tin[4096]; int hist[32] = {0}; int in = 0, out = 0, lagmax = 0; double lat = 0, latmax = 0, t0 = now();
    while (av_read_frame(fmt, pkt) >= 0) {
        double due = t0 + (double)in / fps;
        while (now() < due) usleep(500);
        pkt->pts = in; pkt->dts = in;
        tin[in % 4096] = now();
        int r = avcodec_send_packet(c, pkt);
        if (r < 0) fprintf(stderr, "send %d: %s\n", in, av_err2str(r));
        in++;
        av_packet_unref(pkt);
        while (avcodec_receive_frame(c, fr) == 0) {
            long p = fr->pts >= 0 ? fr->pts : (fr->best_effort_timestamp >= 0 ? fr->best_effort_timestamp : out); double l = now() - tin[p % 4096];
            lat += l; if (l > latmax) latmax = l;
            if (in - out > lagmax) lagmax = in - out;
            if (out >= 60) { hist[(in - 1 - out) < 31 ? (in - 1 - out) : 31]++; }
            if (out < 3 || out == dump)
                printf("frame %d (pts %ld) after packet %d: %dx%d fmt %s, latency %.1f ms\n", out, (long)fr->pts, in - 1,
                       fr->width, fr->height, av_get_pix_fmt_name(fr->format), l * 1000);
            if (out == dump) {
                FILE *f = fopen("/root/frame.yuv", "wb");
                for (int y = 0; y < fr->height; y++) fwrite(fr->data[0] + y * fr->linesize[0], 1, fr->width, f);
                for (int y = 0; y < fr->height / 2; y++) fwrite(fr->data[1] + y * fr->linesize[1], 1, fr->width, f);
                fclose(f);
                printf("dumped, linesize %d %d\n", fr->linesize[0], fr->linesize[1]);
            }
            out++;
            av_frame_unref(fr);
        }
    }
    double s = now() - t0;
    printf("%s: in %d out %d (without flush) in %.2fs = %.1f fps; frames held behind input max %d; latency avg %.1f ms max %.1f ms\n",
           dec, in, out, s, out / s, lagmax - 1, out ? lat / out * 1000 : 0, latmax * 1000);
    printf("steady state (after frame 60): frames behind input -> count:");
    for (int i = 0; i < 32; i++) if (hist[i]) printf(" %d->%d", i, hist[i]);
    printf("\n");
    return 0;
}
