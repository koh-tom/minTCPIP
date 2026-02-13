// ネットワーク層管理マネージャ

const std = @import("std");
const util = @import("util.zig");
const platform = @import("platform.zig");

pub const IFNAMSIZ = 16;
pub const NET_DEVICE_ADDR_LEN = 16;

pub const NET_DEVICE_TYPE_DUMMY = 0x0000;
pub const NET_DEVICE_TYPE_LOOPBACK = 0x0001;
pub const NET_DEVICE_TYPE_ETHERNET = 0x0002;

pub const NET_DEVICE_FLAG_UP = 0x0001;
pub const NET_DEVICE_FLAG_LOOPBACK = 0x0010;
pub const NET_DEVICE_FLAG_BROADCAST = 0x0020;
pub const NET_DEVICE_FLAG_P2P = 0x0040;
pub const NET_DEVICE_FLAG_NEED_ARP = 0x0100;

/// ネットワークデバイス構造体
pub const NetDevice = struct {
    next: ?*NetDevice = null,
    index: u32 = 0,
    name: [IFNAMSIZ]u8 = [_]u8{0} ** IFNAMSIZ,
    type: u16 = 0,
    mtu: u16 = 0,
    flags: u16 = 0,
    hlen: u16 = 0, // ヘッダ長
    alen: u16 = 0, // アドレス長
    addr: [NET_DEVICE_ADDR_LEN]u8 = [_]u8{0} ** NET_DEVICE_ADDR_LEN,
    broadcast: [NET_DEVICE_ADDR_LEN]u8 = [_]u8{0} ** NET_DEVICE_ADDR_LEN,
};

/// 登録されているデバイスのリスト
var devices: ?*NetDevice = null;

/// デバイス構造体をメモリ上に確保
pub fn deviceAlloc() ?*NetDevice {
    const alloc = platform.allocator();
    const dev = alloc.create(NetDevice) catch return null;
    dev.* = .{};
    return dev;
}

/// デバイスをシステムに登録
pub fn deviceRegister(dev: *NetDevice) i32 {
    // リストの先頭に追加
    dev.next = devices;
    devices = dev;

    // インデックスの割り当て (簡易実装)
    var count: u32 = 0;
    var curr = devices;
    while (curr) |c| : (curr = c.next) {
        count += 1;
    }
    dev.index = count;

    util.infof(@src(), "registered device: {s} (index={d})", .{ std.mem.sliceTo(&dev.name, 0), dev.index });
    return 0;
}

/// デバイスからパケットを送信します
pub fn deviceOutput(dev: *NetDevice, proto_type: u16, data: []const u8, dst: []const u8) i32 {
    _ = dev;
    _ = proto_type;
    _ = data;
    _ = dst;
    return 0;
}

/// ネットワーク層の初期化
pub fn init() !void {
    util.infof(@src(), "初期化開始", .{});
    platform.init();
    util.infof(@src(), "初期化完了", .{});
}

/// ネットワーク層の動作開始
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
