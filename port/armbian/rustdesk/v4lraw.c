// Raw V4L2 stateful decoder test (meson-vdec): queue one H.264 access unit at a time and
// wait for the decoded frame, to see how many frames the driver/firmware holds back.
// usage: v4lraw <file.h264> <fps> [tail: 1 = append AUD, 2 = append end of sequence]
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define NOUT 4
#define NCAP 24
static int fd;
static void *outmap[NOUT]; static size_t outlen[NOUT];
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static int x(int r, const char *what) { if (r < 0) { fprintf(stderr, "%s: %s\n", what, strerror(errno)); exit(1); } return r; }

// split Annex-B into access units: a new AU starts at a slice with first_mb == 0 (byte after header has top bit set)
// or at SPS/PPS/AUD/SEI that follows a slice
static unsigned char *data; static size_t len, pos;
static int next_au(size_t *start, size_t *end) {
    if (pos >= len) return 0;
    size_t i = pos; int seen_slice = 0; *start = pos;
    for (;;) {
        // find next start code after i
        size_t j = i + 3;
        while (j + 3 < len && !(data[j] == 0 && data[j + 1] == 0 && data[j + 2] == 1)) j++;
        if (j + 3 >= len) { *end = len; pos = len; return 1; }
        int type = data[j + 3] & 0x1f;
        int cur = data[i + 3 - (data[i + 2] == 1 ? 0 : -1)] & 0x1f;
        (void)cur;
        // what was the NAL at i?
        size_t k = i; while (data[k] == 0) k++; k++; int ti = data[k] & 0x1f;
        if (ti == 1 || ti == 5) seen_slice = 1;
        if (seen_slice && (type == 7 || type == 8 || type == 9 || type == 6 || ((type == 1 || type == 5) && (data[j + 4] & 0x80)))) {
            size_t e = j; while (e > *start && data[e - 1] == 0) e--;
            *end = e; pos = e; return 1;
        }
        i = j;
    }
}

int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "rb"); fseek(f, 0, SEEK_END); len = ftell(f); rewind(f);
    data = malloc(len); fread(data, 1, len, f); fclose(f);
    int fps = atoi(argv[2]), tail = argc > 3 ? atoi(argv[3]) : 0;
    fd = x(open("/dev/video0", O_RDWR | O_NONBLOCK), "open");

    struct v4l2_format fmt = {.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE};
    fmt.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_H264; fmt.fmt.pix_mp.width = 2560; fmt.fmt.pix_mp.height = 1080;
    fmt.fmt.pix_mp.num_planes = 1; fmt.fmt.pix_mp.plane_fmt[0].sizeimage = 2 << 20;
    x(ioctl(fd, VIDIOC_S_FMT, &fmt), "S_FMT out");
    struct v4l2_format cf = {.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE};
    cf.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12M; cf.fmt.pix_mp.width = 2560; cf.fmt.pix_mp.height = 1080;
    if (ioctl(fd, VIDIOC_S_FMT, &cf) < 0) { cf.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12; x(ioctl(fd, VIDIOC_S_FMT, &cf), "S_FMT cap"); }

    struct v4l2_requestbuffers rb = {.count = NOUT, .type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, .memory = V4L2_MEMORY_MMAP};
    x(ioctl(fd, VIDIOC_REQBUFS, &rb), "REQBUFS out");
    for (int i = 0; i < NOUT; i++) {
        struct v4l2_plane p[1]; struct v4l2_buffer b = {.type = rb.type, .memory = V4L2_MEMORY_MMAP, .index = i, .m.planes = p, .length = 1};
        x(ioctl(fd, VIDIOC_QUERYBUF, &b), "QUERYBUF");
        outlen[i] = p[0].length; outmap[i] = mmap(NULL, p[0].length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, p[0].m.mem_offset);
    }
    int ot = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE; x(ioctl(fd, VIDIOC_STREAMON, &ot), "STREAMON out");
    struct v4l2_event_subscription sub = {.type = V4L2_EVENT_SOURCE_CHANGE}; ioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &sub);

    int cap_ready = 0, ncap = 0, in = 0, out = 0, free_out[NOUT], nfree = NOUT;
    for (int i = 0; i < NOUT; i++) free_out[i] = i;
    double tin[8192]; int hist[40] = {0}; double lat = 0, latmax = 0, t0 = now();
    size_t s, e;
    int more = next_au(&s, &e);
    while (more || out < in) {
        double tnow = now();
        // feed
        if (more && nfree > 0 && tnow >= t0 + (double)in / fps) {
            int i = free_out[--nfree];
            memcpy(outmap[i], data + s, e - s);
            size_t n = e - s;
            // tail 1: access unit delimiter, 2: end of sequence, 3: AUD + filler-free padding of zeros
            static const unsigned char aud[] = {0, 0, 0, 1, 9, 0xf0}, eoseq[] = {0, 0, 0, 1, 0x0a};
            if (tail == 1 || tail == 3) { memcpy((char *)outmap[i] + n, aud, sizeof aud); n += sizeof aud; }
            if (tail == 2) { memcpy((char *)outmap[i] + n, eoseq, sizeof eoseq); n += sizeof eoseq; }
            struct v4l2_plane p[1] = {{.bytesused = n}};
            struct v4l2_buffer b = {.type = ot, .memory = V4L2_MEMORY_MMAP, .index = i, .m.planes = p, .length = 1};
            b.timestamp.tv_sec = in / 1000000; b.timestamp.tv_usec = in % 1000000;
            tin[in % 8192] = now();
            x(ioctl(fd, VIDIOC_QBUF, &b), "QBUF out");
            in++;
            more = next_au(&s, &e);
        }
        struct pollfd pf = {.fd = fd, .events = POLLIN | POLLOUT | POLLPRI};
        poll(&pf, 1, 2);
        // reclaim output buffers
        for (;;) {
            struct v4l2_plane p[1]; struct v4l2_buffer b = {.type = ot, .memory = V4L2_MEMORY_MMAP, .m.planes = p, .length = 1};
            if (ioctl(fd, VIDIOC_DQBUF, &b) < 0) break;
            free_out[nfree++] = b.index;
        }
        // source change: set up capture
        struct v4l2_event ev;
        while (ioctl(fd, VIDIOC_DQEVENT, &ev) == 0) {
            if (ev.type == V4L2_EVENT_SOURCE_CHANGE && !cap_ready) {
                struct v4l2_format g = {.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE}; x(ioctl(fd, VIDIOC_G_FMT, &g), "G_FMT");
                struct v4l2_control mc = {.id = V4L2_CID_MIN_BUFFERS_FOR_CAPTURE}; ioctl(fd, VIDIOC_G_CTRL, &mc);
                ncap = mc.value + 2 > NCAP ? NCAP : mc.value + 2;
                printf("capture %ux%u fourcc %.4s planes %d, min buffers %d, using %d\n", g.fmt.pix_mp.width, g.fmt.pix_mp.height,
                       (char *)&g.fmt.pix_mp.pixelformat, g.fmt.pix_mp.num_planes, mc.value, ncap);
                struct v4l2_requestbuffers cr = {.count = ncap, .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, .memory = V4L2_MEMORY_MMAP};
                x(ioctl(fd, VIDIOC_REQBUFS, &cr), "REQBUFS cap"); ncap = cr.count;
                for (int i = 0; i < ncap; i++) {
                    struct v4l2_plane p[3]; struct v4l2_buffer b = {.type = cr.type, .memory = V4L2_MEMORY_MMAP, .index = i, .m.planes = p, .length = g.fmt.pix_mp.num_planes};
                    x(ioctl(fd, VIDIOC_QBUF, &b), "QBUF cap");
                }
                int ct = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE; x(ioctl(fd, VIDIOC_STREAMON, &ct), "STREAMON cap");
                cap_ready = 1;
            }
        }
        if (cap_ready) {
            for (;;) {
                struct v4l2_plane p[3]; struct v4l2_buffer b = {.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, .memory = V4L2_MEMORY_MMAP, .m.planes = p, .length = 3};
                if (ioctl(fd, VIDIOC_DQBUF, &b) < 0) break;
                long id = b.timestamp.tv_sec * 1000000 + b.timestamp.tv_usec;
                double l = now() - tin[id % 8192];
                if (out >= 60) { int lag = in - 1 - id; hist[lag < 39 ? lag : 39]++; lat += l; if (l > latmax) latmax = l; }
                if (out < 3) printf("frame %d = input %ld after %d queued, latency %.1f ms\n", out, id, in, l * 1000);
                out++;
                x(ioctl(fd, VIDIOC_QBUF, &b), "QBUF cap again");
            }
        }
        if (!more && now() - tin[(in - 1) % 8192] > 2.0) break;
    }
    double t = now() - t0;
    printf("in %d out %d in %.2fs; steady (after 60): latency avg %.1f ms max %.1f ms; frames behind input:", in, out, t,
           out > 60 ? lat / (out - 60) * 1000 : 0, latmax * 1000);
    for (int i = 0; i < 40; i++) if (hist[i]) printf(" %d->%d", i, hist[i]);
    printf("\n");
    return 0;
}
