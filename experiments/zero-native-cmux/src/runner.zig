const std = @import("std");
const build_options = @import("build_options");
const zero_native = @import("zero-native");

pub const RunOptions = struct {
    app_name: []const u8,
    window_title: []const u8,
    bundle_id: []const u8,
    icon_path: []const u8 = "",
    bridge: ?zero_native.BridgeDispatcher = null,
    builtin_bridge: zero_native.BridgePolicy = .{},
    security: zero_native.SecurityPolicy = .{},

    fn appInfo(self: RunOptions) zero_native.AppInfo {
        return .{
            .app_name = self.app_name,
            .window_title = self.window_title,
            .bundle_id = self.bundle_id,
            .icon_path = self.icon_path,
            .main_window = .{
                .label = "main",
                .title = self.window_title,
                .default_frame = zero_native.geometry.RectF.init(0, 0, 1240, 780),
                .restore_state = true,
            },
        };
    }
};

pub fn runWithOptions(app: zero_native.App, options: RunOptions, init: std.process.Init) !void {
    if (comptime std.mem.eql(u8, build_options.platform, "macos")) {
        try runMacos(app, options, init);
    } else {
        try runNull(app, options, init);
    }
}

fn runNull(app: zero_native.App, options: RunOptions, init: std.process.Init) !void {
    const app_info = options.appInfo();
    var null_platform = zero_native.NullPlatform.initWithOptions(.{}, webEngine(), app_info);
    var trace_sink = StdoutTraceSink{};
    var runtime = zero_native.Runtime.init(.{
        .platform = null_platform.platform(),
        .trace_sink = trace_sink.sink(),
        .bridge = options.bridge,
        .builtin_bridge = options.builtin_bridge,
        .security = options.security,
    });
    _ = init;
    try runtime.run(app);
}

fn runMacos(app: zero_native.App, options: RunOptions, init: std.process.Init) !void {
    const app_info = options.appInfo();
    var mac_platform = try zero_native.platform.macos.MacPlatform.initWithOptions(
        zero_native.geometry.SizeF.init(1240, 780),
        webEngine(),
        app_info,
    );
    defer mac_platform.deinit();

    var log_buffers: zero_native.debug.LogPathBuffers = .{};
    const log_setup = zero_native.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    if (log_setup) |setup| zero_native.debug.installPanicCapture(init.io, setup.paths);

    var file_trace_sink: zero_native.debug.FileTraceSink = undefined;
    var runtime_trace_sink: ?zero_native.trace.Sink = null;
    if (log_setup) |setup| {
        file_trace_sink = zero_native.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
        runtime_trace_sink = file_trace_sink.sink();
    }

    var runtime = zero_native.Runtime.init(.{
        .platform = mac_platform.platform(),
        .trace_sink = runtime_trace_sink,
        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
        .bridge = options.bridge,
        .builtin_bridge = options.builtin_bridge,
        .security = options.security,
    });

    try runtime.run(app);
}

fn webEngine() zero_native.WebEngine {
    if (comptime std.mem.eql(u8, build_options.web_engine, "chromium")) return .chromium;
    return .system;
}

pub const StdoutTraceSink = struct {
    pub fn sink(self: *StdoutTraceSink) zero_native.trace.Sink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, record: zero_native.trace.Record) zero_native.trace.WriteError!void {
        _ = context;
        if (!std.mem.startsWith(u8, record.name, "runtime.") and !std.mem.startsWith(u8, record.name, "bridge.")) return;
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        zero_native.trace.formatText(record, &writer) catch return error.OutOfSpace;
        std.debug.print("{s}\n", .{writer.buffered()});
    }
};
