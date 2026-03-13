#!/bin/bash
# 对齐版：固定 width/pipe_scale，循环 bp_level 产生多个 MR 点，并记录 MR/IPC/PLR
# 修正：增加了容错处理，防止单点崩溃导致脚本中断

set -u
# 注意：去掉了 set -e，改用手动错误处理，防止 gem5 崩溃时直接退出脚本
set -o pipefail

# ============================================================================
# 0) 用户可改的路径参数
# ============================================================================
GEM5_PATH="/home/fao/gem5"
GEM5_BINARY="${GEM5_PATH}/build/RISCV/gem5.opt"

RISCV_PREFIX="riscv64-unknown-linux-gnu"
GCC="${RISCV_PREFIX}-gcc"

WORK_DIR="$(pwd)"
TEST_DIR="${WORK_DIR}/test_programs"
RESULT_DIR="${WORK_DIR}/results_bsf_curve"
CONFIG_DIR="${WORK_DIR}/configs"

mkdir -p "${TEST_DIR}" "${RESULT_DIR}" "${CONFIG_DIR}"

# ============================================================================
# 1) 固定微架构点（实验目的 1：固定 width、pipe_scale）
# ============================================================================
WIDTH=4
PIPE_SCALE=1.0
CACHE="true"

# ============================================================================
# 2) 预测器实验空间：同家族多档位 -> 多个 MR 点
# ============================================================================
BP_FAMILIES=("tournament" "local" "bimode")
BP_LEVELS=(0 1 2 3 4 5 6 7)

# ============================================================================
# 3) 从 stats.txt 提取指标，生成 summary.csv
# ============================================================================
extract_one_point () {
  local stats_file="$1"
  local program="$2"
  local bp_family="$3"
  local bp_level="$4"
  local width="$5"
  local pipe_scale="$6"

  # 【修正】如果 gem5 崩溃导致 stats.txt 不存在，输出 NaN 占位，避免 awk 报错
  if [[ ! -f "${stats_file}" ]]; then
    echo "${program},${bp_family},${bp_level},${width},${pipe_scale},0,0,nan,0,nan"
    return
  fi

  local misp
  local lookups
  local ipc

  misp="$(awk '
  $1=="system.cpu.iew.branchMispredicts" {print $2; exit}
' "${stats_file}")"

  lookups="$(awk '
  $1=="system.cpu.branchPred.lookups_0::total" {print $2; exit}
  $1=="system.cpu.branchPred.lookups::total" {print $2; exit}
  $1=="system.cpu.branchPred.lookups" {print $2; exit}
  $1=="system.cpu.branchPred.condLookups" {print $2; exit}
  $1=="system.cpu.branchPred.predicted" {print $2; exit}
' "${stats_file}")"

  if [[ -z "${lookups}" ]]; then lookups=0; fi

  ipc="$(awk '
  $1=="system.cpu.ipc" {print $2; exit}
  $1=="system.cpu.commit.ipc" {print $2; exit}
' "${stats_file}")"

  python3 - <<PY
program = r'''${program}'''
bp_family = r'''${bp_family}'''
bp_level = int(r'''${bp_level}''')
pipe_scale = float(r'''${pipe_scale}''')

try:
    misp = float(r'''${misp}''' or 0.0)
    lookups = float(r'''${lookups}''' or 0.0)
    ipc = float(r'''${ipc}''' or 0.0)
    width = float(r'''${width}''')

    mr = (misp / lookups) if lookups > 0 else float("nan")
    plr = 1.0 - (ipc / width) if width > 0 else float("nan")
except:
    mr = float("nan")
    plr = float("nan")
    misp = 0
    lookups = 0
    ipc = 0

print(f"{program},{bp_family},{bp_level},{width},{pipe_scale},{misp},{lookups},{mr},{ipc},{plr}")
PY
}

# ============================================================================
# 4) 编译测试程序
# ============================================================================
compile_test_programs() {
  if ! command -v ${GCC} &> /dev/null; then
    echo "ERROR: RISC-V compiler not found: ${GCC}"
    exit 1
  fi

  cat > "${TEST_DIR}/test_high_branch.c" << 'EOF'
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
  
            dummy++;
        } else {
            
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
  
            dummy--;
        }
    }
    printf("Done High\n");
    return 0;
}
EOF
  ${GCC} -O2 -static "${TEST_DIR}/test_high_branch.c" -o "${TEST_DIR}/test_high_branch"

  cat > "${TEST_DIR}/test_low_branch.c" << 'EOF'
#include <stdio.h>

#define ITERATIONS 1000000

int main() {
    volatile int dummy = 0;

    for (int i = 0; i < ITERATIONS; i++) {
        if (i % 2 == 0) {
            
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
  
            dummy++;
        } else {
            
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
  
            dummy--;
        }
    }
    printf("Done Low\n");
    return 0;
}
EOF
  ${GCC} -O2 -static "${TEST_DIR}/test_low_branch.c" -o "${TEST_DIR}/test_low_branch"
}

# ============================================================================
# 5) 运行一个点
# ============================================================================
run_one () {
  local binary="$1"
  local bp_family="$2"
  local bp_level="$3"
  local outdir="$4"

  mkdir -p "${outdir}"

  # 【修正】末尾添加 "|| true" 确保即使 gem5 崩溃，脚本也会继续执行后续循环
  # 同时将错误日志重定向，避免终端刷屏
  "${GEM5_BINARY}" \
      -d "${outdir}" \
      --stats-file="${outdir}/stats.txt" \
      "${CONFIG_DIR}/gem5_config.py" \
      "${binary}" \
      --bp-family "${bp_family}" \
      --bp-level "${bp_level}" \
      --cache "${CACHE}" \
      --width "${WIDTH}" \
      --pipe-scale "${PIPE_SCALE}" \
      > "${outdir}/sim.log" 2>&1

  local ret=$?
  if [ $ret -ne 0 ]; then
      echo "  [WARN] gem5 failed (code $ret) for ${bp_family} L${bp_level}. See ${outdir}/sim.log"
  fi
}

main () {
  if [ ! -f "${GEM5_BINARY}" ]; then
    echo "ERROR: gem5 not found at ${GEM5_BINARY}"
    exit 1
  fi

  compile_test_programs

  programs=("test_high_branch" "test_low_branch")

  # 对三种预测器家族分别生成一份 summary_{family}.csv
  for bp_family in "${BP_FAMILIES[@]}"; do
    summary_csv="${RESULT_DIR}/summary_${bp_family}.csv"
    echo "program,bp_family,bp_level,width,pipe_scale,branch_misp,branch_lookups,MR,IPC,PLR" > "${summary_csv}"

    for program in "${programs[@]}"; do
      binary="${TEST_DIR}/${program}"
      for lvl in "${BP_LEVELS[@]}"; do
        outdir="${RESULT_DIR}/${bp_family}/${program}/${bp_family}_L${lvl}_w${WIDTH}_ps${PIPE_SCALE}"
        echo "[run] ${bp_family}  ${program}  L${lvl}  (w=${WIDTH}, ps=${PIPE_SCALE})"
        
        run_one "${binary}" "${bp_family}" "${lvl}" "${outdir}"

        line="$(extract_one_point "${outdir}/stats.txt" "${program}" "${bp_family}" "${lvl}" "${WIDTH}" "${PIPE_SCALE}")"
        echo "${line}" >> "${summary_csv}"
      done
    done

    echo ""
    echo "Done. 已生成：${summary_csv}"
  done

  echo "全部完成。即使部分点失败，也不会阻塞后续任务。"
}

main "$@"
