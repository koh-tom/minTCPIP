// 割り込み管理サブシステム (microps の platform/linux/intr.c / intr.h に相当)
//
// C言語版(microps)では POSIX Signal (SIGUSR1, SIGALRM等) と sigwait を使って割り込みスレッドを実現していましたが、
// シグナルは並行処理空間において扱いが難しく不確定要素になるため、
// 本Zigポーティングでは `sync.zig` で定義した「futexベースの条件変数とミューテックス」を利用し、
// モダンで安全な「イベントディスパッチモデル」に置き換えて実装しています。

const std = @import("std");
const util = @import("util.zig");
const sync = @import("sync.zig");

// ============================================================
// 割り込み番号 (IRQ) 定数
// ============================================================
// ハードウェア割り込みをソフトウェアでシミュレーションするための番号定義です。
// C版のシグナル番号(SIGUSR1等)にマッピングされていた論理的な割り込み番号となります。

pub const IRQ_SOFT: u32 = 0;  // ソフトウェア割り込み用 (プロトコルのディスパッチ処理などで利用)
pub const IRQ_USER: u32 = 1;  // ユーザー割り込み用 (スケジューラの緊急終了時などに利用)
pub const IRQ_TIMER: u32 = 2; // タイマー割り込み用 (1ms間隔で発火する定期タイマー)
pub const IRQ_BASE: u32 = 3;  // デバイス用割り込みのベース番号(ここから先がNICなどのハード割り込みとして利用される)

/// 1つの割り込み番号を複数のハンドラで共有するためのフラグ
pub const IRQ_SHARED: u32 = 0x0001;

/// システム全体でサポートする最大割り込み種別数
const MAX_IRQ: usize = 16;

// ============================================================
// 割り込みサービスルーチン (ISR) と 状態管理
// ============================================================

/// ユーザーが登録する割り込みハンドラの関数ポインタ型
pub const IsrFn = *const fn (irq: u32, arg: ?*anyopaque) void;

/// 登録された割り込みハンドラを管理する単方向リストノード
const IrqEntry = struct {
    next: ?*IrqEntry = null,
    irq: u32,             // 監視対象の割り込み番号
    isr: IsrFn,           // 実行するハンドラ関数
    flags: u32,           // 共有フラグ (IRQ_SHARED等)
    arg: ?*anyopaque,     // ハンドラ実行時に渡されるユーザー引数
};

// ============================================================
// グローバルモジュール状態 (Cのスタティック変数相当)
// ============================================================

/// 登録済み割り込みハンドラのリスト (run() 実行前に全て登録される前提なのでロック不要)
var irqs: ?*IrqEntry = null;

/// 各IRQの未処理(ペンディング)カウント。raise()で増え、ディスパッチャが消費する。
var pending: [MAX_IRQ]u32 = [_]u32{0} ** MAX_IRQ;

/// ペンディング配列(`pending`)と終了フラグ(`terminate`)を保護するミューテックス
var mutex: sync.Mutex = .{};

/// 割り込みスレッドを待機・起床させるための条件変数
var cond: sync.Condition = .{};

/// サブシステム終了を指示するフラグ
var terminate: bool = false;

/// 割り込みディスパッチャとして常駐する専用スレッド
var thread: ?std.Thread = null;

/// スレッド起動完了同期用のバリア (pthread_barrier_t相当)
var ready: bool = false;
var ready_mutex: sync.Mutex = .{};
var ready_cond: sync.Condition = .{};

/// IrqEntryの動的確保に使うアロケータ
var alloc: std.mem.Allocator = undefined;

// ============================================================
// パブリック API
// ============================================================

/// 割り込みハンドラ(ISR)を登録します。
/// ネットワークスタック起動(`run()`)の前に呼び出されるべきです。
pub fn register(irq: u32, isr: IsrFn, flags: u32, arg: ?*anyopaque) !void {
    // 既存の登録ハンドラと競合しないかチェックする
    var entry = irqs;
    while (entry) |e| {
        if (e.irq == irq) {
            // IRQ_SHARED フラグが設定されていないのに同じ番号を登録しようとした場合はエラー
            if ((e.flags ^ IRQ_SHARED) != 0 or (flags ^ IRQ_SHARED) != 0) {
                util.errorf(@src(), "conflicts with already registered IRQs, irq={d}", .{irq});
                return error.IrqConflict;
            }
        }
        entry = e.next;
    }

    const new_entry = alloc.create(IrqEntry) catch {
        util.errorf(@src(), "allocator.create() failure", .{});
        return error.OutOfMemory;
    };
    new_entry.* = .{
        .irq = irq,
        .isr = isr,
        .flags = flags,
        .arg = arg,
        .next = irqs, // リストの先頭に追加
    };
    irqs = new_entry;
    util.infof(@src(), "success, irq={d}", .{irq});
}

/// 割り込みを発生(Raise)させます。
/// どのスレッドから呼ばれても安全です。（C版の pthread_kill に相当）
pub fn raise(irq: u32) void {
    if (irq >= MAX_IRQ) return;

    mutex.lock();
    pending[irq] += 1; // 未処理割り込みカウンタをインクリメント
    mutex.unlock();

    // 眠っている割り込みスレッドにシグナルを送って起こす
    cond.signal();
}

/// 割り込みサブシステムを初期化します。
pub fn init(allocator: std.mem.Allocator) void {
    alloc = allocator;
    terminate = false;
    ready = false;
    for (&pending) |*p| p.* = 0;
}

/// 割り込み処理スレッドを起動します。
/// スレッドが内部初期化を完了しスタンバイ状態になるまでブロックします。
pub fn run() !void {
    thread = try std.Thread.spawn(.{}, intrMain, .{});

    // スレッドが準備完了になるまで待機
    ready_mutex.lock();
    while (!ready) {
        ready_cond.wait(&ready_mutex);
    }
    ready_mutex.unlock();
}

/// 割り込み処理スレッドを安全に停止し、割り当てたリソースを解放します。
pub fn shutdown() void {
    const t = thread orelse return;

    // 終了フラグを立ててスレッドを起こす
    mutex.lock();
    terminate = true;
    mutex.unlock();
    cond.signal();

    // スレッドの完全な終了を待つ
    t.join();
    thread = null;

    // 動的確保したハンドラエントリのメモリを解放
    while (irqs) |entry| {
        irqs = entry.next;
        alloc.destroy(entry);
    }

    util.infof(@src(), "shutdown complete", .{});
}

// ============================================================
// 割り込み処理スレッド (ディスパッチャ本体)
// ============================================================

/// 割り込み処理専用の常駐スレッド。
/// C版の `intr_main()` (sigwaitループ) の完全な代替です。
fn intrMain() void {
    util.infof(@src(), "start...", .{});

    // 自身が準備完了になったことをメインプロセスへ通知
    ready_mutex.lock();
    ready = true;
    ready_mutex.unlock();
    ready_cond.signal();

    // デーモンループ
    while (true) {
        mutex.lock();

        // 処理すべき割り込みも終了指示もなければ、ロックを手放して寝る
        while (!hasPending() and !terminate) {
            cond.wait(&mutex);
        }

        if (terminate) {
            mutex.unlock();
            break; // 終了指示が来たのでループを抜ける
        }

        // ペンディングされているIRQを1つ選び、カウンタを減らして取り出す
        const irq = consumeOne();
        mutex.unlock();

        if (irq) |irq_num| {
            // タイマー割り込みは1ms毎に大量に発生するため、ログ出力から除外
            if (irq_num != IRQ_TIMER) {
                util.debugf(@src(), "IRQ <{d}> occurred", .{irq_num});
            }
            // ロックを外した状態で安全にハンドラを実行
            dispatchIrq(irq_num);
        }
    }

    util.infof(@src(), "terminated", .{});
}

/// いずれかのIRQが未処理として残っているか確認（ミューテックス保持状態で呼び出す）
fn hasPending() bool {
    for (pending) |p| {
        if (p > 0) return true;
    }
    return false;
}

/// ランダム(または若い順)に未処理IRQを1つ消費して、そのIRQ番号を返す（ミューテックス保持状態）
fn consumeOne() ?u32 {
    for (&pending, 0..) |*p, i| {
        if (p.* > 0) {
            p.* -= 1;
            return @intCast(i);
        }
    }
    return null;
}

/// 対象のIRQ番号を監視するすべてのハンドラ関数を呼び出す
fn dispatchIrq(irq: u32) void {
    var entry = irqs;
    while (entry) |e| {
        if (e.irq == irq) {
            e.isr(e.irq, e.arg); // 実際の割り込み処理関数の実行
            // 共有フラグが立っていなければ、最初に見つかった処理だけを実行してループを抜ける
            if (e.flags & IRQ_SHARED == 0) {
                break;
            }
        }
        entry = e.next;
    }
}
