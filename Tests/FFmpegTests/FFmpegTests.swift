import FFmpeg
import Foundation
@testable import FFmpegLinkerSupport
import Testing

@Test
func loadsEveryBundledFFmpegLibraryFamily() {
    #expect(!String(cString: av_version_info()).isEmpty)
    #expect(avcodec_version() > 0)
    #expect(avformat_version() > 0)
    #expect(avutil_version() > 0)
    #expect(swresample_version() > 0)
    #expect(swscale_version() > 0)
}

@Test
func exposesRequiredAudioAndVideoDecoders() {
    #expect(avcodec_find_decoder(AV_CODEC_ID_AAC) != nil)
    #expect(avcodec_find_decoder(AV_CODEC_ID_H264) != nil)
    #expect(avcodec_find_decoder(AV_CODEC_ID_AV1) != nil)
}

@Test
func exposesRequiredDemuxersAndProtocols() {
    #expect(av_find_input_format("mov") != nil)
    #expect(av_find_input_format("mp3") != nil)

    var opaque: UnsafeMutableRawPointer?
    var protocols = Set<String>()
    while let name = avio_enum_protocols(&opaque, 0) {
        protocols.insert(String(cString: name))
    }

    #expect(protocols.contains("file"))
    #expect(protocols.contains("http"))
    #expect(protocols.contains("https"))
}

@Test
func bundlesExpectedPrivacyManifest() throws {
    let url = try #require(Bundle.module.url(
        forResource: "PrivacyInfo",
        withExtension: "xcprivacy"
    ))
    let data = try Data(contentsOf: url)
    let document = try #require(
        PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any]
    )

    #expect(document["NSPrivacyTracking"] as? Bool == false)
    #expect((document["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
    #expect((document["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)

    let entries = try #require(
        document["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
    )
    #expect(entries.count == 1)
    let entry = try #require(entries.first)
    #expect(
        entry["NSPrivacyAccessedAPIType"] as? String ==
            "NSPrivacyAccessedAPICategoryFileTimestamp"
    )
    let reasons = try #require(
        entry["NSPrivacyAccessedAPITypeReasons"] as? [String]
    )
    #expect(Set(reasons) == ["3B52.1", "C617.1"])
}
