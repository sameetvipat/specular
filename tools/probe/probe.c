// probe.c — Stage 1 (ingest) made visible.
//
// Opens a media file with FFmpeg's demuxer and reports exactly what the player's
// ingest layer will see: container, streams, codecs, and — the part we care about —
// the color / HDR / Dolby Vision metadata for video and the channel layout for audio.
//
// This is deliberately read-only: it demuxes and inspects, it does not decode.
// Think of it as the first thing the pipeline does before handing packets to
// VideoToolbox.
//
// Build:  scripts/quiet.sh build.sh probe
// Usage:  .build/debug/probe /path/to/movie.mkv

#include <stdio.h>
#include <string.h>
#include <inttypes.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/pixdesc.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/mastering_display_metadata.h>

static const char *s(const char *v) { return v ? v : "?"; }

// Human-readable summary of what the color_trc implies about HDR.
static const char *hdr_from_trc(enum AVColorTransferCharacteristic trc) {
    switch (trc) {
        case AVCOL_TRC_SMPTE2084:   return "HDR10 / PQ (SMPTE ST 2084)";
        case AVCOL_TRC_ARIB_STD_B67:return "HLG (Hybrid Log-Gamma)";
        case AVCOL_TRC_BT2020_10:
        case AVCOL_TRC_BT2020_12:   return "BT.2020 (non-PQ) — wide gamut, likely SDR-range";
        default:                    return "SDR";
    }
}

static void print_fourcc(uint32_t tag) {
    char buf[AV_FOURCC_MAX_STRING_SIZE] = {0};
    av_fourcc_make_string(buf, tag);
    printf("%s", buf);
}

static void inspect_video(const AVStream *st) {
    const AVCodecParameters *p = st->codecpar;
    const AVPixFmtDescriptor *pd = av_pix_fmt_desc_get((enum AVPixelFormat)p->format);

    printf("    resolution     : %dx%d\n", p->width, p->height);
    printf("    pixel format   : %s", s(pd ? pd->name : NULL));
    if (pd) printf("  (%d-bit, %d comp)", pd->comp[0].depth, pd->nb_components);
    printf("\n");

    double fps = st->avg_frame_rate.num && st->avg_frame_rate.den
                 ? av_q2d(st->avg_frame_rate) : 0.0;
    if (fps > 0) printf("    frame rate     : %.3f fps\n", fps);

    printf("    codec tag      : '"); print_fourcc(p->codec_tag); printf("'\n");

    // --- Color signalling (this is what the Metal tone-mapper keys off) ---
    printf("    color primaries: %s\n", s(av_color_primaries_name(p->color_primaries)));
    printf("    transfer (trc) : %s\n", s(av_color_transfer_name(p->color_trc)));
    printf("    color space    : %s\n", s(av_color_space_name(p->color_space)));
    printf("    color range    : %s\n", s(av_color_range_name(p->color_range)));

    const char *hdr = hdr_from_trc(p->color_trc);
    int is_hdr = (p->color_trc == AVCOL_TRC_SMPTE2084 ||
                  p->color_trc == AVCOL_TRC_ARIB_STD_B67);

    // --- Container-level side data: HDR10 mastering info + Dolby Vision config ---
    int have_mdm = 0, have_cll = 0;
    const AVDOVIDecoderConfigurationRecord *dovi = NULL;

    for (int i = 0; i < p->nb_coded_side_data; i++) {
        const AVPacketSideData *sd = &p->coded_side_data[i];
        switch (sd->type) {
            case AV_PKT_DATA_MASTERING_DISPLAY_METADATA: {
                const AVMasteringDisplayMetadata *m =
                    (const AVMasteringDisplayMetadata *)sd->data;
                have_mdm = 1;
                if (m->has_luminance) {
                    printf("    mastering lum  : min %.4f cd/m^2, max %.1f cd/m^2\n",
                           av_q2d(m->min_luminance), av_q2d(m->max_luminance));
                }
                break;
            }
            case AV_PKT_DATA_CONTENT_LIGHT_LEVEL: {
                const AVContentLightMetadata *c =
                    (const AVContentLightMetadata *)sd->data;
                have_cll = 1;
                printf("    content light  : MaxCLL %d, MaxFALL %d\n",
                       c->MaxCLL, c->MaxFALL);
                break;
            }
            case AV_PKT_DATA_DOVI_CONF:
                dovi = (const AVDOVIDecoderConfigurationRecord *)sd->data;
                break;
            default: break;
        }
    }

    printf("    --> HDR type   : %s%s%s\n",
           hdr,
           (have_mdm && is_hdr) ? " + mastering metadata" : "",
           have_cll ? " + MaxCLL/FALL" : "");

    if (dovi) {
        printf("    --> DOLBY VISION:\n");
        printf("          profile          : %d\n", dovi->dv_profile);
        printf("          level            : %d\n", dovi->dv_level);
        printf("          version          : %d.%d\n",
               dovi->dv_version_major, dovi->dv_version_minor);
        printf("          RPU present      : %s\n", dovi->rpu_present_flag ? "yes" : "no");
        printf("          enhancement layer: %s\n", dovi->el_present_flag ? "yes (dual-layer)" : "no");
        printf("          base layer       : %s\n", dovi->bl_present_flag ? "yes" : "no");
        printf("          BL compat id     : %d  (0=none,1=HDR10,2=SDR,4=HLG)\n",
               dovi->dv_bl_signal_compatibility_id);
    }
}

static void inspect_audio(const AVStream *st) {
    const AVCodecParameters *p = st->codecpar;
    char layout[128] = {0};
    av_channel_layout_describe(&p->ch_layout, layout, sizeof(layout));

    printf("    channels       : %d  (%s)\n", p->ch_layout.nb_channels, layout[0] ? layout : "?");
    printf("    sample rate    : %d Hz\n", p->sample_rate);
    const char *sf = av_get_sample_fmt_name((enum AVSampleFormat)p->format);
    if (sf) printf("    sample format  : %s\n", sf);
    if (p->bits_per_raw_sample) printf("    bit depth      : %d\n", p->bits_per_raw_sample);
    if (p->bit_rate) printf("    bit rate       : %" PRId64 " kbps\n", p->bit_rate / 1000);
    printf("    codec tag      : '"); print_fourcc(p->codec_tag); printf("'\n");
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <media-file>\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];

    AVFormatContext *fmt = NULL;
    int err = avformat_open_input(&fmt, path, NULL, NULL);
    if (err < 0) {
        char e[256]; av_strerror(err, e, sizeof(e));
        fprintf(stderr, "error: could not open '%s': %s\n", path, e);
        return 1;
    }
    if ((err = avformat_find_stream_info(fmt, NULL)) < 0) {
        char e[256]; av_strerror(err, e, sizeof(e));
        fprintf(stderr, "error: could not read stream info: %s\n", e);
        avformat_close_input(&fmt);
        return 1;
    }

    printf("========================================================\n");
    printf("FILE      : %s\n", path);
    printf("CONTAINER : %s  (%s)\n", s(fmt->iformat->name), s(fmt->iformat->long_name));
    if (fmt->duration > 0)
        printf("DURATION  : %.1f s\n", (double)fmt->duration / AV_TIME_BASE);
    if (fmt->bit_rate > 0)
        printf("BIT RATE  : %" PRId64 " kbps (overall)\n", fmt->bit_rate / 1000);
    printf("STREAMS   : %u\n", fmt->nb_streams);
    printf("========================================================\n");

    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        const AVStream *st = fmt->streams[i];
        const AVCodecParameters *p = st->codecpar;
        const char *type = av_get_media_type_string(p->codec_type);
        const char *codec = avcodec_get_name(p->codec_id);

        // language tag, if present
        AVDictionaryEntry *lang = av_dict_get(st->metadata, "language", NULL, 0);

        printf("\n[stream %u] %s : %s%s%s\n",
               i, s(type), s(codec),
               lang ? "  lang=" : "", lang ? lang->value : "");

        if (p->codec_type == AVMEDIA_TYPE_VIDEO)      inspect_video(st);
        else if (p->codec_type == AVMEDIA_TYPE_AUDIO) inspect_audio(st);
        else if (p->codec_type == AVMEDIA_TYPE_SUBTITLE) {
            printf("    codec tag      : '"); print_fourcc(p->codec_tag); printf("'\n");
        }
    }

    printf("\n");
    avformat_close_input(&fmt);
    return 0;
}
