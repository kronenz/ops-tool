# 운영 가이드 (Runbook)

## 개요

이 도구는 방화벽 오픈 대장(CSV)을 기반으로 클러스터 노드에서 외부 서버로의 ICMP 연결을 자동 점검합니다.

## 정기 점검 절차

### 1. 사전 준비

1. 최신 방화벽 오픈 대장 CSV 파일 확보
2. 현재 클러스터명 확인 (예: `ic-dataops-dev`, `ic-dataops-prod`)
3. Jenkins Job 파라미터 확인

### 2. Jenkins 실행

1. Jenkins에서 `firewall-check` Job 선택
2. Build with Parameters 클릭
3. 파라미터 입력:
   - `INPUT_FILE`: CSV 파일 경로
   - `SOURCE_CLUSTER`: 현재 클러스터명
   - `TIMEOUT`: 2~3 (네트워크 상황에 따라 조정)
   - `NODE_LABEL`: 해당 클러스터 노드 라벨
4. Build 클릭

### 3. 결과 확인

1. 콘솔 출력에서 성공/실패 요약 확인
2. Artifacts에서 상세 결과 다운로드:
   - `details_*.csv`: 개별 테스트 결과
   - `summary_*.txt`: 요약 리포트

## 실패 대응

### 실패 시 확인 사항

1. **네트워크 문제**
   - 노드에서 수동으로 ping 테스트: `ping -c 5 -W 2 <target_ip>`
   - 라우팅 확인: `traceroute <target_ip>`

2. **방화벽 미오픈**
   - 방화벽 오픈 요청 상태 확인
   - 네트워크팀에 오픈 여부 문의

3. **대상 서버 문제**
   - 대상 서버 상태 확인
   - ICMP가 차단된 경우 별도 확인 필요

### 에스컬레이션

| 상황 | 담당 |
|------|------|
| 방화벽 미오픈 | 네트워크팀 |
| 대상 서버 장애 | 해당 서비스팀 |
| 스크립트 오류 | 플랫폼팀 |

## cron 설정 (선택)

Jenkins 외에 cron으로 정기 실행 시:

```bash
# 매일 오전 9시 실행
0 9 * * * /path/to/firewall-check/bin/check_firewall.sh \
    -i /path/to/firewall.csv \
    -s ic-dataops-dev \
    -o /var/log/firewall-check \
    >> /var/log/firewall-check/cron.log 2>&1
```

## Dry-run 모드 (테스트용)

실제 네트워크 접근 없이 스크립트 동작을 확인할 때:

```bash
./bin/check_firewall.sh -i data/sample_firewall.csv -s ic-dataops-dev -n
```

시뮬레이션 규칙:
- `127.x.x.x`, `8.8.x.x` 대역 → PASS
- 그 외 IP → FAIL

## 트러블슈팅

### SOURCE와 일치하는 행이 없음

```
[WARN] SOURCE='wrong-cluster'와 일치하는 행이 없습니다.
[INFO] CSV에 있는 SOURCE 목록:
  - ic-dataops-dev
  - ic-dataops-prod
```

→ `-s` 옵션에 전달한 클러스터명이 CSV의 SOURCE 컬럼 값과 일치하는지 확인

### ping: command not found

```bash
# RHEL/CentOS
sudo yum install -y iputils
```

### Permission denied

```bash
chmod +x bin/check_firewall.sh
```

### CSV 파싱 오류

- CSV 파일이 UTF-8 인코딩인지 확인
- 헤더 행이 정확한지 확인: `SERVICE,SOURCE,TARGET,PORT,PROTOCOL,...`
- TARGET에 공백이 있을 경우 따옴표로 감싸기: `"10.1.1.1, 10.1.1.2"`

## 유지보수

### CSV 대장 업데이트

1. 새로운 방화벽 오픈 요청 시 CSV에 행 추가
2. 처리 완료 시 처리일자/처리자 업데이트
3. Git commit 후 push

### 스크립트 수정

1. `bin/check_firewall.sh` 수정
2. 테스트 실행으로 동작 확인
3. Git commit 후 push
