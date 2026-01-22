#!/bin/bash
#
# 대규모 IP/PORT 리스트 시뮬레이션 테스트
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_CSV="${SCRIPT_DIR}/data/test_simulation.csv"
REPORTS_DIR="${SCRIPT_DIR}/reports"

cat << 'EOF' > "$TEST_CSV"
SERVICE|SOURCE|TARGET|PORT|PROTOCOL|요청일자|요청자|처리일자|처리자
DB-Cluster|ic-dataops-dev|127.0.0.1, 8.8.8.8, 8.8.4.4, 203.0.113.1, 203.0.113.2|5432, 5433, 5434, 6432|TCP|26/01/16|변상현 책임|26/01/19|김현태 책임
API-Gateway|ic-dataops-dev|127.0.0.1, 203.0.113.10, 203.0.113.11, 203.0.113.12|80, 443, 8080, 8443, 9000|TCP|26/01/17|이영희 책임|26/01/20|김현태 책임
Kafka-Broker|ic-dataops-dev|8.8.8.8, 8.8.4.4, 198.51.100.1, 198.51.100.2, 198.51.100.3|9092, 9093, 9094|TCP|26/01/18|박철수 책임|26/01/21|김현태 책임
DNS-Primary|ic-dataops-dev|8.8.8.8, 8.8.4.4, 1.1.1.1|53|UDP|26/01/19|김민수 책임|26/01/22|김현태 책임
Syslog-Collector|ic-dataops-dev|198.51.100.10, 198.51.100.11|514, 1514, 5514|UDP|26/01/20|최지영 책임|26/01/23|김현태 책임
Network-Monitor|ic-dataops-dev|127.0.0.1, 8.8.8.8, 8.8.4.4, 203.0.113.20, 203.0.113.21, 198.51.100.20||ICMP|26/01/21|홍길동 책임|26/01/24|김현태 책임
Redis-Cluster|ic-dataops-dev|127.0.0.1, 8.8.8.8|6379, 6380, 6381, 26379|TCP|26/01/22|김철수 책임|26/01/25|김현태 책임
Elasticsearch|ic-dataops-dev|127.0.0.1, 203.0.113.30, 203.0.113.31|9200, 9300|TCP|26/01/23|이민호 책임|26/01/26|김현태 책임
NTP-Server|ic-dataops-dev|127.0.0.1, 8.8.8.8|123|UDP|26/01/24|박지성 책임|26/01/27|김현태 책임
Prometheus|ic-dataops-prod|10.25.200.1, 10.25.200.2|9090, 9091, 9093|TCP|26/01/25|손흥민 책임|26/01/28|김현태 책임
EOF

echo "========================================"
echo " 대규모 IP/PORT 리스트 시뮬레이션"
echo "========================================"
echo ""
echo "테스트 데이터 구성:"
echo "  - DB-Cluster: IP 5개 × PORT 4개 = 20건 (TCP)"
echo "  - API-Gateway: IP 4개 × PORT 5개 = 20건 (TCP)"
echo "  - Kafka-Broker: IP 5개 × PORT 3개 = 15건 (TCP)"
echo "  - DNS-Primary: IP 3개 × PORT 1개 = 3건 (UDP)"
echo "  - Syslog-Collector: IP 2개 × PORT 3개 = 6건 (UDP)"
echo "  - Network-Monitor: IP 6개 = 6건 (ICMP)"
echo "  - Redis-Cluster: IP 2개 × PORT 4개 = 8건 (TCP)"
echo "  - Elasticsearch: IP 3개 × PORT 2개 = 6건 (TCP)"
echo "  - NTP-Server: IP 2개 × PORT 1개 = 2건 (UDP)"
echo "  - Prometheus (prod): 제외"
echo "  ----------------------------------------"
echo "  예상 총 테스트: 86건"
echo ""

"${SCRIPT_DIR}/bin/check_firewall.sh" -i "$TEST_CSV" -s ic-dataops-dev -n

echo ""
echo "========================================"
echo " 결과 파일"
echo "========================================"
ls -la "$REPORTS_DIR"/*.csv "$REPORTS_DIR"/*.txt 2>/dev/null | awk '{print "  "$NF": "$5" bytes"}'
