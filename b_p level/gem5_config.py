"""
gem5 RISC-V 处理器配置脚本（安全修复版）
修复日志：
1. [Critical] 将所有预测器（Local/BiMode）的 ctr (计数器位宽) 强制固定为 2。
   - 原因：排查发现 LocalBP 在 L5(ctr=3) 时崩溃，而 L4(ctr=2) 正常。
   - 这里的 ctr=3 极可能是导致 gem5 内部断言失败的根源。
2. 调整了 LocalBP 的高位参数，限制历史长度不超过 16 bits，防止触碰底层类型限制。
"""

import argparse
import m5
from m5.objects import *

# ============================================================================
# 0. Cache 类定义
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
# 1. 处理器参数配置
# ============================================================================

class ProcessorConfig:
    width = 4
    pipe_scale = 1.0
    
    fetchWidth = 4
    decodeWidth = 4
    issueWidth = 4
    commitWidth = 4

    numIQEntries = 64
    LQEntries = 32
    SQEntries = 32

    l1i_size = '32kB'
    l1i_assoc = 2
    l1d_size = '32kB'
    l1d_assoc = 2
    l2_size = '256kB'
    l2_assoc = 4


def apply_uarch_knobs(width: int, pipe_scale: float) -> None:
    ProcessorConfig.width = int(width)
    ProcessorConfig.pipe_scale = float(pipe_scale)

    w = ProcessorConfig.width
    s = ProcessorConfig.pipe_scale

    ProcessorConfig.fetchWidth = w
    ProcessorConfig.decodeWidth = w
    ProcessorConfig.issueWidth = w
    ProcessorConfig.commitWidth = w

    ProcessorConfig.numIQEntries = max(16, int(round(64 * s)))
    ProcessorConfig.LQEntries = max(8,  int(round(32 * s)))
    ProcessorConfig.SQEntries = max(8,  int(round(32 * s)))


# ============================================================================
# 2. 分支预测器“档位”配置（安全版）
# ============================================================================

def _safe_set(obj, name: str, value):
    try:
        setattr(obj, name, value)
        return True
    except Exception:
        return False


def create_bp(bp_family: str, bp_level: int):
    bp_family = bp_family.lower()
    bp_level = int(bp_level)
    if bp_level < 0:
        raise ValueError("bp_level must be >= 0")

    # ------------------------------------------------------------------------
    # Tournament: 保持原样 (通常最稳健)
    # ------------------------------------------------------------------------
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

    # ------------------------------------------------------------------------
    # Local: 安全修复版
    # 策略：所有档位 ctr=2。Size 严格匹配 2^lh。
    # ------------------------------------------------------------------------
    if bp_family == "local":
        table = [
            # L0 - L4 (已经验证过能跑的参数)
            dict(size=64,     ctr=2, lh=4,  lht=64),
            dict(size=128,    ctr=2, lh=6,  lht=128),
            dict(size=256,    ctr=2, lh=8,  lht=256),
            dict(size=1024,   ctr=2, lh=10, lht=512),
            dict(size=4096,   ctr=2, lh=12, lht=1024),
            
            # L5 - L7 (修复区：降级 ctr=2，确保 Size 足够大)
            # L5: 原 ctr=3 -> 改回 2。 Size 16384 = 2^14 (OK)
            dict(size=16384,  ctr=2, lh=14, lht=2048),
            
            # L6: 原 ctr=3 -> 改回 2。 Size 65536 = 2^16 (OK)
            dict(size=65536,  ctr=2, lh=16, lht=4096),
            
            # L7: 略微保守一点，保持 16 bits 历史，只增加 LHT 大小
            # 如果 gem5 内部用 uint16_t 存历史，超过 16 bits 会回绕
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

    # ------------------------------------------------------------------------
    # BiMode: 安全修复版
    # ------------------------------------------------------------------------
    if bp_family == "bimode":
        table = [
            dict(global_=128,    choice=128,    ctr=2, gh=4),
            dict(global_=256,    choice=256,    ctr=2, gh=6),
            dict(global_=512,    choice=512,    ctr=2, gh=8),
            dict(global_=1024,   choice=1024,   ctr=2, gh=10),
            dict(global_=4096,   choice=4096,   ctr=2, gh=12),
            dict(global_=16384,  choice=16384,  ctr=2, gh=14),
            dict(global_=65536,  choice=65536,  ctr=2, gh=16),
            # L7 同样限制在 gh=16，防止潜在溢出，资源给大一点
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
# 3. 系统配置构建函数
# ============================================================================

def create_system(bp_family: str, bp_level: int, enable_cache: bool = True):
    system = System()
    system.mem_mode = 'timing'
    system.clk_domain = SrcClockDomain()
    system.clk_domain.clock = '1GHz'
    system.clk_domain.voltage_domain = VoltageDomain()

    system.cpu = DerivO3CPU()

    system.cpu.branchPred, bp_name = create_bp(bp_family, bp_level)

    system.cpu.fetchWidth = ProcessorConfig.fetchWidth
    system.cpu.decodeWidth = ProcessorConfig.decodeWidth
    system.cpu.issueWidth = ProcessorConfig.issueWidth
    system.cpu.commitWidth = ProcessorConfig.commitWidth

    system.cpu.numIQEntries = ProcessorConfig.numIQEntries
    system.cpu.LQEntries = ProcessorConfig.LQEntries
    system.cpu.SQEntries = ProcessorConfig.SQEntries

    if enable_cache:
        system.cpu.icache = L1Cache()
        system.cpu.icache.size = ProcessorConfig.l1i_size
        system.cpu.icache.assoc = ProcessorConfig.l1i_assoc

        system.cpu.dcache = L1Cache()
        system.cpu.dcache.size = ProcessorConfig.l1d_size
        system.cpu.dcache.assoc = ProcessorConfig.l1d_assoc

        system.l2cache = L2Cache()
        system.l2cache.size = ProcessorConfig.l2_size
        system.l2cache.assoc = ProcessorConfig.l2_assoc

        system.membus = SystemXBar()

        system.cpu.icache.cpu_side = system.cpu.icache_port
        system.cpu.dcache.cpu_side = system.cpu.dcache_port
        system.cpu.icache.mem_side = system.membus.cpu_side_ports
        system.cpu.dcache.mem_side = system.membus.cpu_side_ports

        system.l2cache.cpu_side = system.membus.mem_side_ports

        system.mem_ctrl = MemCtrl()
        system.mem_ctrl.dram = DDR3_1600_8x8()
        system.mem_ctrl.dram.range = AddrRange('512MB')

        system.l2cache.mem_side = system.mem_ctrl.port

    else:
        system.membus = SystemXBar()
        system.cpu.icache_port = system.membus.cpu_side_ports
        system.cpu.dcache_port = system.membus.cpu_side_ports

        system.mem_ctrl = MemCtrl()
        system.mem_ctrl.dram = DDR3_1600_8x8()
        system.mem_ctrl.dram.range = AddrRange('512MB')

        system.membus.mem_side_ports = system.mem_ctrl.port

    system.system_port = system.membus.slave
    system.cpu.clk_domain = system.clk_domain

    return system, bp_name


# ============================================================================
# 4. 主程序入口
# ============================================================================

if __name__ == '__m5_main__':
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", help="RISC-V binary path")
    parser.add_argument("--bp-family", default="tournament", choices=["tournament", "local", "bimode"])
    parser.add_argument("--bp-level", type=int, default=3)
    parser.add_argument("--cache", default="true", choices=["true", "false"])
    parser.add_argument("--width", type=int, default=4)
    parser.add_argument("--pipe-scale", type=float, default=1.0)

    args = parser.parse_args()

    apply_uarch_knobs(args.width, args.pipe_scale)
    enable_cache = (args.cache.lower() == "true")

    system, bp_name = create_system(args.bp_family, args.bp_level, enable_cache)

    process = Process()
    process.cmd = [args.binary]
    process.env = ["GLIBC_TUNABLES=glibc.pthread.rseq=0"]

    system.cpu.workload = process
    system.cpu.createInterruptController()
    system.cpu.createThreads()
    system.workload = SEWorkload.init_compatible(args.binary)

    root = Root(full_system=False, system=system)
    m5.instantiate()

    print(f"[uarch] width={ProcessorConfig.width} pipe_scale={ProcessorConfig.pipe_scale}")
    print(f"[bp] {bp_name} (family={args.bp_family}, level={args.bp_level})")

    exit_event = m5.simulate()
    print(f"Simulation finished: {exit_event.getCause()}")
    m5.stats.dump()
    m5.stats.reset()
