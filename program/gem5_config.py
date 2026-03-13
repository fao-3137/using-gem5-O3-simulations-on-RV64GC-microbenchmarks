"""
gem5 RISC-V O3(SE) 配置文件 —— 用于 BSF / PLR–MR 曲线实验（含 Layer-C：程序敏感性）
- 支持：tournament / local / bimode 三类预测器（去除 ideal/oracle 配置，避免把“ILP 上界”与“完美预测”耦合）
- 支持：固定结构点（width、pipe_scale 固定）下跨程序比较 BSF，并输出 branch density / MPKI 等解释性指标
- 支持：cache on/off（建议主实验先关 cache，减少访存噪声；补充实验再开 cache）
- 兼容性：SEWorkload.init_compatible + createThreads；system_port 使用 membus.cpu_side_ports
"""

import argparse
import m5
from m5.objects import *


# ============================================================================
# 0) Cache 类定义（自包含，避免依赖 common/caches.py）
# ============================================================================

class L1Cache(Cache):
    assoc = 2
    tag_latency = 2
    data_latency = 2
    response_latency = 2
    mshrs = 4
    tgts_per_mshr = 20


class L2Cache(Cache):
    assoc = 8
    tag_latency = 20
    data_latency = 20
    response_latency = 20
    mshrs = 20
    tgts_per_mshr = 12


# ============================================================================
# 1) 处理器参数（ILP 友好：较大的 ROB/IQ/LQ/SQ）
# ============================================================================

class ProcessorConfig:
    # 默认固定结构点（脚本可通过参数覆盖）
    width = 4
    pipe_scale = 1.0

    # 宽度相关（会在 apply_uarch_knobs 中统一设置）
    fetchWidth = 4
    decodeWidth = 4
    renameWidth = 4
    dispatchWidth = 4
    issueWidth = 4
    wbWidth = 4
    commitWidth = 4

    # 窗口/队列（ILP 友好基线；pipe_scale 可做比例缩放）
    numROBEntries = 256
    numIQEntries = 128
    LQEntries = 64
    SQEntries = 64

    # Cache 参数（仅在 enable_cache=True 时生效）
    l1i_size = "32kB"
    l1i_assoc = 2
    l1d_size = "32kB"
    l1d_assoc = 2
    l2_size = "256kB"
    l2_assoc = 4


def _safe_set(obj, name: str, value) -> None:
    """跨 gem5 版本鲁棒：属性不存在就跳过。"""
    try:
        setattr(obj, name, value)
    except Exception:
        pass


def apply_uarch_knobs(width: int, pipe_scale: float) -> None:
    """
    width：超标量宽度（统一作用于 fetch/decode/rename/dispatch/issue/wb/commit）
    pipe_scale：用“等效方式”放大关键 stage delay，构造不同恢复开销（不强行改真实 pipeline 级数）
    """
    ProcessorConfig.width = int(width)
    ProcessorConfig.pipe_scale = float(pipe_scale)

    w = ProcessorConfig.width
    s = ProcessorConfig.pipe_scale

    ProcessorConfig.fetchWidth = w
    ProcessorConfig.decodeWidth = w
    ProcessorConfig.renameWidth = w
    ProcessorConfig.dispatchWidth = w
    ProcessorConfig.issueWidth = w
    ProcessorConfig.wbWidth = w
    ProcessorConfig.commitWidth = w

    # 资源缩放：以 ILP 友好基线为下界，避免缩太小导致跑不满 IPC
    ProcessorConfig.numROBEntries = max(192, int(round(256 * s)))
    ProcessorConfig.numIQEntries = max(96, int(round(128 * s)))
    ProcessorConfig.LQEntries = max(48, int(round(64 * s)))
    ProcessorConfig.SQEntries = max(48, int(round(64 * s)))


# ============================================================================
# 2) 分支预测器配置
# ============================================================================

def create_bp(bp_family: str, bp_level: int):
    bp_family = (bp_family or "").lower()

    # 其他预测器：用离散档位（level）构造多个 MR 采样点
    lvl = int(bp_level)
    if lvl < 0:
        lvl = 0

    if bp_family == "tournament":
        table = [
            dict(local=64, global_=128, choice=128, ctr=2, gh=4, ch=4, lht=64),
            dict(local=128, global_=256, choice=256, ctr=2, gh=6, ch=6, lht=128),
            dict(local=256, global_=512, choice=512, ctr=2, gh=8, ch=8, lht=256),
            dict(local=512, global_=1024, choice=1024, ctr=2, gh=10, ch=10, lht=512),
            dict(local=1024, global_=2048, choice=2048, ctr=2, gh=12, ch=12, lht=1024),
            dict(local=2048, global_=4096, choice=4096, ctr=2, gh=14, ch=14, lht=2048),
            dict(local=4096, global_=8192, choice=8192, ctr=2, gh=16, ch=16, lht=4096),
            dict(local=8192, global_=16384, choice=16384, ctr=2, gh=18, ch=18, lht=8192),
        ]
        idx = min(lvl, len(table) - 1)
        cfg = table[idx]
        bp = TournamentBP()
        _safe_set(bp, "localPredictorSize", cfg["local"])
        _safe_set(bp, "globalPredictorSize", cfg["global_"])
        _safe_set(bp, "choicePredictorSize", cfg["choice"])
        _safe_set(bp, "localCtrBits", cfg["ctr"])
        _safe_set(bp, "globalCtrBits", cfg["ctr"])
        _safe_set(bp, "choiceCtrBits", cfg["ctr"])
        _safe_set(bp, "globalHistoryBits", cfg["gh"])
        _safe_set(bp, "choiceHistoryBits", cfg["ch"])
        _safe_set(bp, "localHistoryTableSize", cfg["lht"])
        return bp, f"Tournament_L{idx}"

    if bp_family == "local":
        table = [
            dict(size=64, ctr=2, lh=4, lht=64),
            dict(size=128, ctr=2, lh=6, lht=128),
            dict(size=256, ctr=2, lh=8, lht=256),
            dict(size=512, ctr=2, lh=10, lht=512),
            dict(size=1024, ctr=2, lh=12, lht=1024),
            dict(size=4096, ctr=2, lh=14, lht=2048),
            dict(size=16384, ctr=2, lh=16, lht=4096),
            dict(size=65536, ctr=2, lh=16, lht=8192),
        ]
        idx = min(lvl, len(table) - 1)
        cfg = table[idx]
        bp = LocalBP()
        _safe_set(bp, "localPredictorSize", cfg["size"])
        _safe_set(bp, "localCtrBits", cfg["ctr"])
        _safe_set(bp, "localHistoryBits", cfg["lh"])
        _safe_set(bp, "localHistoryTableSize", cfg["lht"])
        return bp, f"Local_L{idx}"

    if bp_family == "bimode":
        table = [
            dict(global_=128, choice=128, ctr=2, gh=4),
            dict(global_=256, choice=256, ctr=2, gh=6),
            dict(global_=512, choice=512, ctr=2, gh=8),
            dict(global_=1024, choice=1024, ctr=2, gh=10),
            dict(global_=4096, choice=4096, ctr=2, gh=12),
            dict(global_=16384, choice=16384, ctr=2, gh=14),
            dict(global_=65536, choice=65536, ctr=2, gh=16),
            dict(global_=65536, choice=65536, ctr=2, gh=16),
        ]
        idx = min(lvl, len(table) - 1)
        cfg = table[idx]
        bp = BiModeBP()
        _safe_set(bp, "globalPredictorSize", cfg["global_"])
        _safe_set(bp, "globalCtrBits", cfg["ctr"])
        _safe_set(bp, "choicePredictorSize", cfg["choice"])
        _safe_set(bp, "choiceCtrBits", cfg["ctr"])
        _safe_set(bp, "globalHistoryBits", cfg["gh"])
        return bp, f"BiMode_L{idx}"

    raise ValueError(f"Unknown bp_family: {bp_family}")


# ============================================================================
# 3) 系统构建
# ============================================================================

def create_system(bp_family: str, bp_level: int, enable_cache: bool):
    system = System()
    system.mem_mode = "timing"
    system.clk_domain = SrcClockDomain(clock="1GHz", voltage_domain=VoltageDomain())

    # 建议显式设置 mem_ranges（更接近 gem5 标准写法）
    system.mem_ranges = [AddrRange("512MB")]

    system.cpu = DerivO3CPU()
    system.cpu.clk_domain = system.clk_domain

    system.cpu.branchPred, bp_name = create_bp(bp_family, bp_level)

    # --- 宽度旋钮：尽量全链路统一 ---
    _safe_set(system.cpu, "fetchWidth", ProcessorConfig.fetchWidth)
    _safe_set(system.cpu, "decodeWidth", ProcessorConfig.decodeWidth)
    _safe_set(system.cpu, "renameWidth", ProcessorConfig.renameWidth)
    _safe_set(system.cpu, "dispatchWidth", ProcessorConfig.dispatchWidth)
    _safe_set(system.cpu, "issueWidth", ProcessorConfig.issueWidth)
    _safe_set(system.cpu, "wbWidth", ProcessorConfig.wbWidth)
    _safe_set(system.cpu, "commitWidth", ProcessorConfig.commitWidth)

    # --- ILP 友好资源 ---
    _safe_set(system.cpu, "numROBEntries", ProcessorConfig.numROBEntries)
    _safe_set(system.cpu, "numIQEntries", ProcessorConfig.numIQEntries)
    _safe_set(system.cpu, "LQEntries", ProcessorConfig.LQEntries)
    _safe_set(system.cpu, "SQEntries", ProcessorConfig.SQEntries)

    # --- pipeline 恢复开销代理：放大关键 stage delay ---
    # 说明：这里不是“严格定义 pipeline 级数”，而是让 mispred recovery 的等效开销系统变化
    # （符合你方法文档里对 pipe_scale 的定义口径）
    s = int(round(ProcessorConfig.pipe_scale))
    if s > 1:
        _safe_set(system.cpu, "fetchToDecodeDelay", s)
        _safe_set(system.cpu, "decodeToRenameDelay", s)
        _safe_set(system.cpu, "renameToIEWDelay", s)
        _safe_set(system.cpu, "iewToCommitDelay", s)
        _safe_set(system.cpu, "commitToFetchDelay", s)
        _safe_set(system.cpu, "renameToDispatchDelay", s)
        _safe_set(system.cpu, "dispatchToIssueDelay", s)
        _safe_set(system.cpu, "issueToExecuteDelay", s)
        _safe_set(system.cpu, "executeToCommitDelay", s)

    # --- 互联与内存 ---
    system.membus = SystemXBar()

    system.mem_ctrl = MemCtrl()
    system.mem_ctrl.dram = DDR3_1600_8x8()
    system.mem_ctrl.dram.range = system.mem_ranges[0]
    system.mem_ctrl.port = system.membus.mem_side_ports

    if enable_cache:
        # L1 -> L2 bus -> L2 -> membus -> MemCtrl（标准结构，避免乱连）
        system.l2bus = L2XBar()

        system.cpu.icache = L1Cache(size=ProcessorConfig.l1i_size, assoc=ProcessorConfig.l1i_assoc)
        system.cpu.dcache = L1Cache(size=ProcessorConfig.l1d_size, assoc=ProcessorConfig.l1d_assoc)
        system.l2cache = L2Cache(size=ProcessorConfig.l2_size, assoc=ProcessorConfig.l2_assoc)

        # CPU <-> L1
        system.cpu.icache_port = system.cpu.icache.cpu_side
        system.cpu.dcache_port = system.cpu.dcache.cpu_side

        # L1 <-> L2 bus
        system.cpu.icache.mem_side = system.l2bus.cpu_side_ports
        system.cpu.dcache.mem_side = system.l2bus.cpu_side_ports

        # L2 bus <-> L2
        system.l2cache.cpu_side = system.l2bus.mem_side_ports

        # L2 <-> membus
        system.l2cache.mem_side = system.membus.cpu_side_ports

    else:
        # 无 cache：CPU 直接接 membus（主实验推荐，减少访存噪声）
        system.cpu.icache_port = system.membus.cpu_side_ports
        system.cpu.dcache_port = system.membus.cpu_side_ports

    # system_port：新版本 gem5 通常用 cpu_side_ports（旧的 .slave 可能不存在）
    system.system_port = system.membus.cpu_side_ports

    return system, bp_name


# ============================================================================
# 4) 入口（gem5 以 __m5_main__ 方式调用脚本）
# ============================================================================

if __name__ == "__m5_main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", help="RISC-V binary path (static recommended)")
    parser.add_argument("--bp-family", default="tournament",
                        help="tournament | local | bimode")
    parser.add_argument("--bp-level", type=int, default=3,
                        help="Predictor strength level (0..7) for non-ideal predictors")
    parser.add_argument("--cache", default="false",
                        help="true/false. 建议主实验 false，补充实验再 true")
    parser.add_argument("--width", type=int, default=4)
    parser.add_argument("--pipe-scale", type=float, default=1.0)
    args = parser.parse_args()

    apply_uarch_knobs(args.width, args.pipe_scale)
    enable_cache = (str(args.cache).lower() == "true")

    system, bp_name = create_system(args.bp_family, args.bp_level, enable_cache)

    # SE workload 初始化（保证稳定性与可比性）
    process = Process(cmd=[args.binary], env=["GLIBC_TUNABLES=glibc.pthread.rseq=0"])
    system.workload = SEWorkload.init_compatible(args.binary)
    system.cpu.workload = process

    # 必要的中断与线程初始化（不同 gem5 版本下对统计项生成很关键）
    system.cpu.createInterruptController()
    system.cpu.createThreads()

    root = Root(full_system=False, system=system)
    m5.instantiate()

    print(f"[Run Info] width={ProcessorConfig.width}, pipe_scale={ProcessorConfig.pipe_scale}, "
          f"cache={enable_cache}, bp={bp_name}")

    exit_event = m5.simulate()
    print(f"Simulation finished: {exit_event.getCause()}")

    # dump stats 到 --stats-file 指定的文件中（脚本解析 stats.txt 做后处理）
    m5.stats.dump()
