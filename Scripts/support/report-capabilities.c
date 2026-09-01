#include <FFmpeg.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct NameList {
    const char **values;
    size_t count;
    size_t capacity;
} NameList;

static void fail_allocation(void) {
    fputs("Capability reporter ran out of memory\n", stderr);
    exit(EXIT_FAILURE);
}

static void append_name(NameList *list, const char *name) {
    if (name == NULL) {
        fputs("FFmpeg returned an unnamed capability\n", stderr);
        exit(EXIT_FAILURE);
    }
    if (list->count == list->capacity) {
        size_t next_capacity = list->capacity == 0 ? 64 : list->capacity * 2;
        const char **next_values =
            realloc(list->values, next_capacity * sizeof(*next_values));
        if (next_values == NULL) {
            fail_allocation();
        }
        list->values = next_values;
        list->capacity = next_capacity;
    }
    list->values[list->count++] = name;
}

static int compare_names(const void *lhs, const void *rhs) {
    const char *const *left = lhs;
    const char *const *right = rhs;
    return strcmp(*left, *right);
}

static void print_json_string(const char *value) {
    const unsigned char *cursor = (const unsigned char *)value;
    putchar('"');
    while (*cursor != '\0') {
        switch (*cursor) {
        case '"':
            fputs("\\\"", stdout);
            break;
        case '\\':
            fputs("\\\\", stdout);
            break;
        case '\b':
            fputs("\\b", stdout);
            break;
        case '\f':
            fputs("\\f", stdout);
            break;
        case '\n':
            fputs("\\n", stdout);
            break;
        case '\r':
            fputs("\\r", stdout);
            break;
        case '\t':
            fputs("\\t", stdout);
            break;
        default:
            if (*cursor < 0x20) {
                printf("\\u%04x", (unsigned int)*cursor);
            } else {
                putchar(*cursor);
            }
        }
        cursor++;
    }
    putchar('"');
}

static void print_name_list(const char *key, NameList *list, int trailing_comma) {
    qsort(list->values, list->count, sizeof(*list->values), compare_names);
    printf("  \"");
    fputs(key, stdout);
    printf("\": [");
    for (size_t index = 0; index < list->count; index++) {
        if (index != 0) {
            putchar(',');
        }
        print_json_string(list->values[index]);
    }
    printf("]%s\n", trailing_comma ? "," : "");
}

int main(void) {
    NameList decoders = {0};
    NameList demuxers = {0};
    NameList muxers = {0};
    NameList input_protocols = {0};
    NameList hardware_device_types = {0};
    void *opaque = NULL;
    const AVCodec *codec;
    const AVInputFormat *demuxer;
    const AVOutputFormat *muxer;
    const char *protocol;
    enum AVHWDeviceType hardware_type = AV_HWDEVICE_TYPE_NONE;

    while ((codec = av_codec_iterate(&opaque)) != NULL) {
        if (av_codec_is_decoder(codec)) {
            append_name(&decoders, codec->name);
        }
    }

    opaque = NULL;
    while ((demuxer = av_demuxer_iterate(&opaque)) != NULL) {
        append_name(&demuxers, demuxer->name);
    }

    opaque = NULL;
    while ((muxer = av_muxer_iterate(&opaque)) != NULL) {
        append_name(&muxers, muxer->name);
    }

    opaque = NULL;
    while ((protocol = avio_enum_protocols(&opaque, 0)) != NULL) {
        append_name(&input_protocols, protocol);
    }

    while ((hardware_type = av_hwdevice_iterate_types(hardware_type)) !=
           AV_HWDEVICE_TYPE_NONE) {
        append_name(&hardware_device_types,
                    av_hwdevice_get_type_name(hardware_type));
    }

    puts("{");
    puts("  \"schemaVersion\": 1,");
    print_name_list("decoders", &decoders, 1);
    print_name_list("demuxers", &demuxers, 1);
    print_name_list("muxers", &muxers, 1);
    print_name_list("inputProtocols", &input_protocols, 1);
    print_name_list("hardwareDeviceTypes", &hardware_device_types, 0);
    puts("}");

    free(decoders.values);
    free(demuxers.values);
    free(muxers.values);
    free(input_protocols.values);
    free(hardware_device_types.values);
    return EXIT_SUCCESS;
}
