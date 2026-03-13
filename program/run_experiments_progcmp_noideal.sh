#!/bin/bash
set -u
set -o pipefail

# =============================================================================
# Layer-C / RQ3 实验脚本（改进版）
#   - 固定结构点：WIDTH / PIPE_SCALE / CACHE 对所有程序一致
#   - 跨程序对比：输出每个程序的 MR / PLR / BSF（以及 BrKI / MPKI 解释指标）
#   - 预测器 sweep：每个家族仅 2 个 level（默认 L0 & L7），用于跨程序对比（减少总仿真次数）
#   - benchmark 数量增加：生成更多“不同规格（分支密度 × 可预测性 × 相关性）”微基准
#
# 输出（RESULT_DIR 下）：
#   1) summary_<bp_family>.csv               每个家族一份（长表）：program × level 的 MR/PLR/BSF/BrKI/MPKI
#   2) program_features.csv                  每个程序的 ILP_upper_bound (=WIDTH) 与 BrKI_base（用于解释）
#   3) program_compare_wide.csv              一行一个程序（宽表）：各预测器配置的 MR/PLR/BSF/MPKI（便于跨程序对比）
#   4) program_sensitivity.csv               每个程序拟合的 BSF_slope（可选解释用）
#
# 运行前提：
#   - 已 build RISCV/gem5.opt
#   - 有 RISC-V 交叉编译器（默认 riscv64-unknown-linux-gnu-gcc）
# =============================================================================

# -----------------------------
# 路径配置（可用环境变量覆盖）
# -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}"

GEM5_PATH="${GEM5_PATH:-/home/fao/gem5}"
GEM5_BINARY="${GEM5_BINARY:-${GEM5_PATH}/build/RISCV/gem5.opt}"

# 配置脚本：优先使用环境变量；否则在当前目录自动探测
if [[ -z "${CONFIG_SCRIPT:-}" ]]; then
  if [[ -f "${WORK_DIR}/gem5_config.py" ]]; then
    CONFIG_SCRIPT="${WORK_DIR}/gem5_config.py"
  elif [[ -f "${WORK_DIR}/gem5_config .py" ]]; then
    # 兼容：文件名里意外带空格的情况（如 "gem5_config .py"）
    CONFIG_SCRIPT="${WORK_DIR}/gem5_config .py"
  elif [[ -f "${WORK_DIR}/gem5_config (3).py" ]]; then
    CONFIG_SCRIPT="${WORK_DIR}/gem5_config (3).py"
  else
    CONFIG_SCRIPT="${WORK_DIR}/gem5_config.py"
  fi
fi

RISCV_PREFIX="${RISCV_PREFIX:-riscv64-unknown-linux-gnu}"
GCC="${GCC:-${RISCV_PREFIX}-gcc}"

TEST_DIR="${WORK_DIR}/test_programs"
RESULT_DIR="${WORK_DIR}/results_fixedpoint"

mkdir -p "${TEST_DIR}" "${RESULT_DIR}"

# -----------------------------
# 固定结构点（可通过环境变量覆盖）
# -----------------------------
WIDTH="${WIDTH:-4}"
PIPE_SCALE="${PIPE_SCALE:-1.0}"
CACHE="${CACHE:-false}"   # 建议主实验先 false，减少访存噪声

# -----------------------------
# 预测器 sweep：每家族 2 个 level（默认弱/强）
# 可用 BP_LEVELS_OVERRIDE="0 5" 之类覆盖
# -----------------------------
BP_FAMILIES=("tournament" "local" "bimode")

if [[ -n "${BP_LEVELS_OVERRIDE:-}" ]]; then
  # e.g. BP_LEVELS_OVERRIDE="0 7"
  read -r -a BP_LEVELS <<< "${BP_LEVELS_OVERRIDE}"
else
  BP_LEVELS=(1 3 5 7)
fi

# =============================================================================
# 统计项提取（尽量对不同 gem5 版本鲁棒）
# =============================================================================

get_first_match () {
    local stats_file="$1"; shift
    local keys=("$@")
    local k
    for k in "${keys[@]}"; do
        val="$(awk -v key="${k}" '$1==key {print $2; exit}' "${stats_file}" 2>/dev/null || true)"
        if [[ -n "${val}" ]]; then
            echo "${val}"
            return
        fi
    done
    echo ""
}

get_ipc () {
    local stats_file="$1"
    get_first_match "${stats_file}" \
        "system.cpu.ipc" \
        "system.cpu.commit.ipc"
}

get_committed_insts () {
    local stats_file="$1"
    get_first_match "${stats_file}" \
        "system.cpu.commit.committedInsts" \
        "system.cpu.commit.committedInsts::total" \
        "system.cpu.numInsts" \
        "system.cpu.committedInsts" \
        "system.cpu.commit.insts" \
        "system.cpu.commit.insts::total" \
        "sim_insts"
}

get_committed_branches () {
    # 尽量从 commit 阶段拿“已提交的分支指令数”，这样 BrKI 更接近程序本身的控制流特征。
    # 不同 gem5 版本字段命名不一：如果拿不到就返回空，后续用 predictor lookups 兜底。
    local stats_file="$1"
    get_first_match "${stats_file}" \
        "system.cpu.commit.branchInsts" \
        "system.cpu.commit.branchInsts::total" \
        "system.cpu.commit.branches" \
        "system.cpu.commit.branches::total" \
        "system.cpu.commit.controlInsts" \
        "system.cpu.commit.controlInsts::total" \
        "system.cpu.commit.committedBranches" \
        "system.cpu.commit.committedBranches::total"
}

sum_matches () {
    # 用于不同 gem5 版本下“每线程统计项”的求和兜底
    # pattern 为 awk 正则（匹配第一列 key）
    local stats_file="$1"
    local pattern="$2"
    awk -v pat="${pattern}" '$1 ~ pat {s += $2} END {if (s > 0) printf("%.0f\n", s)}' "${stats_file}" 2>/dev/null || true
}

get_branch_lookups () {
    local stats_file="$1"

    # 1) 优先：把 lookups_<tid>::total 全部加起来（更鲁棒）
    local v
    v="$(sum_matches "${stats_file}" '^system\\.cpu\\.branchPred\\.(condLookups|lookups)_[0-9]+::total$')"
    if [[ -n "${v}" ]]; then
        echo "${v}"
        return
    fi

    # 2) 退化：直接拿 total / 单值
    get_first_match "${stats_file}" \
        "system.cpu.branchPred.condLookups::total" \
        "system.cpu.branchPred.lookups::total" \
        "system.cpu.branchPred.condLookups" \
        "system.cpu.branchPred.lookups" \
        "system.cpu.branchPred.lookups_0::total"
}

get_branch_misp () {
    local stats_file="$1"

    # 1) 兼容“每线程”分支误预测计数
    local v
    v="$(sum_matches "${stats_file}" '^system\\.cpu\\.(iew\\.branchMispredicts|branchPred\\.(condIncorrect|incorrect))_[0-9]+::total$')"
    if [[ -n "${v}" ]]; then
        echo "${v}"
        return
    fi

    # 2) 常见 key（不同版本略有差异）
    get_first_match "${stats_file}" \
        "system.cpu.iew.branchMispredicts::total" \
        "system.cpu.iew.branchMispredicts" \
        "system.cpu.branchPred.condIncorrect::total" \
        "system.cpu.branchPred.condIncorrect" \
        "system.cpu.branchPred.incorrect::total" \
        "system.cpu.branchPred.incorrect"
}

# =============================================================================
# 仿真运行
# =============================================================================

run_sim () {
    local bin="$1"
    local fam="$2"
    local lvl="$3"
    local out="$4"

    mkdir -p "${out}"

    "${GEM5_BINARY}" \
        -d "${out}" \
        --stats-file="${out}/stats.txt" \
        "${CONFIG_SCRIPT}" \
        "${bin}" \
        --bp-family "${fam}" \
        --bp-level "${lvl}" \
        --cache "${CACHE}" \
        --width "${WIDTH}" \
        --pipe-scale "${PIPE_SCALE}" \
        > "${out}/sim.log" 2>&1 || true
}

# =============================================================================
# 计算 MR / PLR / BSF + BrKI / MPKI（Python 计算，避免 bash 浮点陷阱）
#   重要变更（为匹配论文“固定结构点下跨程序比较 BSF”的目标）：
#   - 不再跑 ideal predictor 作为 ILP_ideal（减少仿真次数，也避免 ideal 统计项不一致）
#   - 将 ILP_upper_bound 直接设为 WIDTH（即该结构点的理论上界 IPC≈WIDTH）
#   - 因此：PLR = (WIDTH - IPC_actual) / WIDTH
#           BSF = PLR / MR
# =============================================================================

extract_and_calc () {
  local stats_file="$1"
  local program="$2"
  local bp_family="$3"
  local bp_level="$4"

  if [[ ! -f "${stats_file}" ]]; then return; fi

  local insts misp lookups br_comm ipc
  insts="$(get_committed_insts "${stats_file}")"
  misp="$(get_branch_misp "${stats_file}")"
  lookups="$(get_branch_lookups "${stats_file}")"
  br_comm="$(get_committed_branches "${stats_file}")"
  ipc="$(get_ipc "${stats_file}")"

  [[ -z "${insts}" ]] && insts=0
  [[ -z "${misp}" ]] && misp=0
  [[ -z "${lookups}" ]] && lookups=0
  [[ -z "${br_comm}" ]] && br_comm=-1
  [[ -z "${ipc}" ]] && ipc=0

  python3 - <<PY
p = "${program}"
fam = "${bp_family}"
lvl = "${bp_level}"

insts = float("${insts}")
misp = float("${misp}")
lookups = float("${lookups}")
ipc = float("${ipc}")
ilp_ub = float("${WIDTH}")

mr = (misp / lookups) if lookups > 0 else 0.0
brki = (lookups / insts * 1000.0) if insts > 0 else 0.0   # branches per kilo inst (proxy)

# 尽量使用 commit 阶段分支数（更“程序特征”），拿不到再用 lookups 近似
br_comm = float("${br_comm}")
br_cnt = br_comm if br_comm >= 0 else lookups
brki = (br_cnt / insts * 1000.0) if insts > 0 else 0.0
mpki = (misp / insts * 1000.0) if insts > 0 else 0.0      # mispred per kilo inst

plr = ((ilp_ub - ipc) / ilp_ub) if ilp_ub > 0 else 0.0
bsf = (plr / mr) if mr > 1e-12 else 0.0

print(f"{p},{fam},{lvl},{insts:.0f},{misp:.0f},{lookups:.0f},{mr:.6f},{brki:.3f},{mpki:.3f},{ipc:.4f},{ilp_ub:.4f},{plr:.6f},{bsf:.6f}")
PY
}

# =============================================================================
# 编译：更多“不同规格”的控制流微基准
#   维度：
#     - 分支密度：dense(ASM_PAD32) vs sparse(ASM_PAD256)
#     - 可预测性：random / alternating / biased / loop-exit
#     - 分支相关性：corr（第二个分支完全依赖第一个分支结果 -> global history 受益）
# =============================================================================

compile_test_programs() {
    if ! command -v "${GCC}" &> /dev/null; then
        echo "[ERROR] RISC-V GCC not found: ${GCC}"
        exit 1
    fi

    echo "[Build] Compiling microbenchmarks (expanded set)..."

    # 32 条无依赖指令（填充，降低分支密度，提升 ILP）
    ASM_PAD32='asm volatile(\
        "add x0, x0, x0\n\t""add x0, x0, x0\n\t""add x0, x0, x0\n\t""add x0, x0, x0\n\t"\
        "add x0, x0, x0\n\t""add x0, x0, x0\n\t""add x0, x0, x0\n\t""add x0, x0, x0\n\t"\
        "add x0, x0, x0\n\t""add x0, x0, x0\n\t""add x0, x0, x0\n\t""add x0, x0, x0\n\t"\
        "add x0, x0, x0\n\t""add x0, x0, x0\n\t""add x0, x0, x0\n\t""add x0, x0, x0\n\t"\
        "add x0, x0, x0\n\t""add x0, x0, x0\n\t""add x0, x0, x0\n\t""add x0, x0, x0\n\t"\
        "add x0, x0, x0\n\t""add x0, x0, x0\n\t""add x0, x0, x0\n\t""add x0, x0, x0\n\t"\
        "add x0, x0, x0\n\t""add x0, x0, x0\n\t""add x0, x0, x0\n\t""add x0, x0, x0\n\t"\
        "add x0, x0, x0\n\t""add x0, x0, x0\n\t""add x0, x0, x0\n\t""add x0, x0, x0\n\t"\
        ::: "memory");'

    # 256 条无依赖指令（8×PAD32）：更低分支密度
    ASM_PAD256="${ASM_PAD32} ${ASM_PAD32} ${ASM_PAD32} ${ASM_PAD32} ${ASM_PAD32} ${ASM_PAD32} ${ASM_PAD32} ${ASM_PAD32}"

    # -----------------------------
    # 1) Dense + Random（高分支密度、难预测）
    # -----------------------------
    cat > "${TEST_DIR}/br_dense_random.c" <<EOF
#include <stdio.h>
#include <stdint.h>

#define ITER 1000000

static inline uint16_t lfsr_step(uint16_t x) {
    unsigned bit = ((x >> 0) ^ (x >> 2) ^ (x >> 3) ^ (x >> 5)) & 1u;
    return (x >> 1) | (bit << 15);
}

int main() {
    uint16_t lfsr = 0xACE1u;
    volatile int dummy = 0;

    for (int i = 0; i < ITER; i++) {
        lfsr = lfsr_step(lfsr);
        if (lfsr & 1u) {
            ${ASM_PAD32}
            dummy++;
        } else {
            ${ASM_PAD32}
            dummy--;
        }
    }
    printf("dense_random %d\\n", dummy);
    return 0;
}
EOF

    # -----------------------------
    # 2) Sparse + Random（低分支密度、难预测）
    # -----------------------------
    cat > "${TEST_DIR}/br_sparse_random.c" <<EOF
#include <stdio.h>
#include <stdint.h>

#define ITER 200000

static inline uint16_t lfsr_step(uint16_t x) {
    unsigned bit = ((x >> 0) ^ (x >> 2) ^ (x >> 3) ^ (x >> 5)) & 1u;
    return (x >> 1) | (bit << 15);
}

int main() {
    uint16_t lfsr = 0xACE1u;
    volatile int dummy = 0;

    for (int i = 0; i < ITER; i++) {
        lfsr = lfsr_step(lfsr);
        if (lfsr & 1u) {
            ${ASM_PAD256}
            dummy++;
        } else {
            ${ASM_PAD256}
            dummy--;
        }
    }
    printf("sparse_random %d\\n", dummy);
    return 0;
}
EOF

    # -----------------------------
    # 3) Dense + Alternating（分支密度高、模式强：对纯 bimodal 不友好，对有 history 的更友好）
    # -----------------------------
    cat > "${TEST_DIR}/br_dense_alternating.c" <<EOF
#include <stdio.h>

#define ITER 1000000

int main() {
    volatile int dummy = 0;

    for (int i = 0; i < ITER; i++) {
        // T,N,T,N... 交替：需要 history 才能学得好
        if (i & 1) {
            ${ASM_PAD32}
            dummy++;
        } else {
            ${ASM_PAD32}
            dummy--;
        }
    }
    printf("dense_alternating %d\\n", dummy);
    return 0;
}
EOF

    # -----------------------------
    # 4) Sparse + Alternating（低分支密度、交替模式）
    # -----------------------------
    cat > "${TEST_DIR}/br_sparse_alternating.c" <<EOF
#include <stdio.h>

#define ITER 200000

int main() {
    volatile int dummy = 0;

    for (int i = 0; i < ITER; i++) {
        if (i & 1) {
            ${ASM_PAD256}
            dummy++;
        } else {
            ${ASM_PAD256}
            dummy--;
        }
    }
    printf("sparse_alternating %d\\n", dummy);
    return 0;
}
EOF

    # -----------------------------
    # 5) Dense + Biased Random（高密度、强偏置但“事件点”随机）
    #    分支 taken 概率约 15/16，适合观察“低 MR 但仍有恢复开销”的情况
    # -----------------------------
    cat > "${TEST_DIR}/br_dense_biased.c" <<EOF
#include <stdio.h>
#include <stdint.h>

#define ITER 1000000

static inline uint16_t lfsr_step(uint16_t x) {
    unsigned bit = ((x >> 0) ^ (x >> 2) ^ (x >> 3) ^ (x >> 5)) & 1u;
    return (x >> 1) | (bit << 15);
}

int main() {
    uint16_t lfsr = 0xBEEF;
    volatile int dummy = 0;

    for (int i = 0; i < ITER; i++) {
        lfsr = lfsr_step(lfsr);

        // 偏置：仅当低 4 bit 全 0 时走“反方向”
        if ((lfsr & 0xFu) != 0u) {
            ${ASM_PAD32}
            dummy += 1;
        } else {
            ${ASM_PAD32}
            dummy -= 1;
        }
    }
    printf("dense_biased %d\\n", dummy);
    return 0;
}
EOF

    # -----------------------------
    # 6) Sparse + Biased Random（低密度、偏置随机）
    # -----------------------------
    cat > "${TEST_DIR}/br_sparse_biased.c" <<EOF
#include <stdio.h>
#include <stdint.h>

#define ITER 200000

static inline uint16_t lfsr_step(uint16_t x) {
    unsigned bit = ((x >> 0) ^ (x >> 2) ^ (x >> 3) ^ (x >> 5)) & 1u;
    return (x >> 1) | (bit << 15);
}

int main() {
    uint16_t lfsr = 0xBEEF;
    volatile int dummy = 0;

    for (int i = 0; i < ITER; i++) {
        lfsr = lfsr_step(lfsr);

        if ((lfsr & 0xFu) != 0u) {
            ${ASM_PAD256}
            dummy += 1;
        } else {
            ${ASM_PAD256}
            dummy -= 1;
        }
    }
    printf("sparse_biased %d\\n", dummy);
    return 0;
}
EOF

    # -----------------------------
    # 7) Dense + Correlated branches（两条分支：第二条完全由第一条决定）
    #    目的：让 global-history 更可能收益（local 仅看自身历史 -> 第二条近似随机）
    # -----------------------------
    cat > "${TEST_DIR}/br_dense_corr.c" <<EOF
#include <stdio.h>
#include <stdint.h>

#define ITER 500000

static inline uint16_t lfsr_step(uint16_t x) {
    unsigned bit = ((x >> 0) ^ (x >> 2) ^ (x >> 3) ^ (x >> 5)) & 1u;
    return (x >> 1) | (bit << 15);
}

int main() {
    uint16_t lfsr = 0xCAFE;
    volatile int dummy = 0;

    for (int i = 0; i < ITER; i++) {
        lfsr = lfsr_step(lfsr);
        int b1 = (lfsr & 1u);

        // Branch #1：随机
        if (b1) {
            ${ASM_PAD32}
            dummy += 1;
        } else {
            ${ASM_PAD32}
            dummy -= 1;
        }

        // Branch #2：完全相关（== b1）
        if (b1) {
            ${ASM_PAD32}
            dummy += 2;
        } else {
            ${ASM_PAD32}
            dummy -= 2;
        }
    }

    printf("dense_corr %d\\n", dummy);
    return 0;
}
EOF

    # -----------------------------
    # 8) Sparse + Correlated branches
    # -----------------------------
    cat > "${TEST_DIR}/br_sparse_corr.c" <<EOF
#include <stdio.h>
#include <stdint.h>

#define ITER 100000

static inline uint16_t lfsr_step(uint16_t x) {
    unsigned bit = ((x >> 0) ^ (x >> 2) ^ (x >> 3) ^ (x >> 5)) & 1u;
    return (x >> 1) | (bit << 15);
}

int main() {
    uint16_t lfsr = 0xCAFE;
    volatile int dummy = 0;

    for (int i = 0; i < ITER; i++) {
        lfsr = lfsr_step(lfsr);
        int b1 = (lfsr & 1u);

        if (b1) {
            ${ASM_PAD256}
            dummy += 1;
        } else {
            ${ASM_PAD256}
            dummy -= 1;
        }

        if (b1) {
            ${ASM_PAD256}
            dummy += 2;
        } else {
            ${ASM_PAD256}
            dummy -= 2;
        }
    }

    printf("sparse_corr %d\\n", dummy);
    return 0;
}
EOF

    # -----------------------------
    # 9) Dense + Loop-exit（几乎完美可预测：每个内层循环只有 1 次“退出”事件）
    # -----------------------------
    cat > "${TEST_DIR}/br_dense_loop.c" <<EOF
#include <stdio.h>

#define OUTER 2000
#define INNER 200

int main() {
    volatile int dummy = 0;

    for (int o = 0; o < OUTER; o++) {
        int j = 0;
        while (j < INNER) {
            ${ASM_PAD32}
            dummy += (j & 1);
            j++;
        }
        dummy += j;
    }

    printf("dense_loop %d\\n", dummy);
    return 0;
}
EOF

    # -----------------------------
    # 10) Sparse + Loop-exit
    # -----------------------------
    cat > "${TEST_DIR}/br_sparse_loop.c" <<EOF
#include <stdio.h>

#define OUTER 800
#define INNER 200

int main() {
    volatile int dummy = 0;

    for (int o = 0; o < OUTER; o++) {
        int j = 0;
        while (j < INNER) {
            ${ASM_PAD256}
            dummy += (j & 1);
            j++;
        }
        dummy += j;
    }

    printf("sparse_loop %d\\n", dummy);
    return 0;
}
EOF

    # 编译（static 更稳定）
    "${GCC}" -O2 -static "${TEST_DIR}/br_dense_random.c"       -o "${TEST_DIR}/br_dense_random"
    "${GCC}" -O2 -static "${TEST_DIR}/br_sparse_random.c"      -o "${TEST_DIR}/br_sparse_random"
    "${GCC}" -O2 -static "${TEST_DIR}/br_dense_alternating.c"  -o "${TEST_DIR}/br_dense_alternating"
    "${GCC}" -O2 -static "${TEST_DIR}/br_sparse_alternating.c" -o "${TEST_DIR}/br_sparse_alternating"
    "${GCC}" -O2 -static "${TEST_DIR}/br_dense_biased.c"       -o "${TEST_DIR}/br_dense_biased"
    "${GCC}" -O2 -static "${TEST_DIR}/br_sparse_biased.c"      -o "${TEST_DIR}/br_sparse_biased"
    "${GCC}" -O2 -static "${TEST_DIR}/br_dense_corr.c"         -o "${TEST_DIR}/br_dense_corr"
    "${GCC}" -O2 -static "${TEST_DIR}/br_sparse_corr.c"        -o "${TEST_DIR}/br_sparse_corr"
    "${GCC}" -O2 -static "${TEST_DIR}/br_dense_loop.c"         -o "${TEST_DIR}/br_dense_loop"
    "${GCC}" -O2 -static "${TEST_DIR}/br_sparse_loop.c"        -o "${TEST_DIR}/br_sparse_loop"

    echo "[Build] Done."
}

# =============================================================================
# 主流程
# =============================================================================

main () {
    if [[ ! -f "${GEM5_BINARY}" ]]; then
        echo "[ERROR] gem5 binary not found: ${GEM5_BINARY}"
        exit 1
    fi
    if [[ ! -f "${CONFIG_SCRIPT}" ]]; then
        echo "[ERROR] config script not found: ${CONFIG_SCRIPT}"
        exit 1
    fi

    compile_test_programs

    # 默认：expanded microbench set（你也可以用 PROGRAMS_OVERRIDE 覆盖成自己的程序列表）
    if [[ -n "${PROGRAMS_OVERRIDE:-}" ]]; then
        # e.g. PROGRAMS_OVERRIDE="foo bar baz"（此时 binary 路径需要你自己保证）
        read -r -a programs <<< "${PROGRAMS_OVERRIDE}"
        USE_TEST_DIR="${USE_TEST_DIR:-false}"
    else
        programs=(
            "br_dense_random"
            "br_sparse_random"
            "br_dense_alternating"
            "br_sparse_alternating"
            "br_dense_biased"
            "br_sparse_biased"
            "br_dense_corr"
            "br_sparse_corr"
            "br_dense_loop"
            "br_sparse_loop"
        )
        USE_TEST_DIR="true"
    fi

    # 程序说明（写到结果目录，方便你在论文里引用“控制流特征分组”）
    catalog_md="${RESULT_DIR}/program_catalog.md"
    cat > "${catalog_md}" <<'MD'
# Microbench Program Catalog (Control-Flow Features)

本目录下的 10 个微基准用于在 **固定结构点** 下做“跨程序 BSF 对比”，并用分支密度/MPKI 解释差异。

| program | branch density | predictability | history / correlation | what it stresses |
|---|---|---|---|---|
| br_dense_random | high | hard (pseudo-random) | low | 高 MR + 高频分支，考察恢复开销在高密度分支下的放大效应 |
| br_sparse_random | low | hard (pseudo-random) | low | 低分支密度但难预测，考察“稀疏但致命”的误预测影响 |
| br_dense_alternating | high | medium (T/N alternating) | high | 交替模式对 history 更友好；对纯 bimodal 更不友好 |
| br_sparse_alternating | low | medium (T/N alternating) | high | 同上，但通过插入更多非分支指令降低分支密度 |
| br_dense_biased | high | easy (strongly biased) | low | 低 MR 场景：看 MR 很小但 BSF 仍可能不小（因为每次错代价高） |
| br_sparse_biased | low | easy (strongly biased) | low | 同上，但让误预测事件更“稀疏” |
| br_dense_corr | high | mixed | high (2nd depends on 1st) | 两分支相关：global-history 受益更明显，用于区分 local vs tournament |
| br_sparse_corr | low | mixed | high (2nd depends on 1st) | 同上，但降低分支密度 |
| br_dense_loop | high | easy (loop-exit) | low | 几乎完美可预测：用于对照（MR≈0，BSF 计算需注意数值稳定） |
| br_sparse_loop | low | easy (loop-exit) | low | 同上，但降低分支密度 |

说明：dense/sparse 通过插入不同数量的无依赖指令（PAD32 vs PAD256）改变 **每 1k 指令的分支次数（BrKI）**。
MD

    # 每个家族一个 summary（长表）
    for fam in "${BP_FAMILIES[@]}"; do
        summary_csv="${RESULT_DIR}/summary_${fam}.csv"
        echo "program,bp_family,bp_level,insts,misp,lookups,MR,BrKI,MPKI,IPC_actual,ILP_ideal,PLR,BSF" > "${summary_csv}"
    done

    for program in "${programs[@]}"; do
        if [[ "${USE_TEST_DIR}" == "true" ]]; then
            binary="${TEST_DIR}/${program}"
        else
            binary="${program}"
        fi

        echo "=================================================="
        echo "[Program] ${program}"
        echo "  fixed-point: width=${WIDTH}, pipe_scale=${PIPE_SCALE}, cache=${CACHE}"
        echo "  predictor levels per family: ${BP_LEVELS[*]}"
        echo "=================================================="

        # ---------- Predictor sweep（每家族 2 个 level） ----------
        for fam in "${BP_FAMILIES[@]}"; do
            summary_csv="${RESULT_DIR}/summary_${fam}.csv"
            for lvl in "${BP_LEVELS[@]}"; do
                echo "    [Run] ${fam} L${lvl}..."
                outdir="${RESULT_DIR}/${program}/${fam}_L${lvl}"
                run_sim "${binary}" "${fam}" "${lvl}" "${outdir}"

                line="$(extract_and_calc "${outdir}/stats.txt" "${program}" "${fam}" "${lvl}")"
                if [[ -n "${line}" ]]; then
                    echo "${line}" >> "${summary_csv}"
                fi
            done
        done
    done

    # =============================================================================
    # 后处理：生成更适合“跨程序对比”的宽表 + （可选）BSF_slope
    # =============================================================================
    RESULT_DIR="${RESULT_DIR}" WIDTH="${WIDTH}" PIPE_SCALE="${PIPE_SCALE}" CACHE="${CACHE}" python3 - <<'PY'
import csv, glob, math, os
from collections import defaultdict

result_dir = os.environ.get("RESULT_DIR", os.path.join(os.getcwd(), "results_fixedpoint"))
width = float(os.environ.get("WIDTH", "0") or "0")
pipe_scale = os.environ.get("PIPE_SCALE", "")
cache = os.environ.get("CACHE", "")

# 1) load all summary_*.csv
metrics = {}   # (program, fam, lvl) -> row dict
programs = set()
configs = set()

for path in glob.glob(os.path.join(result_dir, "summary_*.csv")):
    with open(path, newline="") as f:
        r = csv.DictReader(f)
        for row in r:
            p = row.get("program","")
            fam = row.get("bp_family","")
            try:
                lvl = int(row.get("bp_level","0"))
            except Exception:
                lvl = 0
            if not p or not fam:
                continue
            key = (p, fam, lvl)
            metrics[key] = row
            programs.add(p)
            configs.add((fam, lvl))

# stable order
fam_order = {"tournament": 0, "local": 1, "bimode": 2}
configs = sorted(list(configs), key=lambda x: (fam_order.get(x[0], 99), x[0], x[1]))
programs = sorted(list(programs))

# 2) 选择 baseline 点（用于程序级特征：BrKI/MPKI/MR/IPC）
#    默认：优先 tournament L0；如果不存在则取 tournament 最小 level；再不行取全局最小 level。
baseline = {}
by_program = defaultdict(list)
for (p, fam, lvl), row in metrics.items():
    by_program[p].append((fam, lvl, row))

def pick_baseline(p):
    pts = by_program.get(p, [])
    if not pts:
        return None
    # 1) tournament L0
    for fam, lvl, row in pts:
        if fam == "tournament" and lvl == 0:
            return row
    # 2) tournament min lvl
    tpts = [(lvl, row) for fam, lvl, row in pts if fam == "tournament"]
    if tpts:
        return min(tpts, key=lambda x: x[0])[1]
    # 3) global min lvl
    return min(pts, key=lambda x: x[1])[2]

for p in programs:
    baseline[p] = pick_baseline(p) or {}

# 3) program_features.csv（便于你写“程序敏感性/控制流解释”）
feat_path = os.path.join(result_dir, "program_features.csv")
with open(feat_path, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=[
        "program","width","pipe_scale","cache","ILP_ideal",
        "brki_base","mpki_base","mr_base","ipc_base"
    ])
    w.writeheader()
    for p in programs:
        b = baseline.get(p, {})
        def g(k):
            return b.get(k, "")
        w.writerow({
            "program": p,
            "width": str(int(width)) if width else os.environ.get("WIDTH", ""),
            "pipe_scale": pipe_scale,
            "cache": cache,
            "ILP_ideal": str(width) if width else "",
            "brki_base": g("BrKI"),
            "mpki_base": g("MPKI"),
            "mr_base": g("MR"),
            "ipc_base": g("IPC_actual"),
        })

# 4) wide compare table（主用：跨程序对比）
wide_path = os.path.join(result_dir, "program_compare_wide.csv")
fieldnames = [
    "program","width","pipe_scale","cache","ILP_ideal","brki_base","mpki_base","mr_base","ipc_base"
]
for fam, lvl in configs:
    prefix = f"{fam}_L{lvl}"
    fieldnames += [f"{prefix}_MR", f"{prefix}_PLR", f"{prefix}_BSF", f"{prefix}_MPKI"]

with open(wide_path, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=fieldnames)
    w.writeheader()

    for p in programs:
        b = baseline.get(p, {})
        row_out = {
            "program": p,
            "width": str(int(width)) if width else os.environ.get("WIDTH", ""),
            "pipe_scale": pipe_scale,
            "cache": cache,
            "ILP_ideal": str(width) if width else "",
            "brki_base": b.get("BrKI", ""),
            "mpki_base": b.get("MPKI", ""),
            "mr_base": b.get("MR", ""),
            "ipc_base": b.get("IPC_actual", ""),
        }
        for fam, lvl in configs:
            prefix = f"{fam}_L{lvl}"
            r = metrics.get((p, fam, lvl), {})
            row_out[f"{prefix}_MR"] = r.get("MR", "")
            row_out[f"{prefix}_PLR"] = r.get("PLR", "")
            row_out[f"{prefix}_BSF"] = r.get("BSF", "")
            row_out[f"{prefix}_MPKI"] = r.get("MPKI", "")
        w.writerow(row_out)

# 5) program_sensitivity.csv：用所有点做过原点拟合（PLR = slope * MR）
#    说明：现在每家族只有 2 个 level，总点数少；该结果主要用于“趋势/解释”，
#          你做跨程序对比更建议用 program_compare_wide.csv 里的 BSF_point。
points = defaultdict(list)

for (p, fam, lvl), row in metrics.items():
    try:
        mr = float(row.get("MR", "0"))
        plr = float(row.get("PLR", "0"))
        mpki = float(row.get("MPKI", "0"))
        brki = float(row.get("BrKI", "0"))
    except Exception:
        continue

    # 保守过滤：MR=0 会导致数值不稳；放宽阈值以免强预测器点被完全丢掉
    if mr < 1e-6 or mr > 0.95 or plr < 0.0 or plr > 2.0:
        continue

    points[p].append((mr, plr, mpki, brki, fam, lvl))

def fit_slope_origin(xy):
    sxx = 0.0
    sxy = 0.0
    xs, ys = [], []
    for x, y in xy:
        sxx += x*x
        sxy += x*y
        xs.append(x); ys.append(y)
    if sxx <= 0:
        return float("nan"), float("nan")
    slope = sxy / sxx
    ymean = sum(ys)/len(ys) if ys else 0.0
    sst = sum((y-ymean)**2 for y in ys)
    sse = sum((y - slope*x)**2 for x, y in zip(xs, ys))
    r2 = 1.0 - (sse/sst) if sst > 0 else float("nan")
    return slope, r2

rows_out = []
for p, pts in sorted(points.items()):
    xy = [(mr, plr) for (mr, plr, mpki, brki, fam, lvl) in pts]
    slope, r2 = fit_slope_origin(xy)

    # baseline 特征（用于解释）：优先 tournament L0
    b = baseline.get(p, {})
    try:
        mpki_base = float(b.get("MPKI", "nan"))
    except Exception:
        mpki_base = float("nan")
    try:
        mr_base = float(b.get("MR", "nan"))
    except Exception:
        mr_base = float("nan")
    try:
        brki_base = float(b.get("BrKI", "nan"))
    except Exception:
        brki_base = float("nan")

    rows_out.append({
        "program": p,
        "brki_base": f"{brki_base:.3f}" if not math.isnan(brki_base) else "",
        "mpki_base": f"{mpki_base:.3f}" if not math.isnan(mpki_base) else "",
        "mr_base": f"{mr_base:.6f}" if not math.isnan(mr_base) else "",
        "bsf_slope": f"{slope:.6f}" if not math.isnan(slope) else "",
        "fit_r2": f"{r2:.4f}" if not math.isnan(r2) else "",
        "n_points": str(len(xy)),
    })

out_path = os.path.join(result_dir, "program_sensitivity.csv")
with open(out_path, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=[
        "program","brki_base","mpki_base","mr_base","bsf_slope","fit_r2","n_points"
    ])
    w.writeheader()
    w.writerows(rows_out)

print("")
print("==================================================")
print("[Post] Cross-program compare tables generated:")
print("  - program_compare_wide.csv      (主用：跨程序对比 MR/PLR/BSF)")
print("  - program_sensitivity.csv       (可选：BSF_slope 趋势)")
print("==================================================")
PY

    echo ""
    echo "[Done] Results in: ${RESULT_DIR}"
    echo "  - program_compare_wide.csv: recommended for cross-program comparisons (MR/PLR/BSF)"
}

main "$@"
