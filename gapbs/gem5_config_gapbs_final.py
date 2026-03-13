"""
gem5 RISC-V O3 (SE) 配置脚本 —— GAPBS 稳定版（无 maxinsts/maxticks）
- 支持：tournament / local / bimode 分支预测器家族 + level 档位
- 支持：--width / --pipe-scale / --cache / --mem-size
- 支持：--prog-args（GAPBS 必需，传入 -g SCALE -n THREADS 等）
- 兼容：SEWorkload.init_compatible + createInterruptController + createThreads
"""

import argparse
import shlex

import m5
from m5.objects import *


# ============================================================================
# Cache 定义（自包含）
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
# Processor knobs
# ============================================================================

class ProcessorConfig:
    width = 4
    pipe_scale = 1.0

    fetchWidth = 4
    decodeWidth = 4
    renameWidth = 4
    dispatchWidth = 4
    issueWidth = 4
    wbWidth = 4
    commitWidth = 4

    numROBEntries = 256
    numIQEntries = 128
    LQEntries = 64
    SQEntries = 64

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
    w = int(width)
    s = float(pipe_scale)

    ProcessorConfig.width = w
    ProcessorConfig.pipe_scale = s

    ProcessorConfig.fetchWidth = w
    ProcessorConfig.decodeWidth = w
    ProcessorConfig.renameWidth = w
    ProcessorConfig.dispatchWidth = w
    ProcessorConfig.issueWidth = w
    ProcessorConfig.wbWidth = w
    ProcessorConfig.commitWidth = w

    # 资源缩放：给下界，避免小 scale 下资源过小导致 IPC 人为变差
    ProcessorConfig.numROBEntries = max(192, int(round(256 * s)))
    ProcessorConfig.numIQEntries = max(96,  int(round(128 * s)))
    ProcessorConfig.LQEntries     = max(48,  int(round(64  * s)))
    ProcessorConfig.SQEntries     = max(48,  int(round(64  * s)))


# ============================================================================
# Branch predictors
# ============================================================================

def create_bp(bp_family: str, bp_level: int):
    fam = (bp_family or "").lower()
    lvl = max(0, int(bp_level))

    if fam == "tournament":
        table = [
            dict(local=64,   global_=128,   choice=128,   ctr=2, gh=4,  ch=4,  lht=64),
            dict(local=128,  global_=256,   choice=256,   ctr=2, gh=6,  ch=6,  lht=128),
            dict(local=256,  global_=512,   choice=512,   ctr=2, gh=8,  ch=8,  lht=256),
            dict(local=512,  global_=1024,  choice=1024,  ctr=2, gh=10, ch=10, lht=512),
            dict(local=1024, global_=2048,  choice=2048,  ctr=2, gh=12, ch=12, lht=1024),
            dict(local=2048, global_=4096,  choice=4096,  ctr=2, gh=14, ch=14, lht=2048),
            dict(local=4096, global_=8192,  choice=8192,  ctr=2, gh=16, ch=16, lht=4096),
            dict(local=8192, global_=16384, choice=16384, ctr=2, gh=18, ch=18, lht=8192),
        ]
        idx = min(lvl, len(table) - 1)
        c = table[idx]
        bp = TournamentBP()
        _safe_set(bp, "localPredictorSize", c["local"])
        _safe_set(bp, "globalPredictorSize", c["global_"])
        _safe_set(bp, "choicePredictorSize", c["choice"])
        _safe_set(bp, "localCtrBits", c["ctr"])
        _safe_set(bp, "globalCtrBits", c["ctr"])
        _safe_set(bp, "choiceCtrBits", c["ctr"])
        _safe_set(bp, "globalHistoryBits", c["gh"])
        _safe_set(bp, "choiceHistoryBits", c["ch"])
        _safe_set(bp, "localHistoryTableSize", c["lht"])
        return bp, f"Tournament_L{idx}"

    if fam == "local":
        table = [
            dict(size=64,    ctr=2, lh=4,  lht=64),
            dict(size=128,   ctr=2, lh=6,  lht=128),
            dict(size=256,   ctr=2, lh=8,  lht=256),
            dict(size=512,   ctr=2, lh=10, lht=512),
            dict(size=1024,  ctr=2, lh=12, lht=1024),
            dict(size=4096,  ctr=2, lh=14, lht=2048),
            dict(size=16384, ctr=2, lh=16, lht=4096),
            dict(size=65536, ctr=2, lh=16, lht=8192),
        ]
        idx = min(lvl, len(table) - 1)
        c = table[idx]
        bp = LocalBP()
        _safe_set(bp, "localPredictorSize", c["size"])
        _safe_set(bp, "localCtrBits", c["ctr"])
        _safe_set(bp, "localHistoryBits", c["lh"])
        _safe_set(bp, "localHistoryTableSize", c["lht"])
        return bp, f"Local_L{idx}"

    if fam == "bimode":
        table = [
            dict(global_=128,   choice=128,   ctr=2, gh=4),
            dict(global_=256,   choice=256,   ctr=2, gh=6),
            dict(global_=512,   choice=512,   ctr=2, gh=8),
            dict(global_=1024,  choice=1024,  ctr=2, gh=10),
            dict(global_=4096,  choice=4096,  ctr=2, gh=12),
            dict(global_=16384, choice=16384, ctr=2, gh=14),
            dict(global_=65536, choice=65536, ctr=2, gh=16),
            dict(global_=65536, choice=65536, ctr=2, gh=16),
        ]
        idx = min(lvl, len(table) - 1)
        c = table[idx]
        bp = BiModeBP()
        _safe_set(bp, "globalPredictorSize", c["global_"])
        _safe_set(bp, "globalCtrBits", c["ctr"])
        _safe_set(bp, "choicePredictorSize", c["choice"])
        _safe_set(bp, "choiceCtrBits", c["ctr"])
        _safe_set(bp, "globalHistoryBits", c["gh"])
        return bp, f"BiMode_L{idx}"

    raise ValueError(f"Unknown bp_family: {bp_family}")


# ============================================================================
# System construction
# ============================================================================

def create_system(bp_family: str, bp_level: int, enable_cache: bool, mem_size: str):
    system = System()
    system.mem_mode = "timing"
    system.clk_domain = SrcClockDomain(clock="1GHz", voltage_domain=VoltageDomain())
    system.mem_ranges = [AddrRange(mem_size)]

    system.cpu = DerivO3CPU()
    system.cpu.clk_domain = system.clk_domain

    system.cpu.branchPred, bp_name = create_bp(bp_family, bp_level)

    # widths
    _safe_set(system.cpu, "fetchWidth",     ProcessorConfig.fetchWidth)
    _safe_set(system.cpu, "decodeWidth",    ProcessorConfig.decodeWidth)
    _safe_set(system.cpu, "renameWidth",    ProcessorConfig.renameWidth)
    _safe_set(system.cpu, "dispatchWidth",  ProcessorConfig.dispatchWidth)
    _safe_set(system.cpu, "issueWidth",     ProcessorConfig.issueWidth)
    _safe_set(system.cpu, "wbWidth",        ProcessorConfig.wbWidth)
    _safe_set(system.cpu, "commitWidth",    ProcessorConfig.commitWidth)

    # resources
    _safe_set(system.cpu, "numROBEntries",  ProcessorConfig.numROBEntries)
    _safe_set(system.cpu, "numIQEntries",   ProcessorConfig.numIQEntries)
    _safe_set(system.cpu, "LQEntries",      ProcessorConfig.LQEntries)
    _safe_set(system.cpu, "SQEntries",      ProcessorConfig.SQEntries)

    # delay proxy from pipe_scale (discrete)
    s = int(round(ProcessorConfig.pipe_scale))
    if s > 1:
        _safe_set(system.cpu, "fetchToDecodeDelay",     s)
        _safe_set(system.cpu, "decodeToRenameDelay",    s)
        _safe_set(system.cpu, "renameToIEWDelay",       s)
        _safe_set(system.cpu, "iewToCommitDelay",       s)
        _safe_set(system.cpu, "commitToFetchDelay",     s)
        _safe_set(system.cpu, "renameToDispatchDelay",  s)
        _safe_set(system.cpu, "dispatchToIssueDelay",   s)
        _safe_set(system.cpu, "issueToExecuteDelay",    s)
        _safe_set(system.cpu, "executeToCommitDelay",   s)

    # memory system
    system.membus = SystemXBar()

    system.mem_ctrl = MemCtrl()
    system.mem_ctrl.dram = DDR3_1600_8x8()
    system.mem_ctrl.dram.range = system.mem_ranges[0]
    system.mem_ctrl.port = system.membus.mem_side_ports

    if enable_cache:
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
        system.cpu.icache_port = system.membus.cpu_side_ports
        system.cpu.dcache_port = system.membus.cpu_side_ports

    # system port
    system.system_port = system.membus.cpu_side_ports

    # walker ports (optional across versions/configs)
    try:
        system.cpu.mmu.connectWalkerPorts(system.membus.cpu_side_ports, system.membus.cpu_side_ports)
    except Exception:
        pass

    return system, bp_name


# ============================================================================
# Main
# ============================================================================

if __name__ == "__m5_main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", help="RISC-V binary path (static recommended)")
    parser.add_argument("--prog-args", default="", help="Arguments to binary, e.g. \"-g 10 -n 1\"")
    parser.add_argument("--mem-size", default="512MB", help="Memory size, e.g. 512MB, 2GB")

    parser.add_argument("--bp-family", default="tournament", choices=["tournament", "local", "bimode"])
    parser.add_argument("--bp-level", type=int, default=3)

    parser.add_argument("--cache", default="false", help="true/false")
    parser.add_argument("--width", type=int, default=4)
    parser.add_argument("--pipe-scale", type=float, default=1.0)

    args = parser.parse_args()

    apply_uarch_knobs(args.width, args.pipe_scale)
    enable_cache = (str(args.cache).lower() == "true")

    system, bp_name = create_system(args.bp_family, args.bp_level, enable_cache, args.mem_size)

    cmd = [args.binary] + shlex.split(args.prog_args)
    process = Process(cmd=cmd, env=["GLIBC_TUNABLES=glibc.pthread.rseq=0"])

    system.workload = SEWorkload.init_compatible(args.binary)
    system.cpu.workload = process

    system.cpu.createInterruptController()
    system.cpu.createThreads()

    root = Root(full_system=False, system=system)
    m5.instantiate()

    print(f"[Run Info] cmd={' '.join(cmd)}")
    print(f"[Run Info] width={ProcessorConfig.width}, pipe_scale={ProcessorConfig.pipe_scale}, "
          f"cache={enable_cache}, mem={args.mem_size}, bp={bp_name}")

    exit_event = m5.simulate()
    print(f"Simulation finished: {exit_event.getCause()}")
    m5.stats.dump()
