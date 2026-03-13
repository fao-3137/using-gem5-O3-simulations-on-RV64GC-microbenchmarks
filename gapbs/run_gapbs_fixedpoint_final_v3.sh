#!/usr/bin/env bash
# GAPBS (RV64 static) on gem5 RISC-V O3 (SE) —— 修复版：汇总“无数据”问题
#
# 根因：之前在 bash->python 传递数组时用了 `'a' 'b'` 形式，Python 会把相邻字符串字面量自动拼接，
#      导致 PROGRAMS 变成 "bfsccpr..."，FAMILIES 变成 "tournamentlocal..."，从而找不到 stats 路径，汇总全为 0/NaN。
# 本脚本用“空格分隔字符串”传参给 python，再 split()，确保循环正确。
#
# 产物：
# - 每个点：${RESULT_DIR}/${program}/${bp_family}_L${bp_level}/stats.txt + sim.log + cmd.sh + exit_code/cause
# - 汇总：
#   summary_<family>.csv（兼容口径） + summary_ext_<family>.csv（扩展口径）
#   summary_all.csv + summary_ext_all.csv
# - manifest.json（记录 sweep 参数）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}"

# Paths
GEM5_PATH="${GEM5_PATH:-/home/fao/gem5}"
GEM5_BINARY="${GEM5_BINARY:-${GEM5_PATH}/build/RISCV/gem5.opt}"

# 默认用同目录的最终版配置脚本；可用 CONFIG_SCRIPT 覆盖
CONFIG_SCRIPT="${CONFIG_SCRIPT:-${WORK_DIR}/gem5_config_gapbs_final.py}"

GAPBS_DIR="${GAPBS_DIR:-$HOME/GAPBS/gapbs}"
RESULT_DIR="${RESULT_DIR:-$PWD/result_gapbs_fixedpoint}"
mkdir -p "${RESULT_DIR}"

# Workload knobs (large graphs by default; override via env)
SCALE="${SCALE:-14}"
THREADS="${THREADS:-1}"
MEM_SIZE="${MEM_SIZE:-2GB}"

# Fixed microarchitectural point
WIDTH="${WIDTH:-4}"
PIPE_SCALE="${PIPE_SCALE:-1.0}"
CACHE="${CACHE:-false}"

# Sweep space
BP_FAMILIES=("tournament" "local" "bimode")

if [[ -n "${BP_LEVELS_OVERRIDE:-}" ]]; then
  read -r -a BP_LEVELS <<< "${BP_LEVELS_OVERRIDE}"
else
  BP_LEVELS=(1 3 5 7)
fi

PROGRAMS=(bfs cc pr sssp tc bc)

# String forms for python (critical fix)
PROGRAMS_STR="${PROGRAMS[*]}"
FAMILIES_STR="${BP_FAMILIES[*]}"
LEVELS_STR="${BP_LEVELS[*]}"

# Sanity checks (skip if ONLY_SUMMARY=1)
if [[ "${ONLY_SUMMARY:-0}" != "1" ]]; then
  if [[ ! -x "${GEM5_BINARY}" ]]; then
    echo "[ERROR] GEM5_BINARY not found/executable: ${GEM5_BINARY}" >&2
    exit 1
  fi
  if [[ ! -f "${CONFIG_SCRIPT}" ]]; then
    echo "[ERROR] CONFIG_SCRIPT not found: ${CONFIG_SCRIPT}" >&2
    exit 1
  fi
  for p in "${PROGRAMS[@]}"; do
    if [[ ! -x "${GAPBS_DIR}/${p}" ]]; then
      echo "[ERROR] GAPBS binary missing/not executable: ${GAPBS_DIR}/${p}" >&2
      exit 1
    fi
  done
fi

run_one () {
  local prog="$1"
  local fam="$2"
  local lvl="$3"
  local outdir="${RESULT_DIR}/${prog}/${fam}_L${lvl}"
  mkdir -p "${outdir}"

  local cmd=(
    "${GEM5_BINARY}"
    -d "${outdir}"
    --stats-file="${outdir}/stats.txt"
    "${CONFIG_SCRIPT}"
    "${GAPBS_DIR}/${prog}"
    --prog-args "-g ${SCALE} -n ${THREADS}"
    --mem-size "${MEM_SIZE}"
    --bp-family "${fam}"
    --bp-level "${lvl}"
    --cache "${CACHE}"
    --width "${WIDTH}"
    --pipe-scale "${PIPE_SCALE}"
  )

  printf "%q " "${cmd[@]}" > "${outdir}/cmd.sh"
  echo >> "${outdir}/cmd.sh"
  chmod +x "${outdir}/cmd.sh"

  echo "    -> ${outdir}"

  set +e
  "${cmd[@]}" > "${outdir}/sim.log" 2>&1
  local ec=$?
  set -e

  echo "${ec}" > "${outdir}/exit_code.txt"
  local cause
  cause="$(grep -E 'Simulation finished:' "${outdir}/sim.log" | tail -n 1 | sed 's/.*Simulation finished: *//' | tr ',' ';')"
  [[ -z "${cause}" ]] && cause="(unknown)"
  echo "${cause}" > "${outdir}/exit_cause.txt"
}

write_manifest () {
  python3 - <<PY
import json, time
manifest = {
  "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
  "gem5_binary": r"""${GEM5_BINARY}""",
  "config_script": r"""${CONFIG_SCRIPT}""",
  "gapbs_dir": r"""${GAPBS_DIR}""",
  "result_dir": r"""${RESULT_DIR}""",
  "workload": {"scale": int(${SCALE}), "threads": int(${THREADS}), "mem_size": r"""${MEM_SIZE}"""},
  "uarch": {"width": int(${WIDTH}), "pipe_scale": float(${PIPE_SCALE}), "cache": r"""${CACHE}"""},
  "sweep": {"families": r"""${FAMILIES_STR}""".split(), "levels": [int(x) for x in r"""${LEVELS_STR}""".split()]},
  "programs": r"""${PROGRAMS_STR}""".split(),
}
with open(r"""${RESULT_DIR}/manifest.json""", "w", encoding="utf-8") as f:
  json.dump(manifest, f, indent=2)
print("[OK] wrote manifest.json")
PY
}

write_summaries () {
  python3 - <<PY
import csv, math, re
from pathlib import Path

RESULT_DIR = Path(r"""${RESULT_DIR}""")
PROGRAMS = r"""${PROGRAMS_STR}""".split()
BP_FAMILIES = r"""${FAMILIES_STR}""".split()
BP_LEVELS = [int(x) for x in r"""${LEVELS_STR}""".split()]

WIDTH = float(r"""${WIDTH}""")
PIPE_SCALE = float(r"""${PIPE_SCALE}""")
SCALE = int(r"""${SCALE}""")
THREADS = int(r"""${THREADS}""")
CACHE = r"""${CACHE}"""
MEM_SIZE = r"""${MEM_SIZE}"""

def parse_stats(path: Path):
    stats = {}
    if not path.is_file():
        return stats
    with path.open("r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            k, v = parts[0], parts[1]
            try:
                stats[k] = float(v) if v.lower() != "nan" else float("nan")
            except Exception:
                pass
    return stats

def get_first(stats, keys, default=float("nan")):
    for k in keys:
        if k in stats:
            return stats[k]
    return default

def sum_regex(stats, patterns):
    s = 0.0
    hit = False
    for k, v in stats.items():
        for pat in patterns:
            if re.match(pat, k):
                if isinstance(v, float) and math.isfinite(v):
                    s += v
                    hit = True
    return (s if hit else float("nan"))

def safe_div(a, b, default=float("nan")):
    try:
        if b == 0:
            return default
        return a / b
    except Exception:
        return default

def read_exit(outdir: Path):
    ec = ""
    cause = "(missing)"
    p = outdir / "exit_code.txt"
    if p.is_file():
        ec = p.read_text(encoding="utf-8", errors="ignore").strip()
    p = outdir / "exit_cause.txt"
    if p.is_file():
        cause = p.read_text(encoding="utf-8", errors="ignore").strip() or "(unknown)"
    return ec, cause

def extract(stats):
    lookups = sum_regex(stats, [r"^system\.cpu\.branchPred\.(condLookups|lookups)_[0-9]+::total$"])
    if not (isinstance(lookups, float) and math.isfinite(lookups)):
        lookups = get_first(stats, [
            "system.cpu.branchPred.condLookups::total",
            "system.cpu.branchPred.lookups::total",
            "system.cpu.branchPred.condLookups",
            "system.cpu.branchPred.lookups",
            "system.cpu.branchPred.lookups_0::total",
            "system.cpu.branchPred.predicted::total",
            "system.cpu.branchPred.predicted",
        ], 0.0)

    misp = sum_regex(stats, [r"^system\.cpu\.(iew\.branchMispredicts|branchPred\.(condIncorrect|incorrect))_[0-9]+::total$"])
    if not (isinstance(misp, float) and math.isfinite(misp)):
        misp = get_first(stats, [
            "system.cpu.commit.branchMispredicts::total",
            "system.cpu.commit.branchMispredicts",
            "system.cpu.iew.branchMispredicts::total",
            "system.cpu.iew.branchMispredicts",
            "system.cpu.branchPred.condIncorrect::total",
            "system.cpu.branchPred.condIncorrect",
            "system.cpu.branchPred.incorrect::total",
            "system.cpu.branchPred.incorrect",
        ], 0.0)

    ipc = get_first(stats, ["system.cpu.ipc", "system.cpu.commit.ipc"], 0.0)

    num_cycles = get_first(stats, ["system.cpu.numCycles", "system.cpu.numCycles::total", "simTicks", "sim_ticks"], 0.0)

    insts = get_first(stats, [
        "system.cpu.commit.committedInsts",
        "system.cpu.commit.committedInsts::total",
        "system.cpu.committedInsts",
        "system.cpu.committedInsts::total",
        "system.cpu.numInsts",
        "system.cpu.numInsts::total",
        "system.cpu.commit.insts",
        "system.cpu.commit.insts::total",
        "simInsts",
        "sim_insts",
    ], 0.0)

    br_comm = get_first(stats, [
        "system.cpu.commit.branchInsts",
        "system.cpu.commit.branchInsts::total",
        "system.cpu.commit.branches",
        "system.cpu.commit.branches::total",
        "system.cpu.commit.controlInsts",
        "system.cpu.commit.controlInsts::total",
        "system.cpu.commit.committedBranches",
        "system.cpu.commit.committedBranches::total",
    ], float("nan"))

    squashed_insts = get_first(stats, [
        "system.cpu.iew.squashedInsts",
        "system.cpu.iew.squashedInsts::total",
        "system.cpu.fetch.squashedInsts",
        "system.cpu.fetch.squashedInsts::total",
    ], 0.0)

    squash_cycles = get_first(stats, [
        "system.cpu.fetch.squashCycles",
        "system.cpu.fetch.squashCycles::total",
        "system.cpu.iew.squashCycles",
        "system.cpu.iew.squashCycles::total",
    ], 0.0)

    mr = safe_div(misp, lookups)
    plr = (1.0 - safe_div(ipc, WIDTH, default=float("nan"))) if WIDTH > 0 else float("nan")
    bsf = safe_div(plr, mr) if (isinstance(mr, float) and math.isfinite(mr) and mr > 0.0) else float("nan")
    cpi = safe_div(num_cycles, insts) if insts > 0 else float("nan")

    if misp == 0:
        bp = 0.0
    else:
        ideal_cycles = safe_div(insts, WIDTH, default=0.0) if WIDTH > 0 else 0.0
        actual_stall = max(0.0, float(num_cycles) - float(ideal_cycles))
        bp = actual_stall / float(misp)

    br_cnt = br_comm if (isinstance(br_comm, float) and math.isfinite(br_comm) and br_comm >= 0.0) else lookups
    brki = safe_div(br_cnt * 1000.0, insts, default=0.0) if insts > 0 else 0.0
    mpki = safe_div(misp * 1000.0, insts, default=0.0) if insts > 0 else 0.0

    return dict(
        misp=int(misp), lookups=int(lookups), MR=mr, IPC=ipc, PLR=plr, BSF=bsf,
        num_cycles=int(num_cycles), commit_inst=int(insts), bp=bp,
        BrKI=brki, MPKI=mpki, CPI=cpi,
        br_comm=(int(br_comm) if (isinstance(br_comm, float) and math.isfinite(br_comm)) else -1),
        squashedInsts=int(squashed_insts), squashCycles=int(squash_cycles),
    )

legacy_header = ["program","bp_family","bp_level","width","pipe_scale",
                 "branch_misp","branch_lookups","MR","IPC","PLR","BSF",
                 "num_cycles","commit_inst","bp"]

ext_header = ["program","bp_family","bp_level","width","pipe_scale",
              "scale","threads","mem_size","cache",
              "exit_code","exit_cause",
              "misp","lookups","MR","IPC","PLR","BSF",
              "num_cycles","commit_inst","bp",
              "BrKI","MPKI","CPI","br_comm","squashedInsts","squashCycles"]

def write_csv(path: Path, header, rows):
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(header)
        for r in rows:
            w.writerow([r.get(h, "") for h in header])

for fam in BP_FAMILIES:
    legacy_rows = []
    ext_rows = []
    for prog in PROGRAMS:
        for lvl in BP_LEVELS:
            outdir = RESULT_DIR / prog / f"{fam}_L{lvl}"
            stats = parse_stats(outdir / "stats.txt")
            ec, cause = read_exit(outdir)
            m = extract(stats) if stats else dict(
                misp=0,lookups=0,MR=float("nan"),IPC=0.0,PLR=float("nan"),BSF=float("nan"),
                num_cycles=0,commit_inst=0,bp=0.0,BrKI=0.0,MPKI=0.0,CPI=float("nan"),
                br_comm=-1,squashedInsts=0,squashCycles=0
            )

            legacy_rows.append({
                "program": prog, "bp_family": fam, "bp_level": lvl,
                "width": WIDTH, "pipe_scale": PIPE_SCALE,
                "branch_misp": m["misp"], "branch_lookups": m["lookups"],
                "MR": m["MR"], "IPC": m["IPC"], "PLR": m["PLR"], "BSF": m["BSF"],
                "num_cycles": m["num_cycles"], "commit_inst": m["commit_inst"], "bp": m["bp"],
            })
            ext_rows.append({
                "program": prog, "bp_family": fam, "bp_level": lvl,
                "width": WIDTH, "pipe_scale": PIPE_SCALE,
                "scale": SCALE, "threads": THREADS, "mem_size": MEM_SIZE, "cache": CACHE,
                "exit_code": ec, "exit_cause": cause,
                **m
            })

    write_csv(RESULT_DIR / f"summary_{fam}.csv", legacy_header, legacy_rows)
    write_csv(RESULT_DIR / f"summary_ext_{fam}.csv", ext_header, ext_rows)
    print(f"[OK] wrote summary_{fam}.csv and summary_ext_{fam}.csv")

legacy_rows = []
ext_rows = []
for prog in PROGRAMS:
    for fam in BP_FAMILIES:
        for lvl in BP_LEVELS:
            outdir = RESULT_DIR / prog / f"{fam}_L{lvl}"
            stats = parse_stats(outdir / "stats.txt")
            ec, cause = read_exit(outdir)
            m = extract(stats) if stats else dict(
                misp=0,lookups=0,MR=float("nan"),IPC=0.0,PLR=float("nan"),BSF=float("nan"),
                num_cycles=0,commit_inst=0,bp=0.0,BrKI=0.0,MPKI=0.0,CPI=float("nan"),
                br_comm=-1,squashedInsts=0,squashCycles=0
            )

            legacy_rows.append({
                "program": prog, "bp_family": fam, "bp_level": lvl,
                "width": WIDTH, "pipe_scale": PIPE_SCALE,
                "branch_misp": m["misp"], "branch_lookups": m["lookups"],
                "MR": m["MR"], "IPC": m["IPC"], "PLR": m["PLR"], "BSF": m["BSF"],
                "num_cycles": m["num_cycles"], "commit_inst": m["commit_inst"], "bp": m["bp"],
            })
            ext_rows.append({
                "program": prog, "bp_family": fam, "bp_level": lvl,
                "width": WIDTH, "pipe_scale": PIPE_SCALE,
                "scale": SCALE, "threads": THREADS, "mem_size": MEM_SIZE, "cache": CACHE,
                "exit_code": ec, "exit_cause": cause,
                **m
            })

write_csv(RESULT_DIR / "summary_all.csv", legacy_header, legacy_rows)
write_csv(RESULT_DIR / "summary_ext_all.csv", ext_header, ext_rows)
print("[OK] wrote summary_all.csv and summary_ext_all.csv")
PY
}

echo "[INFO] GEM5_BINARY  : ${GEM5_BINARY}"
echo "[INFO] CONFIG_SCRIPT: ${CONFIG_SCRIPT}"
echo "[INFO] GAPBS_DIR    : ${GAPBS_DIR}"
echo "[INFO] RESULT_DIR   : ${RESULT_DIR}"
echo "[INFO] ARGS         : -g ${SCALE} -n ${THREADS}"
echo "[INFO] FIXED-POINT  : width=${WIDTH}, pipe_scale=${PIPE_SCALE}, cache=${CACHE}, mem=${MEM_SIZE}"
echo "[INFO] SWEEP        : families=(${BP_FAMILIES[*]}), levels=(${BP_LEVELS[*]})"
echo

write_manifest

if [[ "${ONLY_SUMMARY:-0}" != "1" ]]; then
  for prog in "${PROGRAMS[@]}"; do
    echo "=================================================="
    echo "[Program] ${prog}"
    echo "=================================================="
    for fam in "${BP_FAMILIES[@]}"; do
      for lvl in "${BP_LEVELS[@]}"; do
        echo "  [Run] ${fam} L${lvl} ..."
        run_one "${prog}" "${fam}" "${lvl}"
      done
    done
    echo
  done
fi

write_summaries
echo "[DONE] ${RESULT_DIR}"
