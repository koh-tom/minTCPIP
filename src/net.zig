// ネットワーク層管理マネージャ

const std = @import("std");
const util = @import("util.zig");
const platform = @import("platform.zig");

/// ネットワーク層の初期化
pub fn init() !void {
    util.infof(@src(), "初期化開始", .{});
    if (platform.init() == -1) |_| {
        util.errorf(@src(), "初期化失敗", .{});
        return error.InitFailure;
    }
    util.infof(@src(), "初期化完了", .{});
    return 0;
}

/// ネットワーク層のサービス開始
pub fn run() !void {
    util.infof(@src(), "サービス開始", .{});
    if (platform.run() == -1) |_| {
        util.errorf(@src(), "サービス開始失敗", .{});
        return error.RunFailure;
    }
    util.infof(@src(), "サービス完了", .{});
    return 0;
}

/// ネットワーク層を停止
pub fn shutdown() void {
    util.infof(@src(), "サービス停止", .{});
    if (platform.shutdown() == -1) |_| {
        util.errorf(@src(), "サービス停止失敗", .{});
        return error.ShutdownFailure;
    }
    util.infof(@src(), "サービス停止完了", .{});
    return 0;
}
