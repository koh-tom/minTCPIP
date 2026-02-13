//minTCPIP — テストプログラム

const std = @import("std");
const minTCPIP = @import("minTCPIP");

const util = minTCPIP.util;
const net = minTCPIP.net;

/// 終了フラグ
var terminate: bool = false;

/// シグナルハンドラ (SIGINT)
fn on_signal(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    terminate = true;
}

/// プロトコルスタックのセットアップ
fn setup() i32 {
    var sa = std.posix.Sigaction{
        .handler = .{ .handler = on_signal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);

    util.infof(@src(), "セットアップ開始", .{});

    net.init() catch |err| {
        util.errorf(@src(), "セットアップ失敗: {}", .{err});
        return -1;
    };
    net.run() catch |err| {
        util.errorf(@src(), "サービス開始失敗: {}", .{err});
        return -1;
    };
    return 0;
}

/// プロトコルスタックの後片付け
fn cleanup() i32 {
    util.infof(@src(), "クリーンアップ開始", .{});
    net.shutdown();
    util.infof(@src(), "クリーンアップ完了", .{});
    return 0;
}

/// アプリケーションのメインロジック
fn app_main() i32 {
    util.debugf(@src(), "Ctrl+Cで終了", .{});
    while (!terminate) {
        minTCPIP.sync.sleepNs(1000 * std.time.ns_per_ms);
    }
    util.debugf(@src(), "アプリケーションメイン完了", .{});
    return 0;
}

pub fn main() !void {
    var ret: i32 = 0;

    if (setup() == -1) {
        util.errorf(@src(), "setup() 失敗", .{});
        std.process.exit(1);
    }

    ret = app_main();

    if (cleanup() == -1) {
        util.errorf(@src(), "cleanup() 失敗", .{});
        std.process.exit(1);
    }

    if (ret != 0) {
        std.process.exit(@intCast(ret));
    }
}
