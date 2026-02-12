// プラットフォーム抽象化層 (microps の platform/linux/platform.c / platform.h に相当)
//
// Linux(POSIX)の環境依存する機能(メモリ確保、乱数生成、システム時刻、スレッド基盤など)を
// minTCPIPというコアロジックから隠蔽し、一元管理するための窓口です。
// C言語版にあった platform.h 同様に、下位のインフラモジュール (intr, timer, sched) への
// インポートもここでまとめて公開 (re-export) しています。

const std = @import("std");
const util = @import("util.zig");

// 同期プリミティブおよび時間取得のヘルパー
pub const sync = @import("sync.zig");

// ============================================================
// 下位インフラの再公開 (re-export)
// ============================================================

pub const intr = @import("intr.zig");   // 割り込み
pub const timer = @import("timer.zig"); // タイマー
pub const sched = @import("sched.zig"); // タスクスケジューラ

// ============================================================
// メモリ管理 (Cの malloc / free に相当)
// ============================================================

/// グローバルなメモリアロケータ。
/// 安全性と速度のバランスが良い OSのページアロケータ をデフォルトの割り当て元としています。
/// 本格的な組み込み実装の場合は固定バッファアロケータ(FixedBufferAllocator)を使ったり、
/// メモリリーク追跡用の DebugAllocator を重ねたりしますが、今はシンプルに提供します。
const alloc = std.heap.page_allocator;

/// C版の `memory_alloc()` および `memory_free()` の代替関数。
/// Zigらしい作法に従い、メモリ割り当てを行うための標準 `Allocator` インターフェースを返却します。
pub fn allocator() std.mem.Allocator {
    return alloc;
}

// ============================================================
// 乱数生成機能 (Cの srandom / random16 に相当)
// ============================================================

var prng: std.Random.DefaultPrng = undefined; // 乱数の内部状態ジェネレータ
var prng_initialized: bool = false; // 初期化済みフラグ

/// TPC/IPの初期シーケンス番号や動的ポート決定用などに使われる16ビット乱数を取得します。
pub fn random16() u16 {
    if (!prng_initialized) {
        // 未初期化の場合は現在時刻を使ってシード値を生成して初期化
        const seed: u64 = @intCast(sync.timestamp());
        prng = std.Random.DefaultPrng.init(seed);
        prng_initialized = true;
    }
    return prng.random().int(u16);
}

// ============================================================
// ライフサイクル管理
// ============================================================

/// プラットフォーム抽象化層の初期設定を一括で行います。
pub fn init() void {
    // 乱数のシードを明示的に初期化しておく
    const seed: u64 = @intCast(sync.timestamp());
    prng = std.Random.DefaultPrng.init(seed);
    prng_initialized = true;
    util.infof(@src(), "platform initialized", .{});
}

/// プラットフォーム依存の開始処理（C版と互換性を保つため現状は空関数）
pub fn run() void {}

/// プラットフォームの終了処理（C版と互換性を保ち、メモリリーク等がないか確認する場所）
pub fn shutdown() void {
    util.infof(@src(), "platform shutdown", .{});
}
