# Firewall Connectivity Check Tool

방화벽 오픈 대장(CSV) 기반으로 클러스터 노드에서 외부 서버로의 ICMP 연결을 테스트하는 도구.

## 요구사항

- RHEL/CentOS 계열 Linux (ping, gawk 필요)
- Bash 4.0+
- Jenkins (선택, 자동화 실행 시)

## 프로젝트 구조

```
firewall-check/
├── bin/
│   └── check_firewall.sh    # 실행 스크립트
├── data/
│   └── sample_firewall.csv  # 예시 CSV
├── reports/                 # 결과 저장 (gitignore)
├── docs/
│   └── runbook.md           # 운영 가이드
├── Jenkinsfile              # Jenkins 파이프라인
└── README.md
```

## CSV 형식 (구분자: `|`)

```
SERVICE|SOURCE|TARGET|PORT|PROTOCOL|요청일자|요청자|처리일자|처리자
ETL|ic-dataops-dev|10.25.200.87, 10.25.200.88|5432, 5433|TCP|26/01/16|변상현 책임|26/01/19|김현태 책임
DNS|ic-dataops-dev|10.25.200.91, 10.25.200.92|53|UDP|26/01/17|박철수 책임|26/01/20|김현태 책임
Network|ic-dataops-dev|10.25.200.94, 10.25.200.95||ICMP|26/01/18|최지영 책임|26/01/21|김현태 책임
```

- **SERVICE**: 서비스명
- **SOURCE**: 소스 클러스터명 (필터링 기준)
- **TARGET**: 대상 IP (단일 또는 쉼표 구분 리스트)
- **PORT**: 단일 또는 쉼표 구분 리스트 (ICMP는 비워둠)
- **PROTOCOL**: TCP, UDP, ICMP

**IP × PORT 조합 테스트**: TARGET과 PORT가 모두 리스트인 경우, 모든 조합을 테스트합니다.
```
TARGET: 10.1.1.1, 10.1.1.2  PORT: 80, 443
→ 10.1.1.1:80, 10.1.1.1:443, 10.1.1.2:80, 10.1.1.2:443 (4건)
```

## 사용법

### CLI 실행

```bash
./bin/check_firewall.sh \
    -i data/sample_firewall.csv \
    -s ic-dataops-dev \
    -t 2

# 옵션:
#   -i <csv>     입력 CSV 파일 (필수)
#   -s <source>  소스 클러스터명 (필수, 본인 클러스터만 테스트)
#   -t <sec>     ping 타임아웃 초 (기본: 2)
#   -o <dir>     결과 저장 디렉토리 (기본: reports/)
#   -n           dry-run 모드 (실제 ping 없이 시뮬레이션)
```

### Dry-run 모드

네트워크 접근 없이 스크립트 동작을 테스트할 때 사용:

```bash
./bin/check_firewall.sh -i data/sample_firewall.csv -s ic-dataops-dev -n
```

- `127.x.x.x`, `8.8.x.x` 대역: PASS
- 그 외 IP: FAIL

### Jenkins 실행

1. Jenkins에 파이프라인 Job 생성
2. Pipeline script from SCM 선택, 이 repo 지정
3. 파라미터:
   - `INPUT_FILE`: CSV 경로
   - `SOURCE_CLUSTER`: 현재 클러스터명
   - `TIMEOUT`: 타임아웃
   - `NODE_LABEL`: 실행할 노드 라벨

## 출력

### 콘솔 출력

- **진행률 표시**: `[1/86]`, `[2/86]`, ... 실시간 진행 상황
- **프로토콜별 통계**: TCP/UDP/ICMP 각각 성공률
- **서비스별 통계**: 서비스별 성공률 + 색상 표시
  - 🟢 녹색: 100% 성공
  - 🟡 노랑: 부분 성공
  - 🔴 빨강: 0% 성공
- **실패 목록 그룹핑**: 서비스별로 그룹화

### 결과 파일

| 파일 | 내용 |
|-----|------|
| `details_*.csv` | 전체 테스트 상세 결과 |
| `failed_*.csv` | 실패한 테스트만 |
| `summary_*.txt` | 요약 리포트 (통계 + 실패 목록) |

## 테스트 기준

| 프로토콜 | 테스트 방식 | 성공 기준 |
|----------|------------|----------|
| **TCP** | `nc -z` 포트 연결 | 연결 성공 |
| **UDP** | `nc -zu` 포트 연결 | 응답 수신 (신뢰성 제한적) |
| **ICMP** | `ping` 5회 | 5회 모두 성공 |

### 실패 사유 코드

| 코드 | 의미 |
|------|------|
| `TCP_CONNECTION_FAILED` | TCP 포트 연결 실패 |
| `UDP_NO_RESPONSE` | UDP 응답 없음 |
| `ICMP_TIMEOUT_OR_UNREACHABLE` | ping 실패 |
| `PORT_NOT_SPECIFIED` | TCP/UDP인데 포트 미지정 |

## 종료 코드

- `0`: 테스트 완료 (실패 여부와 무관하게 정상 종료)
- `1`: 스크립트 오류 (CSV 형식 오류, 파일 없음 등)

실패 여부는 콘솔 출력과 리포트 파일에서 확인합니다.
