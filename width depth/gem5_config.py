"""
gem5 RISC-V O3 处理器配置脚本（用于 BSF/结构敏感性实验）
- 支持参数化：bp_family / bp_level / width / pipe_scale / cache
- width：统一控制 fetch/decode/rename/dispatch/issue/wb/commit 宽度，并联动 ROB/IQ/LSQ 等资源
- pipe_scale：用 O3 的 stage delay 成比例放大，作为“流水深度/恢复开销（误预测代价）”代理变量
- 支持 ideal（尽量用 PerfectBP/PerfectBranchPredictor；否则退化成超大 TournamentBP）
"""

import argparse
import m5
from m5.objects import *

# ============================================================================
# 0. Cache 类定义（保持你原风格）
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
# 1. 处理器参数配置（width 联动 + 资源随 width 规模化）
# ============================================================================

class ProcessorConfig:
    width = 4
    pipe_scale = 1.0

    # 一整套宽度（避免只改一部分）
    fetchWidth = 4
    decodeWidth = 4
    renameWidth = 4
    dispatchWidth = 4
    issueWidth = 4
    wbWidth = 4
    commitWidth = 4

    # 乱序窗口/队列：基准 w=4 时用你当前“ILP 极致优化”尺度
    numROBEntries = 256
    numIQEntries = 128
    LQEntries = 64
    SQEntries = 64

    # 物理寄存器：宽度上去后避免 rename 卡死（保守兜底）
    numPhysIntRegs = 256
    numPhysFloatRegs = 256

    # Cache 参数
    l1i_size = "32kB"
    l1i_assoc = 2
    l1d_size = "32kB"
    l1d_assoc = 2
    l2_size = "256kB"
    l2_assoc = 4

def _safe_set(obj, name: str, value) -> None:
    try:
        setattr(obj, name, value)
    except Exception:
        pass

def apply_uarch_knobs(width: int, pipe_scale: float) -> None:
    """根据 width/pipe_scale 设置联动参数
    - width：影响宽度与结构资源
    - pipe_scale：只影响 pipeline delay（不联动 ROB/IQ，避免把变量搅在一起）
    """
    ProcessorConfig.width = int(width)
    ProcessorConfig.pipe_scale = float(pipe_scale)

    w = ProcessorConfig.width
    scale_w = w / 4.0  # 以 w=4 为基准比例缩放资源

    # 宽度全联动
    ProcessorConfig.fetchWidth = w
    ProcessorConfig.decodeWidth = w
    ProcessorConfig.renameWidth = w
    ProcessorConfig.dispatchWidth = w
    ProcessorConfig.issueWidth = w
    ProcessorConfig.wbWidth = w
    ProcessorConfig.commitWidth = w

    # 队列/窗口随 width 比例缩放（并设最小值，避免过小导致额外瓶颈）
    ProcessorConfig.numROBEntries = max(128, int(round(256 * scale_w)))
    ProcessorConfig.numIQEntries  = max(64,  int(round(128 * scale_w)))
    ProcessorConfig.LQEntries     = max(32,  int(round(64  * scale_w)))
    ProcessorConfig.SQEntries     = max(32,  int(round(64  * scale_w)))

    # 物理寄存器：宽度大时更稳（保守不缩小）
    ProcessorConfig.numPhysIntRegs   = max(256, int(round(256 * scale_w)))
    ProcessorConfig.numPhysFloatRegs = max(256, int(round(256 * scale_w)))

# ============================================================================
# 2. 分支预测器配置（family + level；ideal 支持）
# ============================================================================

def create_ideal_bp():
    # 兼容不同 gem5 版本可能的类名
    if "PerfectBP" in globals():
        return globals()["PerfectBP"](), "Ideal_PerfectBP"
    if "PerfectBranchPredictor" in globals():
        return globals()["PerfectBranchPredictor"](), "Ideal_PerfectBranchPredictor"

    # 退化方案：超大 Tournament（不是 oracle，但尽量强）
    bp = TournamentBP()
    _safe_set(bp, "localPredictorSize", 65536)
    _safe_set(bp, "globalPredictorSize", 131072)
    _safe_set(bp, "choicePredictorSize", 131072)
    _safe_set(bp, "localHistoryTableSize", 65536)
    _safe_set(bp, "globalHistoryBits", 32)
    _safe_set(bp, "choiceHistoryBits", 32)
    return bp, "Ideal_ApproxBigTournament"

def create_bp(bp_family: str, bp_level: int):
    bp_family = bp_family.lower()
    bp_level = int(bp_level)
    if bp_level < 0:
        bp_level = 0

    if bp_family == "ideal":
        return create_ideal_bp()

    if bp_family == "tournament":
        table = [
            dict(local=64,   global_=128,  choice=128,   ctr=2, gh=4,  ch=4,  lht=64),
            dict(local=128,  global_=256,  choice=256,   ctr=2, gh=6,  ch=6,  lht=128),
            dict(local=256,  global_=512,  choice=512,   ctr=2, gh=8,  ch=8,  lht=256),
            dict(local=512,  global_=1024, choice=1024,  ctr=2, gh=10, ch=10, lht=512),
            dict(local=1024, global_=2048, choice=2048,  ctr=2, gh=12, ch=12, lht=1024),
            dict(local=2048, global_=4096, choice=4096,  ctr=2, gh=14, ch=14, lht=2048),
            dict(local=4096, global_=8192, choice=8192,  ctr=2, gh=16, ch=16, lht=4096),
            dict(local=8192, global_=16384, choice=16384, ctr=2, gh=18, ch=18, lht=8192),
        ]
        idx = min(bp_level, len(table) - 1)
        cfg = table[idx]
        bp = TournamentBP()
        _safe_set(bp, "localPredictorSize",  cfg["local"])
        _safe_set(bp, "globalPredictorSize", cfg["global_"])
        _safe_set(bp, "choicePredictorSize", cfg["choice"])
        _safe_set(bp, "localCtrBits",  cfg["ctr"])
        _safe_set(bp, "globalCtrBits", cfg["ctr"])
        _safe_set(bp, "choiceCtrBits", cfg["ctr"])
        _safe_set(bp, "globalHistoryBits", cfg["gh"])
        _safe_set(bp, "choiceHistoryBits", cfg["ch"])
        _safe_set(bp, "localHistoryTableSize", cfg["lht"])
        return bp, f"Tournament_L{idx}"

    if bp_family == "local":
        table = [
            dict(size=64,     ctr=2, lh=4,  lht=64),
            dict(size=128,    ctr=2, lh=6,  lht=128),
            dict(size=256,    ctr=2, lh=8,  lht=256),
            dict(size=512,    ctr=2, lh=10, lht=512),
            dict(size=1024,   ctr=2, lh=12, lht=1024),
            dict(size=4096,   ctr=2, lh=14, lht=2048),
            dict(size=16384,  ctr=2, lh=16, lht=4096),
            dict(size=65536,  ctr=2, lh=16, lht=8192),
        ]
        idx = min(bp_level, len(table) - 1)
        cfg = table[idx]
        bp = LocalBP()
        _safe_set(bp, "localPredictorSize", cfg["size"])
        _safe_set(bp, "localCtrBits", cfg["ctr"])
        _safe_set(bp, "localHistoryBits", cfg["lh"])
        _safe_set(bp, "localHistoryTableSize", cfg["lht"])
        return bp, f"Local_L{idx}"

    if bp_family == "bimode":
        table = [
            dict(global_=128,    choice=128,    ctr=2, gh=4),
            dict(global_=256,    choice=256,    ctr=2, gh=6),
            dict(global_=512,    choice=512,    ctr=2, gh=8),
            dict(global_=1024,   choice=1024,   ctr=2, gh=10),
            dict(global_=4096,   choice=4096,   ctr=2, gh=12),
            dict(global_=16384,  choice=16384,  ctr=2, gh=14),
            dict(global_=65536,  choice=65536,  ctr=2, gh=16),
            dict(global_=65536,  choice=65536,  ctr=2, gh=16),
        ]
        idx = min(bp_level, len(table) - 1)
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
# 3. 系统创建
# ============================================================================

def create_system(bp_family: str, bp_level: int, enable_cache: bool):
    system = System()
    system.clk_domain = SrcClockDomain(clock="1GHz", voltage_domain=VoltageDomain())
    system.mem_mode = "timing"
    system.mem_ranges = [AddrRange("512MB")]

    # CPU
    system.cpu = DerivO3CPU()
    system.cpu.branchPred, bp_name = create_bp(bp_family, bp_level)

    # 应用 width
    system.cpu.fetchWidth = ProcessorConfig.fetchWidth
    system.cpu.decodeWidth = ProcessorConfig.decodeWidth
    _safe_set(system.cpu, "renameWidth", ProcessorConfig.renameWidth)
    _safe_set(system.cpu, "dispatchWidth", ProcessorConfig.dispatchWidth)
    system.cpu.issueWidth = ProcessorConfig.issueWidth
    _safe_set(system.cpu, "wbWidth", ProcessorConfig.wbWidth)
    system.cpu.commitWidth = ProcessorConfig.commitWidth

    # 应用窗口/队列
    system.cpu.numROBEntries = ProcessorConfig.numROBEntries
    system.cpu.numIQEntries = ProcessorConfig.numIQEntries
    system.cpu.LQEntries = ProcessorConfig.LQEntries
    system.cpu.SQEntries = ProcessorConfig.SQEntries
    _safe_set(system.cpu, "numPhysIntRegs", ProcessorConfig.numPhysIntRegs)
    _safe_set(system.cpu, "numPhysFloatRegs", ProcessorConfig.numPhysFloatRegs)

    # pipe_scale：用 delay 代理“流水更深/恢复更慢”
    s = max(1, int(round(ProcessorConfig.pipe_scale)))
    _safe_set(system.cpu, "fetchToDecodeDelay", s)
    _safe_set(system.cpu, "decodeToRenameDelay", s)
    _safe_set(system.cpu, "renameToIEWDelay", s)
    _safe_set(system.cpu, "iewToCommitDelay", s)
    _safe_set(system.cpu, "commitToFetchDelay", s)

    # 总线与内存
    system.membus = SystemXBar()

    system.mem_ctrl = MemCtrl()
    system.mem_ctrl.dram = DDR3_1600_8x8(range=system.mem_ranges[0])
    system.mem_ctrl.port = system.membus.mem_side_ports

    # Cache（可选）
    if enable_cache:
        system.l2bus = L2XBar()

        # L1
        system.cpu.icache = L1Cache(size=ProcessorConfig.l1i_size, assoc=ProcessorConfig.l1i_assoc)
        system.cpu.dcache = L1Cache(size=ProcessorConfig.l1d_size, assoc=ProcessorConfig.l1d_assoc)

        # L2
        system.l2cache = L2Cache(size=ProcessorConfig.l2_size, assoc=ProcessorConfig.l2_assoc)

        # CPU <-> L1
        system.cpu.icache.cpu_side = system.cpu.icache_port
        system.cpu.dcache.cpu_side = system.cpu.dcache_port

        # L1 <-> L2 bus
        system.cpu.icache.mem_side = system.l2bus.cpu_side_ports
        system.cpu.dcache.mem_side = system.l2bus.cpu_side_ports

        # L2 bus <-> L2
        system.l2cache.cpu_side = system.l2bus.mem_side_ports

        # L2 <-> membus
        system.l2cache.mem_side = system.membus.cpu_side_ports
    else:
        # 无 cache：CPU 端口直连 membus（主实验推荐）
        system.cpu.icache_port = system.membus.cpu_side_ports
        system.cpu.dcache_port = system.membus.cpu_side_ports

    # system_port（新写法更兼容）
    system.system_port = system.membus.cpu_side_ports

    system.cpu.clk_domain = system.clk_domain
    return system, bp_name

# ============================================================================
# 4. 主入口
# ============================================================================

if __name__ == "__m5_main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", help="Binary path")
    parser.add_argument("--bp-family", default="tournament")
    parser.add_argument("--bp-level", type=int, default=3)
    parser.add_argument("--cache", default="false")
    parser.add_argument("--width", type=int, default=4)
    parser.add_argument("--pipe-scale", type=float, default=1.0)
    args = parser.parse_args()

    apply_uarch_knobs(args.width, args.pipe_scale)
    enable_cache = (args.cache.lower() == "true")

    system, bp_name = create_system(args.bp_family, args.bp_level, enable_cache)

    # SE workload 初始化
    system.workload = SEWorkload.init_compatible(args.binary)

    # 进程
    process = Process(cmd=[args.binary], env=["GLIBC_TUNABLES=glibc.pthread.rseq=0"])
    system.cpu.workload = process

    # 中断 + 线程（SE 模式稳定性关键）
    system.cpu.createInterruptController()
    system.cpu.createThreads()

    root = Root(full_system=False, system=system)
    m5.instantiate()

    print(f"[Run Info] width={ProcessorConfig.width}, pipe_scale={ProcessorConfig.pipe_scale}, cache={enable_cache}, bp={bp_name}")

    exit_event = m5.simulate()
    print(f"Simulation finished: {exit_event.getCause()}")

    m5.stats.dump()

