# Firewall Check Workflow Guide

**Git → Jenkins → Script → Results** 전체 워크플로우 가이드

---

## Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Firewall Check Workflow                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌─────────┐      ┌─────────┐      ┌─────────┐      ┌─────────┐          │
│   │   Git   │ ──── │ Jenkins │ ──── │ Script  │ ──── │ Results │          │
│   └─────────┘      └─────────┘      └─────────┘      └─────────┘          │
│       │                │                │                │                 │
│       ▼                ▼                ▼                ▼                 │
│   CSV 관리          자동 실행        방화벽 점검       보고서 확인          │
│   스크립트 관리     스케줄링         TCP/UDP/ICMP     성공/실패 분석        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Step 1: Git - CSV 및 스크립트 관리

### 1.1 저장소 클론 (최초 1회)

```bash
git clone <repository-url>
cd firewall-check
```

### 1.2 프로젝트 구조 확인

```
firewall-check/
├── bin/
│   └── check_firewall.sh    # 메인 스크립트
├── data/
│   └── sample_firewall.csv  # 방화벽 오픈 대장
├── reports/                 # 결과 저장 (자동 생성)
├── docs/
│   ├── runbook.md           # 운영 가이드
│   └── workflow-guide.md    # 이 문서
├── Jenkinsfile              # Jenkins 파이프라인
└── README.md
```

### 1.3 CSV 파일 형식

**구분자**: `|` (파이프)

```
SERVICE|SOURCE|TARGET|PORT|PROTOCOL|요청일자|요청자|처리일자|처리자
```

**예시**:

```
SERVICE|SOURCE|TARGET|PORT|PROTOCOL|요청일자|요청자|처리일자|처리자
ETL|ic-dataops-dev|10.25.200.87, 10.25.200.88|5432, 5433|TCP|26/01/16|변상현 책임|26/01/19|김현태 책임
DNS|ic-dataops-dev|10.25.200.91, 10.25.200.92|53|UDP|26/01/17|박철수 책임|26/01/20|김현태 책임
Network|ic-dataops-dev|10.25.200.94, 10.25.200.95||ICMP|26/01/18|최지영 책임|26/01/21|김현태 책임
```

**컬럼 설명**:

| 컬럼 | 설명 | 예시 |
|------|------|------|
| SERVICE | 서비스명 | ETL, API, DNS |
| SOURCE | 소스 클러스터명 (필터 기준) | ic-dataops-dev |
| TARGET | 대상 IP (쉼표로 복수 가능) | 10.1.1.1, 10.1.1.2 |
| PORT | 포트 (쉼표로 복수 가능, ICMP는 비움) | 5432, 5433 |
| PROTOCOL | TCP, UDP, ICMP | TCP |
| 요청일자 | 방화벽 오픈 요청일 | 26/01/16 |
| 요청자 | 요청자명 | 변상현 책임 |
| 처리일자 | 처리 완료일 | 26/01/19 |
| 처리자 | 처리자명 | 김현태 책임 |

### 1.4 CSV 업데이트 절차

```bash
# 1. 최신 코드 가져오기
git pull origin main

# 2. CSV 파일 수정
vi data/sample_firewall.csv

# 3. 로컬 테스트 (dry-run)
./bin/check_firewall.sh -i data/sample_firewall.csv -s ic-dataops-dev -n

# 4. 커밋 및 푸시
git add data/sample_firewall.csv
git commit -m "Update firewall list: add new ETL targets"
git push origin main
```

---

## Step 2: Jenkins - 파이프라인 설정

### 2.1 Jenkins Job 생성 (최초 1회)

1. Jenkins 대시보드 → **New Item**
2. Item name: `firewall-check`
3. **Pipeline** 선택 → OK

### 2.2 파이프라인 설정

**General 탭**:
- [x] This project is parameterized

**파라미터 추가** (Build with Parameters용):

| 파라미터 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| INPUT_FILE | String | data/sample_firewall.csv | CSV 파일 경로 |
| SOURCE_CLUSTER | String | ic-dataops-dev | 현재 클러스터명 |
| TIMEOUT | String | 2 | 타임아웃 (초) |
| NODE_LABEL | String | linux | 실행 노드 라벨 |

**Pipeline 탭**:
- Definition: **Pipeline script from SCM**
- SCM: **Git**
- Repository URL: `<your-repo-url>`
- Branch: `*/main`
- Script Path: `Jenkinsfile`

### 2.3 Jenkinsfile 내용

```groovy
pipeline {
    agent {
        label "${params.NODE_LABEL ?: 'linux'}"
    }

    parameters {
        string(name: 'INPUT_FILE', defaultValue: 'data/sample_firewall.csv', description: 'CSV file path')
        string(name: 'SOURCE_CLUSTER', defaultValue: 'ic-dataops-dev', description: 'Source cluster name')
        string(name: 'TIMEOUT', defaultValue: '2', description: 'Timeout in seconds')
        string(name: 'NODE_LABEL', defaultValue: 'linux', description: 'Jenkins node label')
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Run Firewall Check') {
            steps {
                sh """
                    chmod +x bin/check_firewall.sh
                    ./bin/check_firewall.sh \\
                        -i ${params.INPUT_FILE} \\
                        -s ${params.SOURCE_CLUSTER} \\
                        -t ${params.TIMEOUT}
                """
            }
        }

        stage('Archive Results') {
            steps {
                archiveArtifacts artifacts: 'reports/*.csv, reports/*.txt', allowEmptyArchive: true
            }
        }
    }

    post {
        always {
            echo 'Firewall check completed'
        }
    }
}
```

### 2.4 스케줄 설정 (선택)

**Build Triggers** → **Build periodically**:

```
# 매일 오전 9시 실행
H 9 * * *

# 매주 월요일 오전 9시
H 9 * * 1

# 매월 1일 오전 9시
H 9 1 * *
```

---

## Step 3: Script 실행

### 3.1 CLI 옵션

```bash
./bin/check_firewall.sh [OPTIONS]

필수:
  -i <file>     입력 CSV 파일 경로
  -s <cluster>  소스 클러스터명 (CSV의 SOURCE 컬럼과 매칭)

선택:
  -t <seconds>  타임아웃 (기본: 2)
  -o <dir>      결과 저장 디렉토리 (기본: reports/)
  -n            dry-run 모드 (실제 네트워크 테스트 없이 시뮬레이션)
  -h            도움말
```

### 3.2 실행 예시

```bash
# 실제 테스트 실행
./bin/check_firewall.sh -i data/sample_firewall.csv -s ic-dataops-dev -t 3

# Dry-run (시뮬레이션)
./bin/check_firewall.sh -i data/sample_firewall.csv -s ic-dataops-dev -n

# 결과 디렉토리 지정
./bin/check_firewall.sh -i data/sample_firewall.csv -s ic-dataops-dev -o /var/log/firewall-check
```

### 3.3 테스트 방식

| 프로토콜 | 테스트 명령 | 성공 기준 |
|----------|-------------|----------|
| TCP | `nc -z -w <timeout> <ip> <port>` | 연결 성공 |
| UDP | `nc -zu -w <timeout> <ip> <port>` | 응답 수신 (제한적) |
| ICMP | `ping -c 5 -W <timeout> <ip>` | 5회 모두 성공 |

### 3.4 Dry-run 모드 동작

실제 네트워크 접근 없이 스크립트 동작을 테스트:

| IP 대역 | 결과 |
|---------|------|
| 127.x.x.x | PASS |
| 8.8.x.x | PASS |
| 그 외 | FAIL |

---

## Step 4: 결과 확인

### 4.1 콘솔 출력 예시

```
============================================================
 방화벽 연결 점검 시작
============================================================
 입력 파일: data/sample_firewall.csv
 소스 클러스터: ic-dataops-dev
 타임아웃: 2초
 Dry-run: YES
============================================================

[1/86] [TCP] DB-Cluster 127.0.0.1:5432 ... PASS
[2/86] [TCP] DB-Cluster 127.0.0.1:5433 ... PASS
[3/86] [TCP] DB-Cluster 8.8.8.8:5432 ... PASS
...

============================================================
 테스트 완료
============================================================
 총 테스트: 86건
 성공: 40건 (46.5%)
 실패: 46건 (53.5%)
============================================================

============================================================
 프로토콜별 통계
============================================================
  TCP:  32/69 (46.4%)
  UDP:   5/11 (45.5%)
  ICMP:  3/6  (50.0%)

============================================================
 서비스별 통계
============================================================
  ● DB-Cluster: 12/20 (60%)
  ● API-Gateway: 5/20 (25%)
  ● Redis-Cluster: 8/8 (100%)
  ● Syslog-Collector: 0/6 (0%)

============================================================
 실패 목록 (46건)
============================================================

  [DB-Cluster]
    - 203.0.113.1:5432 (TCP) : TCP_CONNECTION_REFUSED
    - 203.0.113.1:5433 (TCP) : TCP_CONNECTION_REFUSED
    ...
```

### 4.2 결과 파일

| 파일 | 내용 | 용도 |
|------|------|------|
| `details_YYYYMMDD_HHMMSS.csv` | 전체 테스트 상세 결과 | 전체 현황 파악 |
| `failed_YYYYMMDD_HHMMSS.csv` | 실패한 테스트만 | 실패 원인 분석 |
| `summary_YYYYMMDD_HHMMSS.txt` | 요약 리포트 | 빠른 현황 확인 |

### 4.3 Details CSV 형식

```csv
TIMESTAMP|SERVICE|SOURCE|TARGET|PORT|PROTOCOL|RESULT|REASON
2026-01-22 11:37:22|DB-Cluster|ic-dataops-dev|127.0.0.1|5432|TCP|PASS|
2026-01-22 11:37:22|DB-Cluster|ic-dataops-dev|203.0.113.1|5432|TCP|FAIL|TCP_CONNECTION_REFUSED
```

### 4.4 실패 사유 코드

| 코드 | 의미 | 조치 |
|------|------|------|
| TCP_CONNECTION_REFUSED | TCP 포트 연결 거부 | 방화벽 오픈 확인, 대상 서비스 상태 확인 |
| TCP_TIMEOUT | TCP 연결 타임아웃 | 네트워크 경로 확인, 타임아웃 값 조정 |
| UDP_NO_RESPONSE | UDP 응답 없음 | UDP 특성상 정상일 수 있음, 별도 확인 필요 |
| ICMP_TIMEOUT | ping 타임아웃 | 방화벽에서 ICMP 차단 여부 확인 |
| ICMP_UNREACHABLE | 호스트 도달 불가 | 라우팅 확인, 대상 서버 상태 확인 |
| PORT_NOT_SPECIFIED | 포트 미지정 | CSV에서 PORT 컬럼 확인 |

### 4.5 Jenkins Artifacts 확인

1. Jenkins Job → Build History → 해당 빌드 선택
2. **Artifacts** 섹션에서 파일 다운로드
3. 또는 **Console Output**에서 실시간 로그 확인

---

## Troubleshooting

### SOURCE와 일치하는 행이 없음

```
[WARN] SOURCE='wrong-cluster'와 일치하는 행이 없습니다.
```

**해결**: `-s` 옵션 값이 CSV의 SOURCE 컬럼과 정확히 일치하는지 확인

### nc: command not found

```bash
# RHEL/CentOS
sudo yum install -y nc

# Ubuntu/Debian
sudo apt install -y netcat
```

### Permission denied

```bash
chmod +x bin/check_firewall.sh
```

### CSV 파싱 오류

- 구분자가 `|`인지 확인
- 헤더 행이 올바른지 확인
- UTF-8 인코딩인지 확인

---

## Quick Reference

### 일상 운영 체크리스트

- [ ] CSV 파일이 최신 상태인가?
- [ ] SOURCE_CLUSTER가 올바른가?
- [ ] Jenkins 노드가 네트워크 접근 가능한가?
- [ ] 결과 파일이 정상 생성되었는가?
- [ ] 실패 항목에 대한 조치가 필요한가?

### 주요 명령어

```bash
# 로컬 dry-run 테스트
./bin/check_firewall.sh -i data/sample_firewall.csv -s ic-dataops-dev -n

# 실제 테스트
./bin/check_firewall.sh -i data/sample_firewall.csv -s ic-dataops-dev

# 대규모 시뮬레이션 테스트
./test_simulation.sh
```

### 관련 문서

- [README.md](../README.md) - 프로젝트 개요
- [runbook.md](./runbook.md) - 운영 가이드
- [Jenkinsfile](../Jenkinsfile) - Jenkins 파이프라인 정의
