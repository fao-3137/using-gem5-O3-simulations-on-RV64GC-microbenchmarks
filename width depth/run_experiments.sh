#!/bin/bash
set -u
set -o pipefail

# ============================================================================
# 路径配置
# ============================================================================
GEM5_PATH="/home/fao/gem5"
GEM5_BINARY="${GEM5_PATH}/build/RISCV/gem5.opt"
RISCV_PREFIX="riscv64-unknown-linux-gnu"
GCC="${RISCV_PREFIX}-gcc"

WORK_DIR="$(pwd)"
TEST_DIR="${WORK_DIR}/test_programs"
RESULT_DIR="${WORK_DIR}/results_bsf_struct_sweep"   # 第二部分：结构敏感性 sweep
CONFIG_DIR="${WORK_DIR}/configs"
CONFIG_FILE="${CONFIG_DIR}/gem5_config.py"

mkdir -p "${TEST_DIR}" "${RESULT_DIR}" "${CONFIG_DIR}"

# 若你把 gem5_config.py 放在工程根目录，则自动拷贝到 configs/ 下（保持你原结构）
if [[ -f "${WORK_DIR}/gem5_config.py" ]]; then
  cp -f "${WORK_DIR}/gem5_config.py" "${CONFIG_FILE}"
fi
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: ${CONFIG_FILE} not found. Put gem5_config.py into ./configs/ or project root."
  exit 1
fi

# ============================================================================
# 实验参数：固定预测器档位，sweep width 与 pipe_scale
# ============================================================================
# 主实验建议先关 cache（更干净）；如要开：export CACHE=true 再运行
CACHE="${CACHE:-false}"

# width sweep（典型：2/4/8）
WIDTH_LIST=(2 4 8)

# pipe_scale sweep（典型：1/2/3，作为“流水深度/恢复开销”的代理变量）
PIPE_SCALE_LIST=(1 2 3)

# 固定预测器档位（每个条目就是“固定档位”）
# 你可以改 level，比如 L2/L3/L5 看趋势是否一致
FIXED_PREDICTORS=(
  "tournament:4"
  "bimode:4"
  "local:4"
)

# 第二部分：选一个“分支密度高且难预测”的程序看结构敏感性
PROGRAMS=("test_high_branch")

# ============================================================================
# 通用：从 stats.txt 抽取某个统计项（按 key 列表依次尝试）
# ============================================================================
get_stat_value() {
  local stats_file="$1"; shift
  local key
  for key in "$@"; do
    local v
    v="$(awk -v k="${key}" '$1==k {print $2; exit}' "${stats_file}")"
    if [[ -n "${v}" ]]; then
      echo "${v}"
      return
    fi
  done
  echo ""
}

# ============================================================================
# IPC 提取：优先用 gem5 自带 ipc 统计，否则后处理里用 inst/cycle 兜底
# ============================================================================
get_ipc() {
  local stats_file="$1"
  if [[ ! -f "${stats_file}" ]]; then echo ""; return; fi

  local ipc
  ipc="$(get_stat_value "${stats_file}" \
    "system.cpu.ipc" \
    "system.cpu.commit.ipc")"
  echo "${ipc}"
}

# ============================================================================
# 提取数据并计算 MR/PLR/BSF + 分支惩罚（BP proxy）
# 输出一行 CSV
# ============================================================================
extract_and_calc () {
  local stats_file="$1"
  local program="$2"
  local width="$3"
  local pipe_scale="$4"
  local bp_family="$5"
  local bp_level="$6"
  local ipc_ideal="$7"
  local cache_flag="$8"

  if [[ ! -f "${stats_file}" ]]; then return; fi

  # 1) 基本分支统计
  local misp lookups
  misp="$(get_stat_value "${stats_file}" \
    "system.cpu.iew.branchMispredicts" \
    "system.cpu.iew.branchMispredicts::total" \
    "system.cpu.iew.branchMispredicts_0::total")"

  lookups="$(get_stat_value "${stats_file}" \
    "system.cpu.branchPred.lookups_0::total" \
    "system.cpu.branchPred.lookups::total" \
    "system.cpu.branchPred.lookups" \
    "system.cpu.branchPred.condLookups")"

  # 2) IPC / cycles / insts（用于兜底计算）
  local ipc cycles insts
  ipc="$(get_ipc "${stats_file}")"
  cycles="$(get_stat_value "${stats_file}" \
    "system.cpu.numCycles" \
    "system.cpu.cycles" \
    "system.cpu.numCycles::total")"

  insts="$(get_stat_value "${stats_file}" \
    "system.cpu.commit.committedInsts" \
    "system.cpu.committedInsts" \
    "system.cpu.numInsts")"

  # 3) 分支惩罚 proxy：squashCycles + branchStallCycles（不同版本名字可能略不同）
  local squash_cycles branch_stall_cycles squashed_insts
  squash_cycles="$(get_stat_value "${stats_file}" \
    "system.cpu.fetch.squashCycles" \
    "system.cpu.fetch.squashCycles::total" \
    "system.cpu.fetch.squashCycles_0::total")"

  branch_stall_cycles="$(get_stat_value "${stats_file}" \
    "system.cpu.fetch.branchStallCycles" \
    "system.cpu.fetch.branchStallCycles::total" \
    "system.cpu.fetch.branchStallCycles_0::total")"

  squashed_insts="$(get_stat_value "${stats_file}" \
    "system.cpu.commit.squashedInsts" \
    "system.cpu.commit.squashedInsts::total" \
    "system.cpu.iew.squashedInsts" \
    "system.cpu.rename.squashedInsts")"

  # 兜底默认值
  if [[ -z "${misp}" ]]; then misp=0; fi
  if [[ -z "${lookups}" ]]; then lookups=0; fi
  if [[ -z "${ipc}" ]]; then ipc=0; fi
  if [[ -z "${cycles}" ]]; then cycles=0; fi
  if [[ -z "${insts}" ]]; then insts=0; fi
  if [[ -z "${squash_cycles}" ]]; then squash_cycles=0; fi
  if [[ -z "${branch_stall_cycles}" ]]; then branch_stall_cycles=0; fi
  if [[ -z "${squashed_insts}" ]]; then squashed_insts=0; fi

  python3 - <<PY
try:
    program = "${program}"
    width = int("${width}")
    pipe_scale = float("${pipe_scale}")
    cache_flag = "${cache_flag}"
    fam = "${bp_family}"
    lvl = int("${bp_level}")

    misp = float("${misp}")
    lookups = float("${lookups}")

    ipc_raw = float("${ipc}")
    cycles = float("${cycles}")
    insts = float("${insts}")

    ipc_ideal = float("${ipc_ideal}")

    squash_cycles = float("${squash_cycles}")
    branch_stall_cycles = float("${branch_stall_cycles}")
    squashed_insts = float("${squashed_insts}")

    # IPC fallback
    ipc = ipc_raw
    if ipc <= 0.0 and cycles > 0.0:
        ipc = insts / cycles

    # MR
    mr = (misp / lookups) if lookups > 0 else 0.0

    # PLR（相对 ILP_ideal）
    if ipc_ideal > 0:
        plr = (ipc_ideal - ipc) / ipc_ideal
    else:
        plr = 0.0

    # BSF = PLR / MR
    bsf = (plr / mr) if mr > 1e-9 else 0.0

    # 分支惩罚 proxy：每次误预测导致的 front-end 丢失周期
    penalty_cycles = squash_cycles + branch_stall_cycles
    bp_cycles = (penalty_cycles / misp) if misp > 0 else 0.0

    # 额外：每次误预测被 squashed 的指令数
    squash_per_misp = (squashed_insts / misp) if misp > 0 else 0.0

    print(",".join([
        program,
        fam, str(lvl),
        str(width), f"{pipe_scale:.2f}",
        cache_flag,
        f"{misp:.0f}", f"{lookups:.0f}",
        f"{mr:.6f}",
        f"{ipc:.6f}", f"{ipc_ideal:.6f}",
        f"{plr:.6f}", f"{bsf:.6f}",
        f"{penalty_cycles:.0f}", f"{bp_cycles:.6f}",
        f"{squashed_insts:.0f}", f"{squash_per_misp:.6f}",
        f"{cycles:.0f}", f"{insts:.0f}",
    ]))
except Exception:
    pass
PY
}

# ============================================================================
# 运行单个仿真
# ============================================================================
run_sim () {
  local bin="$1"
  local fam="$2"
  local lvl="$3"
  local width="$4"
  local pipe_scale="$5"
  local out="$6"

  mkdir -p "${out}"
  "${GEM5_BINARY}" \
    -d "${out}" \
    --stats-file="${out}/stats.txt" \
    "${CONFIG_FILE}" \
    "${bin}" \
    --bp-family "${fam}" \
    --bp-level "${lvl}" \
    --cache "${CACHE}" \
    --width "${width}" \
    --pipe-scale "${pipe_scale}" \
    > "${out}/sim.log" 2>&1 || true
}

# ============================================================================
# 编译测试程序（沿用你原版：高分支/低分支）
# ============================================================================
compile_test_programs() {
  if ! command -v ${GCC} &> /dev/null; then
    echo "GCC not found: ${GCC}"
    exit 1
  fi

  echo "Compiling Assembly-Optimized test programs..."

  ASM_PADDING='
        asm volatile(
            "add x0, x0, x0\n\t" "add x0, x0, x0\n\t" "add x0, x0, x0\n\t" "add x0, x0, x0\n\t"
            "add x0, x0, x0\n\t" "add x0, x0, x0\n\t" "add x0, x0, x0\n\t" "add x0, x0, x0\n\t"
            "add x0, x0, x0\n\t" "add x0, x0, x0\n\t" "add x0, x0, x0\n\t" "add x0, x0, x0\n\t"
            "add x0, x0, x0\n\t" "add x0, x0, x0\n\t" "add x0, x0, x0\n\t" "add x0, x0, x0\n\t"
            "add x0, x0, x0\n\t" "add x0, x0, x0\n\t" "add x0, x0, x0\n\t" "add x0, x0, x0\n\t"
            "add x0, x0, x0\n\t" "add x0, x0, x0\n\t" "add x0, x0, x0\n\t" "add x0, x0, x0\n\t"
            "add x0, x0, x0\n\t" "add x0, x0, x0\n\t" "add x0, x0, x0\n\t" "add x0, x0, x0\n\t"
            "add x0, x0, x0\n\t" "add x0, x0, x0\n\t" "add x0, x0, x0\n\t" "add x0, x0, x0\n\t"
            ::: "memory"
        );
  '

  # 1) 难预测：LFSR 随机分支（结构敏感性主实验用）
  cat << EOF > "${TEST_DIR}/test_high_branch.c"
#include <stdio.h>
#include <stdint.h>

#define ITERATIONS 1000000

int main() {
    uint16_t lfsr = 0xACE1u;
    unsigned bit;
    volatile int dummy = 0;

    for (int i = 0; i < ITERATIONS; i++) {
        bit  = ((lfsr >> 0) ^ (lfsr >> 2) ^ (lfsr >> 3) ^ (lfsr >> 5)) & 1;
        lfsr =  (lfsr >> 1) | (bit << 15);

        if (lfsr & 1) {
            ${ASM_PADDING}
            dummy++;
        } else {
            ${ASM_PADDING}
            dummy--;
        }
    }
    printf("Done High\\n");
    return 0;
}
EOF

  # 2) 易预测：固定模式（保留，但第二部分默认不跑）
  cat << EOF > "${TEST_DIR}/test_low_branch.c"
#include <stdio.h>

#define ITERATIONS 1000000

int main() {
    volatile int dummy = 0;

    for (int i = 0; i < ITERATIONS; i++) {
        if (i % 2 == 0) {
            ${ASM_PADDING}
            dummy++;
        } else {
            ${ASM_PADDING}
            dummy--;
        }
    }
    printf("Done Low\\n");
    return 0;
}
EOF

  ${GCC} -O2 -static "${TEST_DIR}/test_high_branch.c" -o "${TEST_DIR}/test_high_branch"
  ${GCC} -O2 -static "${TEST_DIR}/test_low_branch.c" -o "${TEST_DIR}/test_low_branch"
}

# ============================================================================
# 主流程：固定预测器档位 -> sweep width/pipe_scale
# ============================================================================
main () {
  compile_test_programs

  local summary_csv="${RESULT_DIR}/summary_struct_sweep.csv"
  if [[ ! -f "${summary_csv}" ]]; then
    echo "program,bp_family,bp_level,width,pipe_scale,cache,misp,lookups,MR,IPC_actual,IPC_ideal,PLR,BSF,penalty_cycles,penalty_cycles_per_misp,squashed_insts,squash_insts_per_misp,cycles,committed_insts" > "${summary_csv}"
  fi

  for program in "${PROGRAMS[@]}"; do
    local binary="${TEST_DIR}/${program}"
    echo "=================================================="
    echo "[Program] ${program}"
    echo "=================================================="

    for w in "${WIDTH_LIST[@]}"; do
      for s in "${PIPE_SCALE_LIST[@]}"; do

        # 先跑 ideal（同一微架构点的 ILP_ideal）
        local uarch_tag="w${w}_s${s}"
        local ideal_out="${RESULT_DIR}/${program}/${uarch_tag}/ideal"

        if [[ ! -f "${ideal_out}/stats.txt" ]]; then
          echo "  [Ideal] ${uarch_tag} cache=${CACHE}"
          run_sim "${binary}" "ideal" "0" "${w}" "${s}" "${ideal_out}"
        fi

        local ipc_ideal
        ipc_ideal="$(get_ipc "${ideal_out}/stats.txt")"
        if [[ -z "${ipc_ideal}" ]]; then ipc_ideal=0; fi

        echo "  -> ILP_ideal IPC = ${ipc_ideal} (${uarch_tag})"

        # 固定预测器档位：扫结构参数
        for bp in "${FIXED_PREDICTORS[@]}"; do
          IFS=':' read -r bp_family bp_level <<< "${bp}"

          local outdir="${RESULT_DIR}/${program}/${uarch_tag}/${bp_family}_L${bp_level}"
          if [[ ! -f "${outdir}/stats.txt" ]]; then
            echo "    [Run] ${bp_family} L${bp_level} @ ${uarch_tag} cache=${CACHE}"
            run_sim "${binary}" "${bp_family}" "${bp_level}" "${w}" "${s}" "${outdir}"
          fi

          local line
          line="$(extract_and_calc "${outdir}/stats.txt" "${program}" "${w}" "${s}" "${bp_family}" "${bp_level}" "${ipc_ideal}" "${CACHE}")"
          if [[ -n "${line}" ]]; then
            echo "${line}" >> "${summary_csv}"
          fi
        done
      done
    done
  done

  echo ""
  echo "All Done."
  echo "  Results dir : ${RESULT_DIR}"
  echo "  Summary CSV : ${RESULT_DIR}/summary_struct_sweep.csv"
}

main "$@"

