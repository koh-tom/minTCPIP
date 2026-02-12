// タイマーサブシステム

const std = @import("std");
const util = @import("util.zig");
const intr = @import("intr.zig");
const sync = @import("sync.zig");

// ============================================================
// タイマーエントリと関数ポインタ
// ============================================================

/// 定期実行されるコールバック関数の型
pub const HandlerFn = *const fn () void;

/// 登録されたタイマー情報を保持するリンクリストノード
const TimerEntry = struct {
    next: ?*TimerEntry = null,
    interval_ns: u64, // 発火インターバル（ナノ秒単位）
    last: i128, // 最後に発火した時刻（ナノ秒単位のモノトニック時刻）
    handler: HandlerFn, // 発火時に実行されるコールバック関数
};

// ============================================================
// グローバルモジュール状態
// ============================================================

/// 登録済みの定期実行タイマーリスト（実行開始前に登録されるためロック機構は省いています）
var timers: ?*TimerEntry = null;

/// 1msのティックを刻み続ける専用スレッド
var tick_thread: ?std.Thread = null;

/// スレッド終了フラグ
var stop_flag: bool = false;
var stop_mutex: sync.Mutex = .{};

/// TimerEntry ノードを動的確保するためのアロケータ
var alloc: std.mem.Allocator = undefined;

// ============================================================
// パブリック API
// ============================================================

/// インターバルタイマーを登録します。
/// 引数 `interval_sec` および `interval_usec` は C言語の `struct timeval` に由来する秒・マイクロ秒のペアです。
pub fn register(interval_sec: i64, interval_usec: i64, handler: HandlerFn) !void {
    const timer_entry = alloc.create(TimerEntry) catch {
        util.errorf(@src(), "allocator.create() failure", .{});
        return error.OutOfMemory;
    };

    // 秒とマイクロ秒をまとめて「ナノ秒」に変換して保持する
    const interval_ns: u64 = @intCast(
        interval_sec * 1_000_000_000 + interval_usec * 1_000,
    );
    timer_entry.* = .{
        .interval_ns = interval_ns,
        .last = sync.nowMono(),
        .handler = handler,
        .next = timers, // リストの先頭に追加
    };
    timers = timer_entry;
    util.infof(@src(), "success, interval={{sec={d}, usec={d}}}", .{ interval_sec, interval_usec });
}

/// タイマーサブシステムを初期化します。
/// 同装となる割り込み(intr.zig)層に `IRQ_TIMER` に反応するハンドラを登録します。
pub fn init(allocator: std.mem.Allocator) !void {
    alloc = allocator;
    stop_flag = false;

    // 定期ティックで発火するハンドラを設定する
    try intr.register(intr.IRQ_TIMER, timerIrqHandler, 0, null);
}

/// タイマースレッドをバックグラウンドに起動し、時間を進め始めます。
pub fn run() !void {
    tick_thread = try std.Thread.spawn(.{}, tickMain, .{});
    util.infof(@src(), "timer tick started (1ms)", .{});
}

/// タイマー処理を安全に停止し、メモリを解放します。
pub fn shutdown() void {
    stop_mutex.lock();
    stop_flag = true;
    stop_mutex.unlock();

    if (tick_thread) |t| {
        t.join();
        tick_thread = null;
    }

    while (timers) |entry| {
        timers = entry.next;
        alloc.destroy(entry);
    }
}

// ============================================================
// 内部動作 (Tick供給と時間差分チェック)
// ============================================================

/// ハードウェアクロックの代替となる、1ms間隔でティックを刻むスリープループ(専用スレッド)
fn tickMain() void {
    while (true) {
        stop_mutex.lock();
        const should_stop = stop_flag;
        stop_mutex.unlock();
        if (should_stop) break;

        // 1ミリ秒スリープ
        sync.sleepNs(1_000_000);

        // 1ms経過したことを割り込み管理層に通知(Raise)する
        intr.raise(intr.IRQ_TIMER);
    }
}

/// IRQ_TIMER（1msティック）が発生したときに、割り込み管理スレッド内から呼び出されるハンドラ。
/// 全ての登録されたタイマーエントリを確認し、設定されたインターバルを経過したものを実行します。
fn timerIrqHandler(_: u32, _: ?*anyopaque) void {
    const now = sync.nowMono(); // この時点での正確な現在時刻を取得
    var timer_entry = timers;

    while (timer_entry) |t| {
        // 前回発火した時刻からの経過時間を計算
        const diff = now - t.last;

        // 要求インターバルを満たしているかチェック
        if (diff >= @as(i128, t.interval_ns)) {
            t.handler(); // ユーザーが登録したコールバックを実行
            t.last = now; // 最後に発火した時刻を更新
        }
        timer_entry = t.next;
    }
}
