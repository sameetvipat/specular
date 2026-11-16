// mkcc — make a short test clip with embedded EIA-608 closed captions (A/53 cc_data).
// Usage: mkcc <out.mkv> [h264|hevc]
// 20 s, 30 fps, 320x240, B-frames on (so cc_data arrives out of display order).
// Captions (CC1, pop-on), shown at EOC time, cleared at EDM time:
//   1.0 s  "HELLO CC ONE"      cleared 4.0 s
//   6.0 s  "SECOND CAPTION"    cleared 9.0 s
//  12.0 s  "THIRD AT TWELVE"   cleared 15.0 s
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
#include <string.h>
#include <stdio.h>

#define FPS 30
#define SECS 20
#define NF (FPS * SECS)

static uint8_t pairs[NF][2];   // one 608 byte pair per frame (0 = padding)
static int     used[NF];

static uint8_t par(uint8_t b) {            // odd parity in bit 7
    int ones = __builtin_popcount(b & 0x7F);
    return (b & 0x7F) | ((ones & 1) ? 0 : 0x80);
}
static void put(int f, uint8_t a, uint8_t b) { pairs[f][0] = par(a); pairs[f][1] = par(b); used[f] = 1; }

// Load `text` so End-Of-Caption lands exactly on frame `showF`; erase on `clearF`.
static void caption(const char *text, int showF, int clearF) {
    int n = (int)strlen(text), chars = (n + 1) / 2;
    int f = showF - (2 + 2 + chars);        // RCL x2, PAC x2, chars, then EOC x2 at showF
    put(f++, 0x14, 0x20); put(f++, 0x14, 0x20);          // RCL
    put(f++, 0x14, 0x60); put(f++, 0x14, 0x60);          // PAC row 15, white
    for (int i = 0; i < n; i += 2) put(f++, text[i], i + 1 < n ? text[i + 1] : 0);
    put(showF, 0x14, 0x2F); put(showF + 1, 0x14, 0x2F);  // EOC (display)
    put(clearF, 0x14, 0x2C); put(clearF + 1, 0x14, 0x2C); // EDM (erase)
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: mkcc <out.mkv> [h264|hevc]\n"); return 2; }
    int hevc = argc > 2 && !strcmp(argv[2], "hevc");
    caption("HELLO CC ONE", 1 * FPS, 4 * FPS);
    caption("SECOND CAPTION", 6 * FPS, 9 * FPS);
    caption("THIRD AT TWELVE", 12 * FPS, 15 * FPS);

    AVFormatContext *oc = NULL;
    if (avformat_alloc_output_context2(&oc, NULL, NULL, argv[1]) < 0) return 1;
    const AVCodec *c = avcodec_find_encoder_by_name(hevc ? "libx265" : "libx264");
    if (!c) { fprintf(stderr, "no encoder\n"); return 1; }
    AVCodecContext *ec = avcodec_alloc_context3(c);
    ec->width = 320; ec->height = 240; ec->pix_fmt = AV_PIX_FMT_YUV420P;
    ec->time_base = (AVRational){1, FPS}; ec->framerate = (AVRational){FPS, 1};
    ec->gop_size = 60; ec->max_b_frames = 3;
    if (oc->oformat->flags & AVFMT_GLOBALHEADER) ec->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    av_opt_set(ec->priv_data, "preset", "fast", 0);
    av_opt_set_int(ec->priv_data, "a53cc", 1, 0);
    if (hevc) av_opt_set(ec->priv_data, "x265-params", "log-level=error", 0);
    if (avcodec_open2(ec, c, NULL) < 0) { fprintf(stderr, "open encoder failed\n"); return 1; }
    AVStream *st = avformat_new_stream(oc, NULL);
    avcodec_parameters_from_context(st->codecpar, ec);
    st->time_base = ec->time_base;
    if (avio_open(&oc->pb, argv[1], AVIO_FLAG_WRITE) < 0) return 1;
    if (avformat_write_header(oc, NULL) < 0) return 1;

    AVFrame *fr = av_frame_alloc();
    fr->format = ec->pix_fmt; fr->width = ec->width; fr->height = ec->height;
    av_frame_get_buffer(fr, 0);
    AVPacket *pk = av_packet_alloc();
    for (int i = 0; i <= NF; i++) {
        AVFrame *in = NULL;
        if (i < NF) {
            av_frame_make_writable(fr);
            for (int y = 0; y < fr->height; y++)                  // moving gradient
                for (int x = 0; x < fr->width; x++) fr->data[0][y * fr->linesize[0] + x] = (uint8_t)(x + y + i * 3);
            memset(fr->data[1], 128, (size_t)fr->linesize[1] * fr->height / 2);
            memset(fr->data[2], 128, (size_t)fr->linesize[2] * fr->height / 2);
            fr->pts = i;
            av_frame_remove_side_data(fr, AV_FRAME_DATA_A53_CC);
            AVFrameSideData *sd = av_frame_new_side_data(fr, AV_FRAME_DATA_A53_CC, 3);
            sd->data[0] = 0xFC;                                    // marker, cc_valid, type 0 (field 1)
            sd->data[1] = used[i] ? pairs[i][0] : 0x80;            // padding = 0x80 0x80
            sd->data[2] = used[i] ? pairs[i][1] : 0x80;
            in = fr;
        }
        if (avcodec_send_frame(ec, in) < 0) return 1;
        while (avcodec_receive_packet(ec, pk) == 0) {
            av_packet_rescale_ts(pk, ec->time_base, st->time_base);
            pk->stream_index = st->index;
            av_interleaved_write_frame(oc, pk);
        }
    }
    av_write_trailer(oc);
    avio_closep(&oc->pb);
    printf("wrote %s (%s, %d frames)\n", argv[1], hevc ? "hevc" : "h264", NF);
    return 0;
}
