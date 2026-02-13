// ネットワーク層管理マネージャ

const std = @import("std");
const util = @import("util.zig");
const platform = @import("platform.zig");

/// ネットワーク層の初期化
pub fn init() !void {
    util.infof(@src(), "initialized", .{});
}

/// ネットワーク層のサービス開始
pub fn run() !void {
    util.infof(@src(), "running...", .{});
}

/// ネットワーク層を停止
pub fn shutdown() void {
    util.infof(@src(), "shutdown complete", .{});
}
