// This target intentionally has no public API. It carries FFmpeg's required
// Apple framework/system-library links and package privacy manifest so clients
// only need to depend on the `FFmpeg` product and import the `FFmpeg` module.
enum FFmpegLinkerSupport {}
