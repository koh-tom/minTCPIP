// 同期および時間取得のユーティリティ

const std = @import("std");
const linux = std.os.linux;
const atomic = std.atomic;

// FUTEX_WAIT: 指定アドレスの値が期待値と同じならスレッドをブロック(スリープ)させる
const FUTEX_WAIT = linux.FUTEX_OP{ .cmd = .WAIT, .private = true };
// FUTEX_WAKE: 指定アドレスでブロックされているスレッドを起床させる
const FUTEX_WAKE = linux.FUTEX_OP{ .cmd = .WAKE, .private = true };

/// futex_wait システムコールのラッパー。
/// `ptr` の指す値が `expected` と一致する限り、スレッドをブロックします。
fn futexWait(ptr: *const u32, expected: u32) void {
    _ = linux.futex_4arg(@ptrCast(ptr), FUTEX_WAIT, expected, null);
}

/// futex_wake システムコールのラッパー。
/// `ptr` に紐づいて待機しているスレッドを `count` 個だけ起床させます。
fn futexWake(ptr: *const u32, count: u32) void {
    _ = linux.futex_3arg(@ptrCast(ptr), FUTEX_WAKE, count);
}

// ============================================================
// Mutex (futexベースの実装)
// ============================================================

/// スレッドセーフな排他ロックを提供するMutex構造体
pub const Mutex = struct {
    /// 状態管理フラグ:
    /// 0 = アンロック状態
    /// 1 = ロック状態（競合なし・待機スレッドなし）
    /// 2 = ロック状態（競合あり・待機スレッドあり）
    state: atomic.Value(u32) = atomic.Value(u32).init(0),

    /// ロックを獲得します（ブロックあり）
    pub fn lock(self: *Mutex) void {
        // ファストパス: アンロック状態(0)であれば、競合なしのロック状態(1)に遷移させる
        if (self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
            // 他のスレッドが既にロックを持っている場合はスローパス（待機処理）へ
            self.lockSlow();
        }
    }

    /// スローパス: ロックが取得できるまで待機します
    fn lockSlow(self: *Mutex) void {
        // 状態を「競合あり(2)」に設定する
        var s = self.state.swap(2, .acquire);
        while (s != 0) {
            // ロックが解放(0)されるまでfutexでスリープする
            futexWait(&self.state.raw, 2);
            // スリープから復帰したら再度ロック取得を試みる
            s = self.state.swap(2, .acquire);
        }
    }

    /// ロックを解放します
    pub fn unlock(self: *Mutex) void {
        // 競合なし(1)であれば、0に戻すだけで終了
        if (self.state.fetchSub(1, .release) != 1) {
            // 競合あり(2)だった場合は、アンロック状態(0)にして待機スレッドを1つ起こす
            self.state.store(0, .release);
            futexWake(&self.state.raw, 1);
        }
    }
};

// ============================================================
// 条件変数 Condition Variable (futexベースの実装)
// ============================================================

/// ある特定の条件が満たされるまでスレッドを待機させるためのCondition Variable
pub const Condition = struct {
    /// 待機世代カウンタ（シグナルが送られるたびに増加する）
    seq: atomic.Value(u32) = atomic.Value(u32).init(0),

    /// Mutexのロックを解除し、シグナルを待機し、再びMutexをロックして復帰します
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        const seq = self.seq.load(.acquire); // 現在の世代を記憶
        mutex.unlock(); // 一旦ロックを手放す
        futexWait(&self.seq.raw, seq); // 世代が推移（シグナル受信）するまで待機
        mutex.lock(); // 起床後にロックを取り直す
    }

    /// 待機中のスレッドを1つだけ起床させます
    pub fn signal(self: *Condition) void {
        _ = self.seq.fetchAdd(1, .release); // 世代を進める
        futexWake(&self.seq.raw, 1); // 1スレッド起床
    }

    /// 待機中の全てのスレッドを起床させます
    pub fn broadcast(self: *Condition) void {
        _ = self.seq.fetchAdd(1, .release); // 世代を進める
        futexWake(&self.seq.raw, std.math.maxInt(u32)); // 全スレッド起床
    }
};

// ============================================================
// 時間取得ヘルパー (Zig 0.16対応)
// ============================================================

/// 現在の時刻をUNIXエポックからのナノ秒として取得します (CLOCK_REALTIME)
pub fn nowNano() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

/// 現在の時刻をUNIXエポックからのミリ秒として取得します
pub fn nowMillis() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// 経過時間計測用の単調増加時刻（モノトニッククロック）のナノ秒を取得します
pub fn nowMono() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

/// 指定したナノ秒だけ、現在のスレッドをスリープさせます
pub fn sleepNs(ns: u64) void {
    var req = linux.timespec{
        .sec = @intCast(ns / 1_000_000_000),
        .nsec = @intCast(ns % 1_000_000_000),
    };
    var rem: linux.timespec = undefined;
    // sleepがシグナル等で中断された場合は、残りの時間を再度待機する
    while (linux.nanosleep(&req, &rem) != 0) {
        req = rem;
    }
}

/// UNIXエポック（1970/1/1 00:00:00）からの経過秒数を取得します
pub fn timestamp() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}
