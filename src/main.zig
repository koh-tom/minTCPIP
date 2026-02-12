const std = @import("std");
const minTCPIP = @import("minTCPIP");

const util = minTCPIP.util;
const sync = minTCPIP.sync;
const platform = minTCPIP.platform;
const intr = platform.intr;
const timer = platform.timer;
const sched = platform.sched;

// タイマーによって呼び出された回数を記録する変数
var timer_count: u32 = 0;

/// 1秒ごとに発火するように登録されるコールバック関数(タイマーハンドラ)
fn timerCallback() void {
    timer_count += 1;
    util.infof(@src(), "timer fired! count={d}", .{timer_count});
}

/// ソフトウェア割り込み (将来のnet.cでのプロトコル処理用) が発生した際のハンドラ
fn softIrqHandler(irq: u32, _: ?*anyopaque) void {
    util.debugf(@src(), "softirq handler called, irq={d}", .{irq});
}

pub fn main() !void {
    util.infof(@src(), "=== minTCPIP infrastructure demo ===", .{});

    // --- 1. プラットフォームの初期設定 ---
    platform.init();

    // --- 2. 割り込み管理機構の初期設定 ---
    const alloc = platform.allocator();
    intr.init(alloc);

    // --- 3. タイマー機構の初期設定 ---
    try timer.init(alloc);

    // --- 4. スケジューラの初期設定 ---
    try sched.init();

    // --- 検証用: 割り込みハンドラを実際に登録してみる ---
    try intr.register(intr.IRQ_SOFT, softIrqHandler, 0, null);

    // --- 検証用: 1秒周期(1sec, 0usec)で動作するコールバックを仕掛ける ---
    try timer.register(1, 0, timerCallback);

    // ===================================
    // ユーティリティ群の動作確認 (Demo)
    // ===================================

    util.infof(@src(), "-- Hexdump demo --", .{});
    // テスト用のIPパケットダミーデータを16進数整形して出力
    util.hexdump(&minTCPIP.test_config.test_data);

    util.infof(@src(), "-- Byte order demo --", .{});
    // リトル/ビッグエンディアン間の値の相互変換テスト
    const val: u16 = 0x1234;
    util.infof(@src(), "host 0x{x:0>4} -> network 0x{x:0>4} -> host 0x{x:0>4}", .{
        val,
        util.hton16(val), // ホスト→ネットワーク
        util.ntoh16(util.hton16(val)), // ネットワーク→ホスト (元に戻るはず)
    });

    util.infof(@src(), "-- Checksum demo --", .{});
    // TCP/IPチェックサムの計算テスト (IPヘッダ部は先頭20バイト)
    const ip_hdr = minTCPIP.test_config.test_data[0..20];
    const cksum = util.cksum16(ip_hdr, 0);
    // 元データのIPヘッダ自体が正しいチェックサムを含んでいるため、全体を再計算すると必ず 0x0000 になる
    util.infof(@src(), "IP header checksum verification: 0x{x:0>4} (0x0000 = valid)", .{cksum});

    util.infof(@src(), "-- Random demo --", .{});
    // 16ビット乱数生成テスト
    util.infof(@src(), "random16() = {d}", .{platform.random16()});
    util.infof(@src(), "random16() = {d}", .{platform.random16()});

    // ===================================
    // サブスレッドのデーモン起動と待機
    // ===================================

    // 常駐スレッドの開始 (割り込み待ち受け ＆ 1msタイマーの時流し)
    try intr.run();
    try timer.run();
    sched.run();

    util.infof(@src(), "=== All subsystems running. Waiting 3 seconds for timer events... ===", .{});

    // メインスレッド側はここで3秒間(3 * 1,000,000,000 ナノ秒)スリープ。
    // その間、裏でタイマースレッドが割り込みを発生させ `timerCallback` が3回実行されるはず。
    sync.sleepNs(3 * std.time.ns_per_s);

    // ===================================
    // シャットダウン処理
    // ===================================
    util.infof(@src(), "=== Shutting down... ===", .{});

    // 起動時の逆順にシャットダウンを行う
    sched.shutdown();
    timer.shutdown();
    intr.shutdown();
    platform.shutdown();

    // 期待通りタイマーコールバックが正確に動作した回数を確認
    util.infof(@src(), "=== Done. Timer fired {d} time(s). ===", .{timer_count});
}
