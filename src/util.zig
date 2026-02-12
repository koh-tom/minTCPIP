// ユーティリティモジュール
// minTCPIPプロトコルスタック全体で共通利用されるユーティリティ関数群を提供します。
// 主な機能：
//   1. ロギング (lprintf同等関数)
//   2. 16進ダンプ (hexdump)
//   3. 侵入型リストキュー (Queue)
//   4. バイトオーダー変換 (ntoh/hton)
//   5. インターネットチェックサム (cksum16)

const std = @import("std");
const sync = @import("sync.zig");

// ============================================================
// ロギング機能
// ============================================================

/// タイムスタンプとファイル名、行番号を付与してログを出力するベース関数です。
/// C版の `lprintf()` 相当の機能を提供します。
pub fn logMessage(
    level: u8, // 'E'(Error), 'W'(Warning), 'I'(Info), 'D'(Debug)
    src: std.builtin.SourceLocation,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const now = sync.nowMillis();
    const secs = now / 1000;
    const ms = now % 1000;

    // フォーマット: "秒.ミリ秒 [レベル] 関数名: メッセージ (ファイル名:行番号)"
    std.debug.print("{d}.{d:0>3} [{c}] {s}: ", .{
        secs, ms, level, src.fn_name,
    });
    std.debug.print(fmt, args);
    std.debug.print(" ({s}:{d})\n", .{ src.file, src.line });
}

/// エラーログを出力します (@src()を使って呼び出し位置の情報を渡します)
pub inline fn errorf(src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    logMessage('E', src, fmt, args);
}

/// 警告ログを出力します
pub inline fn warnf(src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    logMessage('W', src, fmt, args);
}

/// 情報ログを出力します
pub inline fn infof(src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    logMessage('I', src, fmt, args);
}

/// デバッグログを出力します
pub inline fn debugf(src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    logMessage('D', src, fmt, args);
}

// ============================================================
// 16進ダンプ (Hexdump)
// ============================================================

/// バイナリデータを可読な16進数とASCII文字にして標準エラーに出力します。
/// パケットの中身をデバッグ調査する際などに使用します。
pub fn hexdump(data: []const u8) void {
    std.debug.print("+------+-------------------------------------------------+------------------+\n", .{});
    var offset: usize = 0;
    // 1行あたり16バイトとして処理
    while (offset < data.len) : (offset += 16) {
        // オフセット表示
        std.debug.print("| {x:0>4} | ", .{offset});
        // 16進数部分の表示
        for (0..16) |i| {
            if (offset + i < data.len) {
                std.debug.print("{x:0>2} ", .{data[offset + i]});
            } else {
                std.debug.print("   ", .{}); // データが足りない部分は空白埋め
            }
        }
        std.debug.print("| ", .{});
        // ASCII文字部分の表示
        for (0..16) |i| {
            if (offset + i < data.len) {
                const c = data[offset + i];
                // 印字可能な文字であればそのまま、それ以外はドット(.)を表示
                if (std.ascii.isPrint(c)) {
                    std.debug.print("{c}", .{c});
                } else {
                    std.debug.print(".", .{});
                }
            } else {
                std.debug.print(" ", .{});
            }
        }
        std.debug.print(" |\n", .{});
    }
    std.debug.print("+------+-------------------------------------------------+------------------+\n", .{});
}

// ============================================================
// キュー管理 (侵入型リンクリスト)
// ============================================================

/// 侵入型(Intrusive)リンクリストのノード。
/// この構造体を任意の構造体の中にフィールドとして埋め込むことで、
/// その構造体をそのままキューに積めるようになります（Zigの @fieldParentPtr などと併用）。
pub const QueueEntry = struct {
    next: ?*QueueEntry = null,
};

/// ネットワークパケットやPCBなどを管理する汎用的なFIFOキュー
pub const Queue = struct {
    head: ?*QueueEntry = null, // キューの先頭（次に取り出される要素）
    tail: ?*QueueEntry = null, // キューの末尾（最後に追加された要素）
    num: usize = 0, // キューに積まれている要素数

    /// キューを空の状態に初期化します
    pub fn init(self: *Queue) void {
        self.* = .{};
    }

    /// キューの末尾にエントリをプッシュ(追加)します
    pub fn push(self: *Queue, entry: *QueueEntry) *QueueEntry {
        entry.next = null;
        if (self.tail) |t| {
            t.next = entry; // 古い末尾の次に繋げる
        }
        self.tail = entry; // 新しい末尾として更新
        if (self.head == null) {
            self.head = entry; // キューが空だった場合は先頭にもなる
        }
        self.num += 1;
        return entry;
    }

    /// キューの先頭からエントリをポップ(取り出し)します
    pub fn pop(self: *Queue) ?*QueueEntry {
        const entry = self.head orelse return null;
        self.head = entry.next; // 先頭を次の要素にずらす
        if (self.head == null) {
            self.tail = null; // 全て空になったら末尾もnullに
        }
        self.num -= 1;
        entry.next = null; // 取り出した要素のリンク関係を断ち切る
        return entry;
    }

    /// 先頭要素を取り出さずに覗き見(peek)します
    pub fn peek(self: *const Queue) ?*QueueEntry {
        return self.head;
    }

    /// キュー内のすべての要素に対して関数を適用します
    pub fn forEach(
        self: *const Queue,
        func: *const fn (?*anyopaque, *QueueEntry) void,
        arg: ?*anyopaque,
    ) void {
        var entry = self.head;
        while (entry) |e| {
            // func内でリスト改変が行われる可能性を考慮し、事前に次の要素を退避しておく
            const next = e.next;
            func(arg, e);
            entry = next;
        }
    }
};

// ============================================================
// バイトオーダー変換関数
// ============================================================
// ネットワーク上では「ビッグエンディアン」を利用することがRFCで定められています。
// プログラムが動いているCPUアーキテクチャ(x86などはリトルエンディアン)に合わせて
// 16ビット値／32ビット値を適切にバイトスワップするための関数群です。

/// ホストバイトオーダーからネットワークバイトオーダーへ (16bit)
pub inline fn hton16(h: u16) u16 {
    return std.mem.nativeToBig(u16, h);
}

/// ネットワークバイトオーダーからホストバイトオーダーへ (16bit)
pub inline fn ntoh16(n: u16) u16 {
    return std.mem.bigToNative(u16, n);
}

/// ホストバイトオーダーからネットワークバイトオーダーへ (32bit)
pub inline fn hton32(h: u32) u32 {
    return std.mem.nativeToBig(u32, h);
}

/// ネットワークバイトオーダーからホストバイトオーダーへ (32bit)
pub inline fn ntoh32(n: u32) u32 {
    return std.mem.bigToNative(u32, n);
}

// ============================================================
// チェックサム計算
// ============================================================

/// RFC 1071 インターネットチェックサムの計算
/// IPヘッダ、TCP、UDPなどのエラー検出用チェックサムを計算します。
/// 全ての16ビットワードの1の補数和をとり、その結果の1の補数を返します。
pub fn cksum16(data: []const u8, initial: u32) u16 {
    var sum: u32 = initial;
    var i: usize = 0;

    // 2バイト（16ビット）ずつ取り出して足し合わせる
    while (i + 1 < data.len) : (i += 2) {
        // x86等のポインタキャストと同じくリトルエンディアンとして取り出す
        const word: u32 = @as(u32, data[i]) | (@as(u32, data[i + 1]) << 8);
        sum += word;
    }

    // データ長が奇数の場合、最後の1バイトを加算する
    if (i < data.len) {
        sum += @as(u32, data[i]);
    }

    // 32ビットに溢れた超過部分(桁上がり)を、下位16ビットに折り返して足し込む
    while (sum >> 16 != 0) {
        sum = (sum & 0xffff) + (sum >> 16);
    }

    // 最後にビット反転（1の補数）して返す
    return ~@as(u16, @truncate(sum));
}

// ============================================================
// ユニットテスト
// ============================================================

test "queue push/pop" {
    var q: Queue = .{};
    q.init();

    var e1: QueueEntry = .{};
    var e2: QueueEntry = .{};
    var e3: QueueEntry = .{};

    _ = q.push(&e1);
    _ = q.push(&e2);
    _ = q.push(&e3);
    try std.testing.expectEqual(@as(usize, 3), q.num);

    try std.testing.expectEqual(&e1, q.pop().?);
    try std.testing.expectEqual(&e2, q.pop().?);
    try std.testing.expectEqual(&e3, q.pop().?);
    try std.testing.expectEqual(@as(?*QueueEntry, null), q.pop());
    try std.testing.expectEqual(@as(usize, 0), q.num);
}

test "byte order roundtrip" {
    const val16: u16 = 0x1234;
    try std.testing.expectEqual(val16, ntoh16(hton16(val16)));
    const val32: u32 = 0x12345678;
    try std.testing.expectEqual(val32, ntoh32(hton32(val32)));
}

test "checksum of IP header" {
    const ip_header = [_]u8{
        0x45, 0x00, 0x00, 0x30,
        0x00, 0x80, 0x00, 0x00,
        0xff, 0x01, 0xbd, 0x4a,
        0x7f, 0x00, 0x00, 0x01,
        0x7f, 0x00, 0x00, 0x01,
    };
    // 正常なIPヘッダであればチェックサムを自ら再計算した際の結果は必ず0になる
    const result = cksum16(&ip_header, 0);
    try std.testing.expectEqual(@as(u16, 0), result);
}
