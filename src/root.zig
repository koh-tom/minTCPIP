// minTCPIP — Zigによる軽量TCP/IPプロトコルスタック

// 各種ユーティリティ関数群 (ロギング、キュー、チェックサム等) のエクスポート
pub const util = @import("util.zig");

// 同期・スレッドインフラ (Zig 0.16対応版Mutex, 時間等) のエクスポート
pub const sync = @import("sync.zig");

// プラットフォーム依存処理 (アロケータ、乱数、割り込み、タイマー等) のエクスポート
pub const platform = @import("platform.zig");

// ============================================================
// platform 空間からアクセス可能なサブモジュール構造
//   minTCPIP.platform.intr   — 割り込み管理
//   minTCPIP.platform.timer  — 定期実行タイマー
//   minTCPIP.platform.sched  — タスクスリープ・スケジューラ
// ============================================================

/// ローカル通信やループバックインターフェイスなどで利用するIP情報のベース設定
pub const test_config = struct {
    pub const LOOPBACK_IP_ADDR = "127.0.0.1";
    pub const LOOPBACK_NETMASK = "255.0.0.0";

    // 仮想NIC (TAPデバイス) 用の設定
    pub const ETHER_TAP_NAME = "tap0";
    // テスト用のダミーMACアドレス (RFC7042 Documentation Value)
    pub const ETHER_TAP_HW_ADDR = "00:00:5e:00:53:01";
    // テスト環境における仮想NIC自身のIPアドレス (RFC5737 TEST-NET-1)
    pub const ETHER_TAP_IP_ADDR = "192.0.2.2";
    // 仮想NICの固定サブネットマスク
    pub const ETHER_TAP_NETMASK = "255.255.255.0";

    // ダミーのデフォルトゲートウェイ
    pub const DEFAULT_GATEWAY = "192.0.2.1";

    /// サンプルとして用意されている検証用のIPパケットダンプ。
    /// （中身は "127.0.0.1" 宛の ICMP Echo Request/Ping パケットです）
    pub const test_data = [_]u8{
        0x45, 0x00, 0x00, 0x30,
        0x00, 0x80, 0x00, 0x00,
        0xff, 0x01, 0xbd, 0x4a,
        0x7f, 0x00, 0x00, 0x01,
        0x7f, 0x00, 0x00, 0x01,
        0x08, 0x00, 0x35, 0x64,
        0x00, 0x80, 0x00, 0x01,
        0x31, 0x32, 0x33, 0x34,
        0x35, 0x36, 0x37, 0x38,
        0x39, 0x30, 0x21, 0x40,
        0x23, 0x24, 0x25, 0x5e,
        0x26, 0x2a, 0x28, 0x29,
    };
};

// ============================================================
// `zig build test` 用のエントリーポイント
// サブモジュール内の test ブロックを再帰的に走らせるために必要です。
// ============================================================
test {
    // 例: util モジュール内に記述された byte order, checksum のテストを実行する
    _ = @import("util.zig");
}
