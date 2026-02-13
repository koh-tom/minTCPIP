//! ネットワーク層管理マネージャ (microps net.c / net.h 相当)
//! 
//! プロトコルスタック全体の初期化・実行・停止を管理します。

const std = @import("std");
const util = @import("util.zig");
const platform = @import("platform.zig");

/// ネットワーク層の初期化
pub fn init() !void {
    util.infof(@src(), "初期化開始", .{});
    
    // プラットフォームの初期設定 (platform.init は void を返すためエラーチェック不要)
    platform.init();
    
    util.infof(@src(), "初期化完了", .{});
}

/// ネットワーク層のサービス開始
pub fn run() !void {
    util.infof(@src(), "サービス開始", .{});
    
    platform.run();
    
    util.infof(@src(), "サービス完了", .{});
}

/// ネットワーク層の停止
pub fn shutdown() void {
    util.infof(@src(), "サービス停止", .{});
    
    platform.shutdown();
    
    util.infof(@src(), "サービス停止完了", .{});
}
