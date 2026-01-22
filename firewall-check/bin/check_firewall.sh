#!/bin/bash
#
# Firewall Connectivity Check Tool
# 방화벽 오픈 대장 기반 연결 확인 테스트 도구
#
# Usage: check_firewall.sh -i <csv_file> -s <source_cluster> [-t <timeout>] [-o <output_dir>] [-n]
#
# 지원 프로토콜:
#   - TCP: 포트 연결 테스트 (nc -z)
#   - UDP: 포트 연결 테스트 (nc -zu, 신뢰성 제한적)
#   - ICMP: 호스트 도달 테스트 (ping)
#

set -uo pipefail

# ============================================================
# 기본 설정
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

DEFAULT_TIMEOUT=2
DEFAULT_PING_COUNT=5
DEFAULT_OUTPUT_DIR="${PROJECT_DIR}/reports"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# ============================================================
# 로깅 함수
# ============================================================
log_info()     { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success()  { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail()     { echo -e "${RED}[FAIL]${NC} $1"; }
log_warn()     { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_progress() { echo -e "${CYAN}[${1}/${2}]${NC} ${3}"; }

log_header() {
    echo ""
    echo "============================================================"
    echo " $1"
    echo "============================================================"
}

# ============================================================
# 도움말
# ============================================================
usage() {
    cat << EOF
Usage: $(basename "$0") -i <csv_file> -s <source_cluster> [-t <timeout>] [-o <output_dir>] [-n]

필수 옵션:
    -i <csv_file>       방화벽 오픈 대장 CSV 파일 경로
    -s <source_cluster> 현재 클러스터 이름 (SOURCE 필터링용)

선택 옵션:
    -t <timeout>        연결 타임아웃 초 (기본: ${DEFAULT_TIMEOUT})
    -o <output_dir>     결과 저장 디렉토리 (기본: ${DEFAULT_OUTPUT_DIR})
    -n                  dry-run 모드 (실제 테스트 없이 시뮬레이션)
    -h                  도움말 출력

CSV 형식 (구분자: |):
    SERVICE|SOURCE|TARGET|PORT|PROTOCOL|요청일자|요청자|처리일자|처리자
    - TARGET: 단일 IP 또는 쉼표로 구분된 IP 리스트
    - PORT: 단일 또는 쉼표로 구분된 PORT 리스트
    - PROTOCOL: TCP, UDP, ICMP (대소문자 무관)

예시:
    $(basename "$0") -i /path/to/firewall.csv -s ic-dataops-dev -t 3
    $(basename "$0") -i firewall.csv -s ic-dataops-dev -n  # dry-run
EOF
    exit 1
}

# ============================================================
# CSV 파싱 함수
# ============================================================
parse_targets() {
    local target_str="$1"
    echo "$target_str" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'
}

validate_csv_header() {
    local file="$1"
    local header
    header=$(head -1 "$file")
    
    if [[ ! "$header" =~ ^SERVICE\|SOURCE\|TARGET ]]; then
        echo "Error: CSV 헤더 형식이 올바르지 않습니다."
        echo "  Expected: SERVICE|SOURCE|TARGET|PORT|PROTOCOL|..."
        echo "  Got: $header"
        return 1
    fi
    return 0
}

list_available_sources() {
    local file="$1"
    awk -F'|' 'NR>1 && $2!="" {print "  - "$2}' "$file" | sort -u
}

# 테스트 항목 수 미리 계산
count_total_tests() {
    local file="$1"
    local source_filter="$2"
    local count=0
    
    while IFS='|' read -r service source target port protocol _rest; do
        source=$(echo "$source" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ "$source" != "$source_filter" ]] && continue
        
        protocol=$(echo "$protocol" | tr '[:lower:]' '[:upper:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        local ip_count=$(echo "$target" | tr ',' '\n' | grep -c '[0-9]')
        
        if [[ "$protocol" == "ICMP" ]] || [[ -z "$protocol" ]]; then
            count=$((count + ip_count))
        else
            local port_count=$(echo "$port" | tr ',' '\n' | grep -c '[0-9]')
            [[ $port_count -eq 0 ]] && port_count=1
            count=$((count + ip_count * port_count))
        fi
    done < <(tail -n +2 "$file")
    
    echo "$count"
}

# ============================================================
# 연결 테스트 함수
# ============================================================
test_connectivity() {
    local target="$1"
    local port="$2"
    local protocol="$3"
    local timeout="$4"
    
    protocol=$(echo "$protocol" | tr '[:lower:]' '[:upper:]')
    
    if [[ "$DRY_RUN" == true ]]; then
        if [[ "$target" =~ ^127\. ]] || [[ "$target" =~ ^8\.8\. ]]; then
            echo "PASS|OK"
        else
            case "$protocol" in
                TCP)  echo "FAIL|TCP_CONNECTION_REFUSED" ;;
                UDP)  echo "FAIL|UDP_NO_RESPONSE" ;;
                *)    echo "FAIL|ICMP_TIMEOUT" ;;
            esac
        fi
        return
    fi
    
    case "$protocol" in
        TCP)
            if [[ -z "$port" ]]; then
                echo "FAIL|PORT_NOT_SPECIFIED"
                return
            fi
            if nc -z -w "$timeout" "$target" "$port" 2>/dev/null; then
                echo "PASS|OK"
            else
                echo "FAIL|TCP_CONNECTION_FAILED"
            fi
            ;;
        UDP)
            if [[ -z "$port" ]]; then
                echo "FAIL|PORT_NOT_SPECIFIED"
                return
            fi
            if nc -zu -w "$timeout" "$target" "$port" 2>/dev/null; then
                echo "PASS|OK"
            else
                echo "FAIL|UDP_NO_RESPONSE"
            fi
            ;;
        ICMP|"")
            if ping -c "$DEFAULT_PING_COUNT" -W "$timeout" "$target" > /dev/null 2>&1; then
                echo "PASS|OK"
            else
                echo "FAIL|ICMP_TIMEOUT_OR_UNREACHABLE"
            fi
            ;;
        *)
            echo "FAIL|UNKNOWN_PROTOCOL_${protocol}"
            ;;
    esac
}

# ============================================================
# 옵션 파싱
# ============================================================
INPUT_FILE=""
SOURCE_CLUSTER=""
TIMEOUT="$DEFAULT_TIMEOUT"
OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
DRY_RUN=false

while getopts "i:s:t:o:nh" opt; do
    case $opt in
        i) INPUT_FILE="$OPTARG" ;;
        s) SOURCE_CLUSTER="$OPTARG" ;;
        t) TIMEOUT="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        n) DRY_RUN=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

# ============================================================
# 입력 검증
# ============================================================
if [[ -z "$INPUT_FILE" ]]; then
    echo "Error: -i <csv_file> 옵션이 필요합니다."
    usage
fi

if [[ -z "$SOURCE_CLUSTER" ]]; then
    echo "Error: -s <source_cluster> 옵션이 필요합니다."
    usage
fi

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: 입력 파일을 찾을 수 없습니다: $INPUT_FILE"
    exit 1
fi

if ! validate_csv_header "$INPUT_FILE"; then
    exit 1
fi

if ! command -v nc &> /dev/null; then
    log_warn "nc (netcat) 명령어가 없습니다. TCP/UDP 테스트는 실패합니다."
    log_warn "설치: yum install -y nc (또는 nmap-ncat)"
fi

# ============================================================
# 초기화
# ============================================================
mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
DETAILS_FILE="${OUTPUT_DIR}/details_${TIMESTAMP}.csv"
SUMMARY_FILE="${OUTPUT_DIR}/summary_${TIMESTAMP}.txt"
FAILED_FILE="${OUTPUT_DIR}/failed_${TIMESTAMP}.csv"

TOTAL_ROWS=0
FILTERED_ROWS=0
TOTAL_TESTS=0
PASS_COUNT=0
FAIL_COUNT=0

# 프로토콜별 통계
TCP_PASS=0; TCP_FAIL=0
UDP_PASS=0; UDP_FAIL=0
ICMP_PASS=0; ICMP_FAIL=0

# 서비스별 통계
declare -A SERVICE_PASS
declare -A SERVICE_FAIL

declare -a FAILED_TESTS=()

# ============================================================
# 실행 시작
# ============================================================
log_header "방화벽 연결 확인 테스트"

log_info "실행 시간: $(date '+%Y-%m-%d %H:%M:%S')"
log_info "입력 파일: $INPUT_FILE"
log_info "소스 클러스터: $SOURCE_CLUSTER"
log_info "타임아웃: ${TIMEOUT}초"
log_info "지원 프로토콜: TCP (포트), UDP (포트), ICMP (ping)"
[[ "$DRY_RUN" == true ]] && log_warn "DRY-RUN 모드: 실제 테스트 없이 시뮬레이션"

EXPECTED_TESTS=$(count_total_tests "$INPUT_FILE" "$SOURCE_CLUSTER")
log_info "예상 테스트 수: ${EXPECTED_TESTS}건"
log_info "결과 파일: $DETAILS_FILE"

echo "SERVICE,SOURCE,TARGET,PORT,PROTOCOL,RESULT,REASON,TIMESTAMP" > "$DETAILS_FILE"
echo "SERVICE,SOURCE,TARGET,PORT,PROTOCOL,RESULT,REASON,TIMESTAMP" > "$FAILED_FILE"

log_header "테스트 실행"

CURRENT_TEST=0

# ============================================================
# CSV 파싱 및 테스트
# ============================================================
while IFS='|' read -r service source target port protocol _rest; do
    [[ -z "$service" ]] && continue
    
    ((TOTAL_ROWS++)) || true
    
    source=$(echo "$source" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    port=$(echo "$port" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    protocol=$(echo "$protocol" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    if [[ "$source" != "$SOURCE_CLUSTER" ]]; then
        continue
    fi
    
    ((FILTERED_ROWS++)) || true
    
    proto_upper=$(echo "$protocol" | tr '[:lower:]' '[:upper:]')
    [[ -z "$proto_upper" ]] && proto_upper="ICMP"
    
    while IFS= read -r single_target; do
        [[ -z "$single_target" ]] && continue
        
        if [[ "$proto_upper" == "ICMP" ]]; then
            ((TOTAL_TESTS++)) || true
            ((CURRENT_TEST++)) || true
            
            test_result=$(test_connectivity "$single_target" "" "$proto_upper" "$TIMEOUT")
            result=$(echo "$test_result" | cut -d'|' -f1)
            reason=$(echo "$test_result" | cut -d'|' -f2)
            test_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
            
            if [[ "$result" == "PASS" ]]; then
                ((PASS_COUNT++)) || true
                ((ICMP_PASS++)) || true
                SERVICE_PASS[$service]=$((${SERVICE_PASS[$service]:-0} + 1))
                log_progress "$CURRENT_TEST" "$EXPECTED_TESTS" "${GREEN}PASS${NC} $service -> $single_target (ICMP)"
            else
                ((FAIL_COUNT++)) || true
                ((ICMP_FAIL++)) || true
                SERVICE_FAIL[$service]=$((${SERVICE_FAIL[$service]:-0} + 1))
                log_progress "$CURRENT_TEST" "$EXPECTED_TESTS" "${RED}FAIL${NC} $service -> $single_target (ICMP) - $reason"
                FAILED_TESTS+=("$service|$single_target|ICMP|$reason")
                echo "$service,$source,$single_target,,ICMP,$result,$reason,$test_timestamp" >> "$FAILED_FILE"
            fi
            
            echo "$service,$source,$single_target,,ICMP,$result,$reason,$test_timestamp" >> "$DETAILS_FILE"
        else
            while IFS= read -r single_port; do
                [[ -z "$single_port" ]] && continue
                
                ((TOTAL_TESTS++)) || true
                ((CURRENT_TEST++)) || true
                
                test_result=$(test_connectivity "$single_target" "$single_port" "$proto_upper" "$TIMEOUT")
                result=$(echo "$test_result" | cut -d'|' -f1)
                reason=$(echo "$test_result" | cut -d'|' -f2)
                test_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
                
                display_target="${single_target}:${single_port}"
                
                if [[ "$result" == "PASS" ]]; then
                    ((PASS_COUNT++)) || true
                    if [[ "$proto_upper" == "TCP" ]]; then
                        ((TCP_PASS++)) || true
                    else
                        ((UDP_PASS++)) || true
                    fi
                    SERVICE_PASS[$service]=$((${SERVICE_PASS[$service]:-0} + 1))
                    log_progress "$CURRENT_TEST" "$EXPECTED_TESTS" "${GREEN}PASS${NC} $service -> $display_target ($proto_upper)"
                else
                    ((FAIL_COUNT++)) || true
                    if [[ "$proto_upper" == "TCP" ]]; then
                        ((TCP_FAIL++)) || true
                    else
                        ((UDP_FAIL++)) || true
                    fi
                    SERVICE_FAIL[$service]=$((${SERVICE_FAIL[$service]:-0} + 1))
                    log_progress "$CURRENT_TEST" "$EXPECTED_TESTS" "${RED}FAIL${NC} $service -> $display_target ($proto_upper) - $reason"
                    FAILED_TESTS+=("$service|$display_target|$proto_upper|$reason")
                    echo "$service,$source,$single_target,$single_port,$proto_upper,$result,$reason,$test_timestamp" >> "$FAILED_FILE"
                fi
                
                echo "$service,$source,$single_target,$single_port,$proto_upper,$result,$reason,$test_timestamp" >> "$DETAILS_FILE"
                
            done < <(parse_targets "$port")
        fi
        
    done < <(parse_targets "$target")
    
done < <(tail -n +2 "$INPUT_FILE")

# ============================================================
# 필터링 결과 검증
# ============================================================
if [[ $FILTERED_ROWS -eq 0 ]]; then
    log_warn "SOURCE='$SOURCE_CLUSTER'와 일치하는 행이 없습니다."
    log_warn "CSV 파일의 SOURCE 컬럼 값을 확인하세요."
    log_info "CSV에 있는 SOURCE 목록:"
    list_available_sources "$INPUT_FILE"
fi

# ============================================================
# 결과 요약 출력
# ============================================================
log_header "테스트 결과 요약"

echo ""
echo "  입력 파일 총 행수 (헤더 제외): $TOTAL_ROWS"
echo "  필터링된 행수 (SOURCE=$SOURCE_CLUSTER): $FILTERED_ROWS"
echo "  총 테스트 수: $TOTAL_TESTS"
echo ""

SUCCESS_RATE=0
if [[ $TOTAL_TESTS -gt 0 ]]; then
    SUCCESS_RATE=$((PASS_COUNT * 100 / TOTAL_TESTS))
fi

echo "  ==========================================="
echo -e "  ${GREEN}성공 (PASS)${NC}: $PASS_COUNT"
echo -e "  ${RED}실패 (FAIL)${NC}: $FAIL_COUNT"
echo "  -------------------------------------------"
echo "  성공률: ${SUCCESS_RATE}%"
echo "  ==========================================="

# 프로토콜별 통계
log_header "프로토콜별 통계"
echo ""
TCP_TOTAL=$((TCP_PASS + TCP_FAIL))
UDP_TOTAL=$((UDP_PASS + UDP_FAIL))
ICMP_TOTAL=$((ICMP_PASS + ICMP_FAIL))

if [[ $TCP_TOTAL -gt 0 ]]; then
    TCP_RATE=$((TCP_PASS * 100 / TCP_TOTAL))
    echo -e "  TCP  : ${GREEN}${TCP_PASS} PASS${NC} / ${RED}${TCP_FAIL} FAIL${NC} (총 ${TCP_TOTAL}건, 성공률 ${TCP_RATE}%)"
fi
if [[ $UDP_TOTAL -gt 0 ]]; then
    UDP_RATE=$((UDP_PASS * 100 / UDP_TOTAL))
    echo -e "  UDP  : ${GREEN}${UDP_PASS} PASS${NC} / ${RED}${UDP_FAIL} FAIL${NC} (총 ${UDP_TOTAL}건, 성공률 ${UDP_RATE}%)"
fi
if [[ $ICMP_TOTAL -gt 0 ]]; then
    ICMP_RATE=$((ICMP_PASS * 100 / ICMP_TOTAL))
    echo -e "  ICMP : ${GREEN}${ICMP_PASS} PASS${NC} / ${RED}${ICMP_FAIL} FAIL${NC} (총 ${ICMP_TOTAL}건, 성공률 ${ICMP_RATE}%)"
fi

# 서비스별 통계
log_header "서비스별 통계"
echo ""
for svc in $(echo "${!SERVICE_PASS[@]} ${!SERVICE_FAIL[@]}" | tr ' ' '\n' | sort -u); do
    svc_pass=${SERVICE_PASS[$svc]:-0}
    svc_fail=${SERVICE_FAIL[$svc]:-0}
    svc_total=$((svc_pass + svc_fail))
    if [[ $svc_total -gt 0 ]]; then
        svc_rate=$((svc_pass * 100 / svc_total))
        if [[ $svc_fail -eq 0 ]]; then
            echo -e "  ${GREEN}●${NC} $svc: ${svc_pass}/${svc_total} (${svc_rate}%)"
        elif [[ $svc_pass -eq 0 ]]; then
            echo -e "  ${RED}●${NC} $svc: ${svc_pass}/${svc_total} (${svc_rate}%)"
        else
            echo -e "  ${YELLOW}●${NC} $svc: ${svc_pass}/${svc_total} (${svc_rate}%)"
        fi
    fi
done

# 실패 목록
if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
    log_header "실패 목록 (${#FAILED_TESTS[@]}건)"
    
    current_svc=""
    for failed in "${FAILED_TESTS[@]}"; do
        IFS='|' read -r svc tgt proto rsn <<< "$failed"
        if [[ "$svc" != "$current_svc" ]]; then
            current_svc="$svc"
            echo ""
            echo -e "  ${YELLOW}[$svc]${NC}"
        fi
        echo "    - $tgt ($proto) : $rsn"
    done
fi

# ============================================================
# Summary 파일 저장
# ============================================================
cat << EOF > "$SUMMARY_FILE"
============================================================
 방화벽 연결 확인 테스트 결과 요약
============================================================

실행 시간: $(date '+%Y-%m-%d %H:%M:%S')
입력 파일: $INPUT_FILE
소스 클러스터: $SOURCE_CLUSTER
타임아웃: ${TIMEOUT}초
모드: $([ "$DRY_RUN" == true ] && echo "DRY-RUN (시뮬레이션)" || echo "실제 테스트")

------------------------------------------------------------
전체 통계
------------------------------------------------------------
입력 파일 총 행수: $TOTAL_ROWS
필터링된 행수: $FILTERED_ROWS
총 테스트 수: $TOTAL_TESTS
성공 (PASS): $PASS_COUNT
실패 (FAIL): $FAIL_COUNT
성공률: ${SUCCESS_RATE}%

------------------------------------------------------------
프로토콜별 통계
------------------------------------------------------------
EOF

[[ $TCP_TOTAL -gt 0 ]] && echo "TCP  : ${TCP_PASS} PASS / ${TCP_FAIL} FAIL (총 ${TCP_TOTAL}건, 성공률 ${TCP_RATE:-0}%)" >> "$SUMMARY_FILE"
[[ $UDP_TOTAL -gt 0 ]] && echo "UDP  : ${UDP_PASS} PASS / ${UDP_FAIL} FAIL (총 ${UDP_TOTAL}건, 성공률 ${UDP_RATE:-0}%)" >> "$SUMMARY_FILE"
[[ $ICMP_TOTAL -gt 0 ]] && echo "ICMP : ${ICMP_PASS} PASS / ${ICMP_FAIL} FAIL (총 ${ICMP_TOTAL}건, 성공률 ${ICMP_RATE:-0}%)" >> "$SUMMARY_FILE"

cat << EOF >> "$SUMMARY_FILE"

------------------------------------------------------------
서비스별 통계
------------------------------------------------------------
EOF

for svc in $(echo "${!SERVICE_PASS[@]} ${!SERVICE_FAIL[@]}" | tr ' ' '\n' | sort -u); do
    svc_pass=${SERVICE_PASS[$svc]:-0}
    svc_fail=${SERVICE_FAIL[$svc]:-0}
    svc_total=$((svc_pass + svc_fail))
    if [[ $svc_total -gt 0 ]]; then
        svc_rate=$((svc_pass * 100 / svc_total))
        echo "$svc: ${svc_pass}/${svc_total} (${svc_rate}%)" >> "$SUMMARY_FILE"
    fi
done

cat << EOF >> "$SUMMARY_FILE"

------------------------------------------------------------
실패 목록 (${#FAILED_TESTS[@]}건)
------------------------------------------------------------
EOF

if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
    current_svc=""
    for failed in "${FAILED_TESTS[@]}"; do
        IFS='|' read -r svc tgt proto rsn <<< "$failed"
        if [[ "$svc" != "$current_svc" ]]; then
            current_svc="$svc"
            echo "" >> "$SUMMARY_FILE"
            echo "[$svc]" >> "$SUMMARY_FILE"
        fi
        echo "  - $tgt ($proto) : $rsn" >> "$SUMMARY_FILE"
    done
else
    echo "(없음)" >> "$SUMMARY_FILE"
fi

# ============================================================
# 완료
# ============================================================
echo ""
log_info "상세 결과: $DETAILS_FILE"
log_info "실패 목록: $FAILED_FILE"
log_info "요약 결과: $SUMMARY_FILE"

exit 0
