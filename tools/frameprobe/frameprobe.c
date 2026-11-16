// frameprobe.c — Stage 1.5: decode one frame and read *bitstream* HDR/DV metadata.
//
// `probe` only demuxes, so it sees container-level metadata. But HDR10 mastering
// SEI and the Dolby Vision RPU live *inside* the HEVC bitstream and only surface
// once you actually decode a frame. This tool opens the video stream's decoder,
// decodes until the first full frame, and reports the per-frame side data the
// Metal tone-mapper will ultimately consume.
//
// Build: scripts/quiet.sh build.sh frameprobe
// Usage: .build/debug/frameprobe /path/to/movie.mkv

#include <stdio.h>
#include <string.h>
#include <inttypes.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/pixdesc.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/frame.h>

static const char *s(const char *v) { return v ? v : "?"; }

static void report_frame_side_data(const AVFrame *f) {
    int found_any = 0;
    for (int i = 0; i < f->nb_side_data; i++) {
        const AVFrameSideData *sd = f->side_data[i];
        switch (sd->type) {
            case AV_FRAME_DATA_MASTERING_DISPLAY_METADATA: {
                const AVMasteringDisplayMetadata *m = (const AVMasteringDisplayMetadata *)sd->data;
                found_any = 1;
                printf("  [frame] HDR10 mastering display (from SEI):\n");
                if (m->has_luminance)
                    printf("          luminance    : min %.4f, max %.1f cd/m^2\n",
                           av_q2d(m->min_luminance), av_q2d(m->max_luminance));
                if (m->has_primaries)
                    printf("          primaries/WP : present\n");
                break;
            }
            case AV_FRAME_DATA_CONTENT_LIGHT_LEVEL: {
                const AVContentLightMetadata *c = (const AVContentLightMetadata *)sd->data;
                found_any = 1;
                printf("  [frame] content light (from SEI): MaxCLL %d, MaxFALL %d\n",
                       c->MaxCLL, c->MaxFALL);
                break;
            }
            case AV_FRAME_DATA_DOVI_METADATA: {
                const AVDOVIMetadata *dovi = (const AVDOVIMetadata *)sd->data;
                const AVDOVIRpuDataHeader *h = av_dovi_get_header(dovi);
                found_any = 1;
                printf("  [frame] DOLBY VISION RPU metadata (parsed):\n");
                printf("          rpu_type           : %d\n", h->rpu_type);
                printf("          vdr_rpu_profile    : %d\n", h->vdr_rpu_profile);
                printf("          vdr_rpu_level      : %d\n", h->vdr_rpu_level);
                printf("          coef data type     : %d\n", h->coef_data_type);
                printf("          -> this is the dynamic metadata the Metal shader applies per-frame\n");
                break;
            }
            case AV_FRAME_DATA_DOVI_RPU_BUFFER:
                found_any = 1;
                printf("  [frame] Dolby Vision raw RPU buffer present (%zu bytes)\n", sd->size);
                break;
            case AV_FRAME_DATA_DYNAMIC_HDR_PLUS:
                found_any = 1;
                printf("  [frame] HDR10+ dynamic metadata present (%zu bytes)\n", sd->size);
                break;
            default:
                break;
        }
    }
    if (!found_any)
        printf("  [frame] no HDR/DV side data on this frame (SDR, or metadata is container-level)\n");
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <media-file>\n", argv[0]); return 2; }
    const char *path = argv[1];

    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, path, NULL, NULL) < 0) {
        fprintf(stderr, "error: cannot open %s\n", path); return 1;
    }
    if (avformat_find_stream_info(fmt, NULL) < 0) {
        fprintf(stderr, "error: cannot read stream info\n"); avformat_close_input(&fmt); return 1;
    }

    int vidx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (vidx < 0) { fprintf(stderr, "error: no video stream\n"); avformat_close_input(&fmt); return 1; }

    const AVCodecParameters *par = fmt->streams[vidx]->codecpar;
    const AVCodec *dec = avcodec_find_decoder(par->codec_id);
    if (!dec) { fprintf(stderr, "error: no decoder for %s\n", avcodec_get_name(par->codec_id)); avformat_close_input(&fmt); return 1; }

    AVCodecContext *ctx = avcodec_alloc_context3(dec);
    if (!ctx || avcodec_parameters_to_context(ctx, par) < 0 || avcodec_open2(ctx, dec, NULL) < 0) {
        fprintf(stderr, "error: cannot open decoder\n");
        avcodec_free_context(&ctx); avformat_close_input(&fmt); return 1;
    }

    printf("FILE   : %s\n", path);
    printf("VIDEO  : %s, software-decoding first frame to read bitstream metadata...\n",
           avcodec_get_name(par->codec_id));

    AVPacket *pkt = av_packet_alloc();
    AVFrame  *frm = av_frame_alloc();
    int got = 0;

    while (!got && av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index == vidx) {
            if (avcodec_send_packet(ctx, pkt) == 0) {
                while (avcodec_receive_frame(ctx, frm) == 0) {
                    const AVPixFmtDescriptor *pd = av_pix_fmt_desc_get(frm->format);
                    printf("\nDecoded frame: %dx%d, %s (%d-bit)\n",
                           frm->width, frm->height, s(pd ? pd->name : NULL),
                           pd ? pd->comp[0].depth : 0);
                    printf("  primaries=%s transfer=%s space=%s\n",
                           s(av_color_primaries_name(frm->color_primaries)),
                           s(av_color_transfer_name(frm->color_trc)),
                           s(av_color_space_name(frm->colorspace)));
                    report_frame_side_data(frm);
                    got = 1;
                    break;
                }
            }
        }
        av_packet_unref(pkt);
    }
    if (!got) printf("  (could not decode a frame)\n");

    av_frame_free(&frm);
    av_packet_free(&pkt);
    avcodec_free_context(&ctx);
    avformat_close_input(&fmt);
    return got ? 0 : 1;
}
