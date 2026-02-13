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

    util.infof(@src(), "setup protocol stack...", .{});

    if (net.init()) |_| {} else |_| {
        util.errorf(@src(), "net_init() failure", .{});
        return -1;
    }
    if (net.run()) |_| {} else |_| {
        util.errorf(@src(), "net_run() failure", .{});
        return -1;
    }
    return 0;
}

/// プロトコルスタックの後片付け
fn cleanup() i32 {
    util.infof(@src(), "cleanup protocol stack...", .{});
    net.shutdown();
    return 0;
}

/// アプリケーションのメインロジック
fn app_main() i32 {
    return 0;
}

pub fn main() !void {
    var ret: i32 = 0;

    if (setup() == -1) {
        util.errorf(@src(), "setup() failure", .{});
        std.process.exit(1);
    }

    ret = app_main();

    if (cleanup() == -1) {
        util.errorf(@src(), "cleanup() failure", .{});
        std.process.exit(1);
    }

    if (ret != 0) {
        std.process.exit(@intCast(ret));
    }
}
