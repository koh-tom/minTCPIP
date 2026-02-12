// タスクスケジューラサブシステム

const std = @import("std");
const util = @import("util.zig");
const intr = @import("intr.zig");
const sync = @import("sync.zig");

// ============================================================
// タスク構造体 (PCBに埋め込んで利用)
// ============================================================

/// スリープ/起床機能を備えた「スケジューラブルなタスク」情報です。
/// UDP制御ブロック(UDP PCB)やTCP制御ブロック(TCP PCB)の内部に、
/// メンバー変数の1つとして埋め込んで利用します。
pub const SchedTask = struct {
    next: ?*SchedTask = null, // スリープ中のタスク群を繋ぐリンクリスト用ノード
    cond: sync.Condition = .{}, // このタスク専用の条件変数 (ここでスリープする)
    interrupted: bool = false, // シャットダウンやシグナルによって強制終了される際のフラグ
    wc: i32 = 0, // 待機カウント(Wait Count) / 同時にスリープしている数
};

// ============================================================
// グローバルモジュール状態
// ============================================================

/// スリープに入っているタスク群のリンクリストを保護するためのミューテックス
var tasks_lock: sync.Mutex = .{};

/// 現在スリープ中のタスク群リスト
var tasks: ?*SchedTask = null;

// ============================================================
// 内部関数 (スリープリストの管理)
// ============================================================

/// タスクをスリープ中リストに追加します
fn tasksAdd(task: *SchedTask) void {
    tasks_lock.lock();
    task.next = tasks;
    tasks = task; // 先頭に追加
    tasks_lock.unlock();
}

/// タスクをスリープ中リストから削除します
fn tasksDel(task: *SchedTask) void {
    tasks_lock.lock();
    if (tasks == task) {
        tasks = task.next; // 先頭の削除
        task.next = null;
        tasks_lock.unlock();
        return;
    }
    // 中間・末尾からの削除
    var entry = tasks;
    while (entry) |e| {
        if (e.next == task) {
            e.next = task.next;
            task.next = null;
            break;
        }
        entry = e.next;
    }
    tasks_lock.unlock();
}

// ============================================================
// パブリック API
// ============================================================

/// 指定したタスクを初期化します。
/// (使用前に必ず呼び出す必要があります)
pub fn taskInit(task: *SchedTask) void {
    task.* = .{};
}

/// 指定したタスクを破棄します。
/// まだスレッドがタスクでスリープ中の場合はエラー `error.TaskBusy` を返します。
pub fn taskDestroy(task: *SchedTask) !void {
    if (task.wc != 0) {
        return error.TaskBusy;
    }
}

/// 現在の関数（スレッド）を指定したタスク上でスリープさせます。
/// パケットが到着するか、強制割り込み(interrupt)が発生するまでブロックされます。
///
/// 引数の `lock` はスリープに入る直前に条件変数によって自動的に解放され、
/// 目覚めた直後に自動的に再取得されるプロトコルスタック全体のロックを想定しています。
pub fn taskSleep(task: *SchedTask, lock: *sync.Mutex) !void {
    // 既に中断フラグが立っているなら最初から寝ない
    if (task.interrupted) {
        return error.Interrupted;
    }

    task.wc += 1;
    tasksAdd(task);

    // ====== 【スリープの核】 ======
    // ・ここで渡された `lock` を一旦手放し、自身は眠りに落ちる。
    // ・誰かが taskWakeup() を呼ぶと目覚め、自動的に再び `lock` を獲得してから次に進む。
    task.cond.wait(lock);

    tasksDel(task);
    task.wc -= 1;

    // 起きた理由が、正常なパケット到着ではなく例外的な中断命令だった場合
    if (task.interrupted) {
        if (task.wc == 0) {
            task.interrupted = false; // 最後の1人がフラグを片付ける
        }
        return error.Interrupted;
    }
}

/// このタスク上でスリープ待機している全てのスレッドを起床(Wake)させます。
/// 通常、ネットワークからパケットを受信し対象システムへデータを渡すタイミングなどで呼び出されます。
pub fn taskWakeup(task: *SchedTask) void {
    task.cond.broadcast(); // 複数人が待機していてもまとめて起床させる
}

/// スケジューラサブシステムを初期化します。
/// ユーザー割り込み(IRQ_USER)を補足して、全タスクの強制終了が行えるようハンドラを登録します。
pub fn init() !void {
    try intr.register(intr.IRQ_USER, schedIrqHandler, 0, null);
}

/// スケジューラの動作を開始します（現時点では空関数。C版互換のため用意）
pub fn run() void {}

/// スケジューラ周りのリソースを開放します（現時点では空関数）
pub fn shutdown() void {}

// ============================================================
// シャットダウン機能用 IRQ ハンドラ
// ============================================================

/// システム強制終了時など、外部からタスクを中断させる必要がある際に呼ばれます
/// (IRQ_USERイベント発生時に発火)。
/// スリープ中リストにあるすべてのタスクについて `interrupted` フラグを立て、
/// 無理やり起床させて `error.Interrupted` を返却させる緊急脱出ハッチの役割を担います。
fn schedIrqHandler(_: u32, _: ?*anyopaque) void {
    tasks_lock.lock();
    var task = tasks;
    while (task) |t| {
        if (!t.interrupted) {
            t.interrupted = true; // 中断指示を記録
            t.cond.broadcast(); // 眠っている人を全員無理やり起こす
        }
        task = t.next;
    }
    tasks_lock.unlock();
}
