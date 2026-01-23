#!/bin/bash
#===============================================================================
# Firewall Connectivity Check Tool v3.2
#===============================================================================
#
# 3단계 진단: [1] Network → [2] Host → [3] Port
# 병렬 실행 지원 (다중 노드 동시 테스트)
#
#===============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"

DEFAULT_TIMEOUT=2
DEFAULT_PING_COUNT=3
DEFAULT_OUTPUT_DIR="${PROJECT_DIR}/reports"
REMOTE_SCRIPT_PATH="/tmp/check_firewall_$$.sh"

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'
    GRAY=$'\033[0;90m'
    WHITE=$'\033[1;37m'
    DIM=$'\033[2m'
    NC=$'\033[0m'
    BOLD=$'\033[1m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' GRAY='' WHITE='' DIM='' NC='' BOLD=''
fi

#===============================================================================
# 시각화 함수
#===============================================================================

print_box() {
    local title="$1"
    local width=60
    echo ""
    printf "${CYAN}┏"; printf '━%.0s' $(seq 1 $width); printf "┓${NC}\n"
    printf "${CYAN}┃${NC} ${BOLD}${WHITE}%-$((width-2))s${NC} ${CYAN}┃${NC}\n" "$title"
    printf "${CYAN}┗"; printf '━%.0s' $(seq 1 $width); printf "┛${NC}\n"
}

print_section() {
    local title="$1"
    echo ""
    echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}${WHITE}  $title${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
}

print_result_icon() {
    case "$1" in
        PASS) echo -e "${GREEN}✓${NC}" ;;
        FAIL) echo -e "${RED}✗${NC}" ;;
        SKIP) echo -e "${GRAY}○${NC}" ;;
        RUN)  echo -e "${YELLOW}►${NC}" ;;
        WAIT) echo -e "${GRAY}◌${NC}" ;;
    esac
}

print_test_line() {
    local current=$1 total=$2 service=$3 target=$4 protocol=$5
    local nr=$6 hr=$7 pr=$8 result=$9
    
    local icon=$(print_result_icon "$result")
    local target_display="$target"
    [[ ${#target_display} -gt 25 ]] && target_display="${target_display:0:22}..."
    
    printf "  ${DIM}[%3d/%3d]${NC} %s %-12s ${DIM}→${NC} %-25s ${DIM}(%s)${NC}" \
        "$current" "$total" "$icon" "${service:0:12}" "$target_display" "$protocol"
    
    printf "  ${DIM}N:${NC}$(print_result_icon "$nr")"
    printf " ${DIM}H:${NC}$(print_result_icon "$hr")"
    [[ "$protocol" != "ICMP" ]] && printf " ${DIM}P:${NC}$(print_result_icon "$pr")"
    echo ""
}

print_summary_box() {
    local total=$1 pass=$2 fail=$3 rate=$4
    local net_p=$5 net_f=$6 host_p=$7 host_f=$8 port_p=$9 port_f=${10}
    
    echo ""
    echo -e "${CYAN}┌──────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}  ${BOLD}테스트 결과 요약${NC}                                            ${CYAN}│${NC}"
    echo -e "${CYAN}├──────────────────────────────────────────────────────────────┤${NC}"
    printf "${CYAN}│${NC}  총 테스트: ${WHITE}%-6d${NC}  ${GREEN}PASS: %-6d${NC}  ${RED}FAIL: %-6d${NC}  성공률: ${WHITE}%3d%%${NC}  ${CYAN}│${NC}\n" \
        "$total" "$pass" "$fail" "$rate"
    echo -e "${CYAN}├──────────────────────────────────────────────────────────────┤${NC}"
    printf "${CYAN}│${NC}  ${DIM}[1]${NC} Network: ${GREEN}%4d${NC}/${RED}%-4d${NC}  " "$net_p" "$net_f"
    printf "${DIM}[2]${NC} Host: ${GREEN}%4d${NC}/${RED}%-4d${NC}  " "$host_p" "$host_f"
    printf "${DIM}[3]${NC} Port: ${GREEN}%4d${NC}/${RED}%-4d${NC}  ${CYAN}│${NC}\n" "$port_p" "$port_f"
    echo -e "${CYAN}└──────────────────────────────────────────────────────────────┘${NC}"
}

print_failure_table() {
    local -n failures_ref=$1
    local count=${#failures_ref[@]}
    
    [[ $count -eq 0 ]] && return
    
    print_section "실패 목록 (${count}건)"
    echo ""
    for f in "${failures_ref[@]}"; do
        IFS='|' read -r svc src nip tgt proto layer <<< "$f"
        echo -e "  ${RED}✗${NC} ${WHITE}${svc}${NC} : ${src} : ${nip} ${DIM}->${NC} ${tgt} ${DIM}(${proto})${NC} : ${RED}${layer}${NC}"
    done
}

log_info()  { echo -e "  ${BLUE}ℹ${NC}  $1"; }
log_warn()  { echo -e "  ${YELLOW}⚠${NC}  $1"; }
log_error() { echo -e "  ${RED}✗${NC}  $1"; }
log_ok()    { echo -e "  ${GREEN}✓${NC}  $1"; }

usage() {
    cat << EOF
Usage: $(basename "$0") -i <csv> [-N <nodes>] [-I <ip>] [-t <timeout>] [-o <dir>] [-n]

옵션:
  -i  CSV 파일 (필수)
  -N  노드 목록 파일 (다중 노드 병렬 실행)
  -I  노드 IP 강제 지정
  -t  타임아웃 (기본: 2초)
  -o  출력 디렉토리
  -n  dry-run 모드
EOF
    exit 1
}

#===============================================================================
# 유틸리티 함수
#===============================================================================

ip_to_int() { 
    local a b c d
    IFS='.' read -r a b c d <<< "$1"
    echo $(( (a<<24)+(b<<16)+(c<<8)+d ))
}

ip_in_cidr() {
    local ip="$1" cidr="$2"
    [[ ! "$cidr" =~ / ]] && { [[ "$ip" == "$cidr" ]] && return 0 || return 1; }
    local network="${cidr%/*}" prefix="${cidr#*/}"
    local mask=$(( 0xFFFFFFFF << (32-prefix) & 0xFFFFFFFF ))
    [[ $(( $(ip_to_int "$ip") & mask )) -eq $(( $(ip_to_int "$network") & mask )) ]]
}

get_node_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || \
    ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || \
    echo "unknown"
}

parse_targets() { 
    echo "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'
}

validate_csv_header() {
    local header=$(head -1 "$1")
    [[ "$header" =~ ^SERVICE\|SOURCE\|TARGET ]] || { echo "Error: Invalid CSV header"; return 1; }
}

list_sources() { 
    awk -F'|' 'NR>1 && $2!="" {print "  - "$2}' "$1" | sort -u
}

count_tests() {
    local file="$1" node_ip="$2" count=0
    while IFS='|' read -r _ source target port protocol _; do
        # SOURCE 매칭 체크 제거 (정보성 필드로만 사용)
        protocol=$(echo "$protocol" | tr '[:lower:]' '[:upper:]' | xargs)
        local ips=$(echo "$target" | tr ',' '\n' | grep -c '[0-9]')
        if [[ "$protocol" == "ICMP" ]] || [[ -z "$protocol" ]]; then
            count=$((count + ips))
        else
            local ports=$(echo "$port" | tr ',' '\n' | grep -c '[0-9]')
            [[ $ports -eq 0 ]] && ports=1
            count=$((count + ips * ports))
        fi
    done < <(tail -n +2 "$file")
    echo "$count"
}

#===============================================================================
# 테스트 함수
#===============================================================================

test_network() {
    [[ "$2" == true ]] && { 
        [[ "$1" =~ ^(127\.|8\.8\.|10\.|192\.168\.) ]] && echo "PASS|ROUTE_OK" || echo "FAIL|NO_ROUTE"
        return
    }
    ip route get "$1" &>/dev/null && echo "PASS|ROUTE_OK" || echo "FAIL|NO_ROUTE"
}

test_host() {
    [[ "$3" == true ]] && { 
        [[ "$1" =~ ^(127\.|8\.8\.) ]] && echo "PASS|ICMP_OK" || echo "FAIL|ICMP_TIMEOUT"
        return
    }
    ping -c "$DEFAULT_PING_COUNT" -W "$2" "$1" &>/dev/null && echo "PASS|ICMP_OK" || echo "FAIL|ICMP_TIMEOUT"
}

test_port() {
    local target="$1" port="$2" proto="$3" timeout="$4" dry="$5"
    [[ "$dry" == true ]] && { 
        [[ "$target" =~ ^(127\.|8\.8\.) ]] && echo "PASS|PORT_OPEN" || echo "FAIL|PORT_CLOSED"
        return
    }
    case "$proto" in
        TCP) nc -z -w "$timeout" "$target" "$port" 2>/dev/null && echo "PASS|PORT_OPEN" || echo "FAIL|TCP_REFUSED" ;;
        UDP) nc -zu -w "$timeout" "$target" "$port" 2>/dev/null && echo "PASS|PORT_OPEN" || echo "FAIL|UDP_NO_RESP" ;;
        *) echo "SKIP|ICMP_MODE" ;;
    esac
}

#===============================================================================
# 단일 노드 테스트 (로컬 실행)
#===============================================================================

run_node_test() {
    local input="$1" node="$2" timeout="$3" outdir="$4" dry="$5" ts="$6"
    local quiet="${7:-false}"
    
    local report="${outdir}/report_${node}_${ts}.csv"
    local status_file="${outdir}/.status_${node}_${ts}.tmp"
    local total=0 pass=0 fail=0 current=0
    local net_p=0 net_f=0 host_p=0 host_f=0 port_p=0 port_f=0
    declare -A svc_pass svc_fail
    declare -a failures=()
    
    local expected=$(count_tests "$input" "$node")
    
    echo "RUNNING|0|$expected" > "$status_file"
    
    [[ "$quiet" != "true" ]] && {
        print_box "3단계 진단 - Node: $node"
        log_info "예상 테스트: ${expected}건"
        echo ""
    }
    
    echo "TIMESTAMP|SERVICE|SOURCE|NODE|TARGET|PORT|PROTOCOL|RESULT|FAIL_AT|NETWORK|HOST|PORT" > "$report"
    
    while IFS='|' read -r service source target port protocol _; do
        [[ -z "$service" ]] && continue
        
        port=$(echo "$port" | xargs)
        protocol=$(echo "$protocol" | tr '[:lower:]' '[:upper:]' | xargs)
        [[ -z "$protocol" ]] && protocol="ICMP"
        
        # SOURCE 매칭 체크 제거 - CSV의 모든 규칙 테스트
        
        while IFS= read -r tgt; do
            [[ -z "$tgt" ]] && continue
            
            if [[ "$protocol" == "ICMP" ]]; then
                ((total++)); ((current++))
                echo "RUNNING|$current|$expected" > "$status_file"
                
                IFS='|' read -r nr nrsn <<< "$(test_network "$tgt" "$dry")"
                [[ "$nr" == "PASS" ]] && ((net_p++)) || ((net_f++))
                
                local hr="SKIP" hrsn="NET_FAIL" pr="SKIP" prsn="NA" result="FAIL" fat="Network"
                
                if [[ "$nr" == "PASS" ]]; then
                    IFS='|' read -r hr hrsn <<< "$(test_host "$tgt" "$timeout" "$dry")"
                    [[ "$hr" == "PASS" ]] && { ((host_p++)); result="PASS"; fat=""; } || { ((host_f++)); fat="Host"; }
                fi
                
                [[ "$quiet" != "true" ]] && print_test_line "$current" "$expected" "$service" "$tgt" "$protocol" "$nr" "$hr" "$pr" "$result"
                
                local now=$(date '+%Y-%m-%d %H:%M:%S')
                echo "$now|$service|$source|$node|$tgt||$protocol|$result|$fat|$nr|$hr|$pr" >> "$report"
                
                if [[ "$result" == "PASS" ]]; then
                    ((pass++)); svc_pass[$service]=$((${svc_pass[$service]:-0}+1))
                else
                    ((fail++)); svc_fail[$service]=$((${svc_fail[$service]:-0}+1))
                    failures+=("$service|$source|$node|$tgt|$protocol|$fat")
                fi
            else
                while IFS= read -r prt; do
                    [[ -z "$prt" ]] && continue
                    ((total++)); ((current++))
                    echo "RUNNING|$current|$expected" > "$status_file"
                    
                    IFS='|' read -r nr nrsn <<< "$(test_network "$tgt" "$dry")"
                    [[ "$nr" == "PASS" ]] && ((net_p++)) || ((net_f++))
                    
                    local hr="SKIP" hrsn="NET_FAIL" pr="SKIP" prsn="NA" result="FAIL" fat="Network"
                    
                    if [[ "$nr" == "PASS" ]]; then
                        IFS='|' read -r hr hrsn <<< "$(test_host "$tgt" "$timeout" "$dry")"
                        if [[ "$hr" == "PASS" ]]; then
                            ((host_p++))
                            IFS='|' read -r pr prsn <<< "$(test_port "$tgt" "$prt" "$protocol" "$timeout" "$dry")"
                            [[ "$pr" == "PASS" ]] && { ((port_p++)); result="PASS"; fat=""; } || { ((port_f++)); fat="Port"; }
                        else
                            ((host_f++)); fat="Host"
                        fi
                    fi
                    
                    [[ "$quiet" != "true" ]] && print_test_line "$current" "$expected" "$service" "$tgt:$prt" "$protocol" "$nr" "$hr" "$pr" "$result"
                    
                    local now=$(date '+%Y-%m-%d %H:%M:%S')
                    echo "$now|$service|$source|$node|$tgt|$prt|$protocol|$result|$fat|$nr|$hr|$pr" >> "$report"
                    
                    if [[ "$result" == "PASS" ]]; then
                        ((pass++)); svc_pass[$service]=$((${svc_pass[$service]:-0}+1))
                    else
                        ((fail++)); svc_fail[$service]=$((${svc_fail[$service]:-0}+1))
                        failures+=("$service|$source|$node|$tgt:$prt|$protocol|$fat")
                    fi
                done < <(parse_targets "$port")
            fi
        done < <(parse_targets "$target")
    done < <(tail -n +2 "$input")
    
    local rate=0
    [[ $total -gt 0 ]] && rate=$((pass*100/total))
    
    echo "DONE|$pass|$fail|$rate" > "$status_file"
    echo "$node|$total|$pass|$fail|$rate" > "${outdir}/.result_${node}_${ts}.tmp"
    
    [[ "$quiet" != "true" ]] && {
        print_summary_box "$total" "$pass" "$fail" "$rate" "$net_p" "$net_f" "$host_p" "$host_f" "$port_p" "$port_f"
        print_failure_table failures
        echo ""
        log_info "결과 파일: $report"
    }
}

#===============================================================================
# 병렬 실행 - 다중 노드
#===============================================================================

check_ssh_access() {
    local node="$1"
    ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "$node" "echo OK" &>/dev/null
}

deploy_to_node() {
    local node="$1" input="$2" outdir="$3"
    local remote_csv="/tmp/firewall_check_$$.csv"
    local remote_outdir="/tmp/firewall_reports_$$"
    
    scp -q -o StrictHostKeyChecking=no "$SCRIPT_PATH" "${node}:${REMOTE_SCRIPT_PATH}" && \
    scp -q -o StrictHostKeyChecking=no "$input" "${node}:${remote_csv}" && \
    ssh -o StrictHostKeyChecking=no "$node" "chmod +x ${REMOTE_SCRIPT_PATH}; mkdir -p ${remote_outdir}"
}

run_on_remote_node() {
    local node="$1" timeout="$2" outdir="$3" ts="$4"
    local remote_csv="/tmp/firewall_check_$$.csv"
    local remote_outdir="/tmp/firewall_reports_$$"
    local status_file="${outdir}/.status_${node}_${ts}.tmp"
    
    echo "RUNNING|0|0" > "$status_file"
    
    ssh -o StrictHostKeyChecking=no "$node" \
        "${REMOTE_SCRIPT_PATH} -i ${remote_csv} -I ${node} -t ${timeout} -o ${remote_outdir} -q" >/dev/null 2>&1
    
    scp -q -o StrictHostKeyChecking=no "${node}:${remote_outdir}/*" "${outdir}/" 2>/dev/null || true
    
    local remote_result=$(ssh -o StrictHostKeyChecking=no "$node" \
        "cat ${remote_outdir}/.result_*_*.tmp 2>/dev/null || echo '$node|0|0|0|0'")
    echo "$remote_result" > "${outdir}/.result_${node}_${ts}.tmp"
    
    IFS='|' read -r _ _ rp rf rr <<< "$remote_result"
    echo "DONE|${rp:-0}|${rf:-0}|${rr:-0}" > "$status_file"
    
    ssh -o StrictHostKeyChecking=no "$node" "rm -rf ${REMOTE_SCRIPT_PATH} ${remote_csv} ${remote_outdir}" 2>/dev/null || true
}

monitor_progress() {
    local outdir="$1" ts="$2" total_nodes="$3"
    shift 3
    local nodes=("$@")
    
    echo ""
    while true; do
        local all_done=true
        local line=""
        
        for node in "${nodes[@]}"; do
            local sf="${outdir}/.status_${node}_${ts}.tmp"
            local status="WAIT" current=0 expected=0 pass=0 fail=0 rate=0
            
            if [[ -f "$sf" ]]; then
                IFS='|' read -r status p1 p2 p3 < "$sf"
                if [[ "$status" == "RUNNING" ]]; then
                    current=$p1; expected=$p2
                    all_done=false
                elif [[ "$status" == "DONE" ]]; then
                    pass=$p1; fail=$p2; rate=$p3
                fi
            else
                all_done=false
            fi
            
            local short_node="${node: -12}"
            if [[ "$status" == "DONE" ]]; then
                line+="  ${GREEN}✓${NC} ${short_node} ${DIM}(${pass}/${fail})${NC}"
            elif [[ "$status" == "RUNNING" ]]; then
                local pct=0
                [[ $expected -gt 0 ]] && pct=$((current * 100 / expected))
                line+="  ${YELLOW}►${NC} ${short_node} ${DIM}(${pct}%)${NC}"
            else
                line+="  ${GRAY}◌${NC} ${short_node}"
            fi
        done
        
        printf "\r%-100s" "$line"
        
        $all_done && break
        sleep 1
    done
    echo ""
}

run_multi_parallel() {
    local input="$1" nfile="$2" timeout="$3" outdir="$4" dry="$5" ts="$6"
    local nodes=()
    local accessible_nodes=()
    local failed_nodes=()
    local my_ip=$(get_node_ip)
    local pids=()
    
    while IFS= read -r n; do
        n=$(echo "$n" | xargs | grep -v '^#')
        [[ -n "$n" ]] && nodes+=("$n")
    done < "$nfile"
    
    print_section "1단계: 노드 목록"
    log_info "컨트롤플레인: $my_ip"
    log_info "대상 노드: ${#nodes[@]}개"
    for n in "${nodes[@]}"; do
        [[ "$n" == "$my_ip" ]] && echo -e "    ${GREEN}●${NC} $n ${DIM}(local)${NC}" || echo -e "    ${BLUE}●${NC} $n ${DIM}(remote)${NC}"
    done
    
    print_section "2단계: SSH 접근 확인"
    for n in "${nodes[@]}"; do
        printf "    %-20s " "$n"
        if [[ "$n" == "$my_ip" ]]; then
            echo -e "${GREEN}✓${NC} local"
            accessible_nodes+=("$n")
        elif [[ "$dry" == true ]]; then
            echo -e "${GREEN}✓${NC} dry-run"
            accessible_nodes+=("$n")
        elif check_ssh_access "$n"; then
            echo -e "${GREEN}✓${NC} OK"
            accessible_nodes+=("$n")
        else
            echo -e "${RED}✗${NC} FAIL"
            failed_nodes+=("$n")
        fi
    done
    
    if [[ ${#failed_nodes[@]} -gt 0 ]]; then
        echo ""
        log_warn "SSH 접근 불가 노드: ${#failed_nodes[@]}개"
        for fn in "${failed_nodes[@]}"; do
            echo -e "    ${RED}✗${NC} $fn"
            echo "$fn|0|0|0|0" > "${outdir}/.result_${fn}_${ts}.tmp"
        done
    fi
    
    [[ ${#accessible_nodes[@]} -eq 0 ]] && {
        log_error "접근 가능한 노드가 없습니다"
        exit 1
    }
    
    print_section "3단계: 파일 배포"
    for n in "${accessible_nodes[@]}"; do
        printf "    %-20s " "$n"
        if [[ "$n" == "$my_ip" ]] || [[ "$dry" == true ]]; then
            echo -e "${GREEN}✓${NC} skip (local/dry)"
        elif deploy_to_node "$n" "$input" "$outdir"; then
            echo -e "${GREEN}✓${NC} OK"
        else
            echo -e "${RED}✗${NC} FAIL"
        fi
    done
    
    print_section "4단계: 병렬 테스트 실행"
    log_info "모든 노드에서 동시 실행 중..."
    
    for n in "${accessible_nodes[@]}"; do
        echo "WAIT|0|0" > "${outdir}/.status_${n}_${ts}.tmp"
    done
    
    for n in "${accessible_nodes[@]}"; do
        if [[ "$n" == "$my_ip" ]] || [[ "$dry" == true ]]; then
            run_node_test "$input" "$n" "$timeout" "$outdir" "$dry" "$ts" "true" &
            pids+=($!)
        else
            run_on_remote_node "$n" "$timeout" "$outdir" "$ts" &
            pids+=($!)
        fi
    done
    
    monitor_progress "$outdir" "$ts" "${#accessible_nodes[@]}" "${accessible_nodes[@]}"
    
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    
    print_section "5단계: 결과 집계"
    
    local tt=0 tp=0 tf=0
    
    echo ""
    echo -e "${CYAN}┌──────────────────┬──────────┬──────────┬──────────┬──────────┐${NC}"
    echo -e "${CYAN}│${NC} ${BOLD}NODE${NC}             ${CYAN}│${NC} ${BOLD}TESTS${NC}    ${CYAN}│${NC} ${BOLD}PASS${NC}     ${CYAN}│${NC} ${BOLD}FAIL${NC}     ${CYAN}│${NC} ${BOLD}RATE${NC}     ${CYAN}│${NC}"
    echo -e "${CYAN}├──────────────────┼──────────┼──────────┼──────────┼──────────┤${NC}"
    
    for n in "${nodes[@]}"; do
        local rf="${outdir}/.result_${n}_${ts}.tmp"
        if [[ -f "$rf" ]]; then
            IFS='|' read -r _ nt np nf nr < "$rf"
            tt=$((tt+nt)); tp=$((tp+np)); tf=$((tf+nf))
            
            local status_icon="${GREEN}✓${NC}"
            [[ $nf -gt 0 ]] && status_icon="${YELLOW}!${NC}"
            [[ $nt -eq 0 ]] && status_icon="${RED}✗${NC}"
            
            printf "${CYAN}│${NC} %b %-14s ${CYAN}│${NC} %8s ${CYAN}│${NC} ${GREEN}%8s${NC} ${CYAN}│${NC} ${RED}%8s${NC} ${CYAN}│${NC} %7s%% ${CYAN}│${NC}\n" \
                "$status_icon" "${n:0:14}" "$nt" "$np" "$nf" "$nr"
        fi
    done
    
    echo -e "${CYAN}├──────────────────┼──────────┼──────────┼──────────┼──────────┤${NC}"
    local or=0
    [[ $tt -gt 0 ]] && or=$((tp*100/tt))
    printf "${CYAN}│${NC}   ${BOLD}%-14s${NC} ${CYAN}│${NC} ${BOLD}%8s${NC} ${CYAN}│${NC} ${GREEN}${BOLD}%8s${NC} ${CYAN}│${NC} ${RED}${BOLD}%8s${NC} ${CYAN}│${NC} ${BOLD}%7s%%${NC} ${CYAN}│${NC}\n" \
        "TOTAL" "$tt" "$tp" "$tf" "$or"
    echo -e "${CYAN}└──────────────────┴──────────┴──────────┴──────────┴──────────┘${NC}"
    
    for n in "${nodes[@]}"; do
        rm -f "${outdir}/.status_${n}_${ts}.tmp" "${outdir}/.result_${n}_${ts}.tmp"
    done
    
    local agg="${outdir}/summary_${ts}.txt"
    cat << EOF > "$agg"
================================================================================
 방화벽 3단계 진단 - 전체 집계
================================================================================
 실행시각: $(date '+%Y-%m-%d %H:%M:%S')
 컨트롤플레인: $my_ip
 대상노드: ${#nodes[@]}개 (성공: ${#accessible_nodes[@]}, 실패: ${#failed_nodes[@]})
--------------------------------------------------------------------------------
 총 테스트: $tt | PASS: $tp | FAIL: $tf | 성공률: ${or}%
================================================================================
EOF
    echo ""
    log_info "집계 파일: $agg"
    log_info "개별 리포트: ${outdir}/report_*_${ts}.csv"
}

#===============================================================================
# 메인
#===============================================================================

INPUT="" NODES="" TIMEOUT="$DEFAULT_TIMEOUT" OUTDIR="$DEFAULT_OUTPUT_DIR" DRY=false FORCE_IP="" QUIET=false

while getopts "i:N:I:t:o:nqh" opt; do
    case $opt in
        i) INPUT="$OPTARG";;
        N) NODES="$OPTARG";;
        I) FORCE_IP="$OPTARG";;
        t) TIMEOUT="$OPTARG";;
        o) OUTDIR="$OPTARG";;
        n) DRY=true;;
        q) QUIET=true;;
        h) usage;;
        *) usage;;
    esac
done

[[ -z "$INPUT" ]] && { echo "Error: -i required"; usage; }
[[ ! -f "$INPUT" ]] && { echo "Error: $INPUT not found"; exit 1; }
validate_csv_header "$INPUT" || exit 1
[[ -n "$NODES" && ! -f "$NODES" ]] && { echo "Error: $NODES not found"; exit 1; }

mkdir -p "$OUTDIR"
TS=$(date '+%Y%m%d_%H%M%S')

[[ "$QUIET" != "true" ]] && {
    print_box "방화벽 3단계 진단 v3.2"
    log_info "입력: $INPUT"
    log_info "진단: [1]Network → [2]Host → [3]Port"
    [[ "$DRY" == true ]] && log_warn "DRY-RUN 모드"
}

if [[ -n "$NODES" ]]; then
    run_multi_parallel "$INPUT" "$NODES" "$TIMEOUT" "$OUTDIR" "$DRY" "$TS"
else
    if [[ -n "$FORCE_IP" ]]; then
        NIP="$FORCE_IP"
        [[ "$QUIET" != "true" ]] && log_info "지정 노드: $NIP"
    else
        NIP=$(get_node_ip)
        [[ "$QUIET" != "true" ]] && log_info "현재 노드: $NIP"
    fi
    
    run_node_test "$INPUT" "$NIP" "$TIMEOUT" "$OUTDIR" "$DRY" "$TS" "$QUIET"
fi

echo ""
exit 0
