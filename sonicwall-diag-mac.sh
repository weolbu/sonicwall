#!/bin/bash
# SonicWall CSE Service Tunnel - macOS Diagnostic & Fix Script
#
# Usage:
#   curl -sL <URL> | sudo bash                          # 기본 도메인 진단
#   curl -sL <URL> | sudo bash -s -- 10.0.1.50          # 기본 + 추가 서버 테스트
#   curl -sL <URL> | sudo bash -s -- 10.0.1.50 8080     # 기본 + 추가 서버:포트 테스트

set -euo pipefail

DEFAULT_HOSTS=("weolbu.com" "admin.weolbu.com" "redash.weolbu.com")
EXTRA_HOST="${1:-}"
EXTRA_PORT="${2:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

WG_BIN="/Applications/Banyan.app/Contents/Resources/bin/wg"
PLIST="/Applications/Banyan.app/Contents/Resources/conf/com.banyan.banyanwgs.plist"

print_header() { echo -e "\n${CYAN}===== $1 =====${NC}"; }
pass()         { echo -e "  ${GREEN}[OK]${NC} $1"; }
warn()         { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
fail()         { echo -e "  ${RED}[FAIL]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}root 권한이 필요합니다. sudo 로 실행해주세요.${NC}"
    exit 1
fi

echo -e "${CYAN}"
echo "============================================"
echo " SonicWall CSE Service Tunnel Diagnostics"
echo " macOS"
echo "============================================"
echo -e "${NC}"

# --------------------------------------------------
print_header "1단계: Banyan 앱 설치 확인"
# --------------------------------------------------
if [[ -x "$WG_BIN" ]]; then
    pass "WireGuard 바이너리 존재: $WG_BIN"
else
    fail "WireGuard 바이너리를 찾을 수 없습니다. CSE 앱이 설치되어 있는지 확인하세요."
    exit 1
fi

# --------------------------------------------------
print_header "2단계: WireGuard 서비스(banyan-wgs) 상태 확인"
# --------------------------------------------------
WGS_RUNNING=false
if launchctl list 2>/dev/null | grep -q banyan; then
    pass "banyan-wgs 서비스가 실행 중입니다."
    WGS_RUNNING=true
else
    warn "banyan-wgs 서비스가 실행되고 있지 않습니다. 재시작을 시도합니다..."
    launchctl unload -w "$PLIST" 2>/dev/null || true
    sleep 2
    launchctl load -w "$PLIST" 2>/dev/null || true
    sleep 3
    if launchctl list 2>/dev/null | grep -q banyan; then
        pass "서비스 재시작 성공!"
        WGS_RUNNING=true
    else
        fail "서비스 재시작 실패. CSE 앱 재설치를 권장합니다."
    fi
fi

# --------------------------------------------------
print_header "3단계: WireGuard 터널 상태 확인"
# --------------------------------------------------
WG_OUTPUT=$("$WG_BIN" 2>/dev/null || true)

if [[ -z "$WG_OUTPUT" ]]; then
    fail "WireGuard 인터페이스가 활성화되지 않았습니다."
    echo "       -> CSE 앱에서 Service Tunnel Power 버튼을 켜주세요."
else
    pass "WireGuard 인터페이스 활성 상태"
    echo ""
    echo -e "${CYAN}  --- WireGuard 상세 정보 ---${NC}"
    echo "$WG_OUTPUT" | sed 's/^/  /'
    echo ""

    # Handshake 검사
    HANDSHAKE_LINE=$(echo "$WG_OUTPUT" | grep -i "latest handshake" || true)
    if [[ -n "$HANDSHAKE_LINE" ]]; then
        if echo "$HANDSHAKE_LINE" | grep -qE "([0-9]+) seconds? ago"; then
            SECS=$(echo "$HANDSHAKE_LINE" | grep -oE '[0-9]+' | tail -1)
            if [[ "$SECS" -le 180 ]]; then
                pass "Latest handshake: ${SECS}초 전 (정상, 180초 이내)"
            else
                warn "Latest handshake: ${SECS}초 전 (180초 초과 - 터널 불안정 가능)"
            fi
        elif echo "$HANDSHAKE_LINE" | grep -q "minute"; then
            MINS=$(echo "$HANDSHAKE_LINE" | grep -oE '[0-9]+' | head -1)
            if [[ "$MINS" -le 3 ]]; then
                pass "Latest handshake: 약 ${MINS}분 전 (정상 범위)"
            else
                warn "Latest handshake: 약 ${MINS}분 전 (터널 불안정 가능)"
            fi
        else
            warn "Handshake 시간 파싱 불가: $HANDSHAKE_LINE"
        fi
    else
        fail "Handshake 기록 없음 - 터널이 한 번도 연결되지 않았습니다."
    fi

    # Transfer 검사
    TRANSFER_LINE=$(echo "$WG_OUTPUT" | grep -i "transfer" || true)
    if [[ -n "$TRANSFER_LINE" ]]; then
        pass "Transfer: $TRANSFER_LINE"
    else
        warn "Transfer 정보 없음"
    fi

    # Allowed IPs 출력
    ALLOWED=$(echo "$WG_OUTPUT" | grep -i "allowed ips" || true)
    if [[ -n "$ALLOWED" ]]; then
        echo -e "\n  ${CYAN}[Allowed IPs - 터널 경유 대상 CIDR]${NC}"
        echo "$ALLOWED" | sed 's/^/  /'
    fi

    # Endpoint 출력
    ENDPOINT=$(echo "$WG_OUTPUT" | grep -i "endpoint" || true)
    if [[ -n "$ENDPOINT" ]]; then
        echo -e "\n  ${CYAN}[Endpoint - Access Tier 주소]${NC}"
        echo "$ENDPOINT" | sed 's/^/  /'
    fi
fi

# --------------------------------------------------
print_header "4단계: DNS 설정 확인"
# --------------------------------------------------
echo -e "  ${CYAN}[scutil --dns 주요 항목]${NC}"
scutil --dns 2>/dev/null | grep -A5 "resolver" | head -40 | sed 's/^/  /'

# --------------------------------------------------
print_header "5단계: 프로세스 및 네트워크 상태"
# --------------------------------------------------

echo -e "\n  ${CYAN}[CSE 관련 프로세스]${NC}"
ps aux 2>/dev/null | grep -iE "banyan|sonicwall|wireguard" | grep -v grep | sed 's/^/  /' || warn "CSE 관련 프로세스 없음"

echo -e "\n  ${CYAN}[라우팅 테이블]${NC}"
netstat -rn 2>/dev/null | head -40 | sed 's/^/  /'

echo -e "\n  ${CYAN}[CSE 로컬 DNS 리졸버(127.0.0.5) 연결 상태]${NC}"
netstat -an 2>/dev/null | grep "127.0.0.5" | sed 's/^/  /' || warn "127.0.0.5 관련 연결 없음"

echo -e "\n  ${CYAN}[포트 리스닝 상태 (banyan/wireguard 관련)]${NC}"
lsof -iTCP -iUDP 2>/dev/null | grep -iE "banyan|wireguard|wg|utun" | sed 's/^/  /' || warn "관련 리스닝 포트 없음"

# --------------------------------------------------
# 서버 테스트 함수
# --------------------------------------------------
test_server() {
    local HOST="$1"
    local PORT="${2:-}"

    echo -e "\n${CYAN}  ────────────────────────────────────────${NC}"
    echo -e "  ${CYAN}대상: ${HOST}${PORT:+ :$PORT}${NC}"
    echo -e "${CYAN}  ────────────────────────────────────────${NC}"

    # Ping
    echo ""
    echo -e "  ${CYAN}[Ping: $HOST]${NC}"
    if ping -c 3 -W 3 "$HOST" 2>/dev/null; then
        pass "Ping 성공"
    else
        fail "Ping 실패"
    fi

    # DNS 조회 (host)
    echo ""
    echo -e "  ${CYAN}[DNS - host: $HOST]${NC}"
    if host "$HOST" 2>/dev/null; then
        pass "host 조회 성공"
    else
        fail "host 조회 실패"
    fi

    # DNS 조회 (nslookup)
    echo ""
    echo -e "  ${CYAN}[DNS - nslookup: $HOST]${NC}"
    if nslookup "$HOST" 2>/dev/null; then
        pass "nslookup 조회 성공"
    else
        fail "nslookup 조회 실패"
    fi

    # DNS 조회 (dig)
    echo ""
    echo -e "  ${CYAN}[DNS - dig: $HOST]${NC}"
    dig "$HOST" 2>/dev/null | sed 's/^/  /' || fail "dig 조회 실패"

    # CSE 로컬 DNS 리졸버 직접 조회
    echo ""
    echo -e "  ${CYAN}[DNS - dig @127.0.0.5 (CSE 로컬 리졸버): $HOST]${NC}"
    dig @127.0.0.5 "$HOST" 2>/dev/null | sed 's/^/  /' || fail "CSE 로컬 DNS 리졸버 조회 실패"

    # TCP 포트 테스트
    if [[ -n "$PORT" ]]; then
        echo ""
        echo -e "  ${CYAN}[TCP 포트: $HOST:$PORT]${NC}"
        if nc -z -w 5 "$HOST" "$PORT" 2>/dev/null; then
            pass "포트 $PORT 연결 성공"
        else
            fail "포트 $PORT 연결 실패"
        fi
    fi

    # HTTP 연결 테스트
    echo ""
    echo -e "  ${CYAN}[HTTP: http://$HOST]${NC}"
    curl -v --connect-timeout 5 "http://$HOST" 2>&1 | tail -20 | sed 's/^/  /' || true

    echo ""
    echo -e "  ${CYAN}[HTTPS: https://$HOST]${NC}"
    curl -v --connect-timeout 5 "https://$HOST" 2>&1 | tail -20 | sed 's/^/  /' || true

    echo ""
    echo -e "  ${CYAN}[HTTPS 응답 요약: https://$HOST]${NC}"
    CURL_RESULT=$(curl -s --connect-timeout 10 -o /dev/null -w "HTTP %{http_code} | connect: %{time_connect}s | total: %{time_total}s" "https://$HOST" 2>/dev/null || true)
    if [[ -n "$CURL_RESULT" ]]; then
        echo -e "  $CURL_RESULT"
        if echo "$CURL_RESULT" | grep -q "HTTP 0"; then
            fail "HTTPS 연결 실패 (타임아웃 또는 연결 불가)"
        else
            pass "HTTPS 응답 수신"
        fi
    else
        fail "curl 실행 실패"
    fi
}

# --------------------------------------------------
print_header "6단계: 서버 연결 테스트"
# --------------------------------------------------

# 기본 도메인 테스트
for HOST in "${DEFAULT_HOSTS[@]}"; do
    test_server "$HOST"
done

# 추가 서버 테스트 (인자로 전달된 경우)
if [[ -n "$EXTRA_HOST" ]]; then
    test_server "$EXTRA_HOST" "$EXTRA_PORT"
fi

# --------------------------------------------------
print_header "진단 요약"
# --------------------------------------------------
echo ""
echo "  문제가 지속되면 다음을 수행하세요:"
echo "  1. CSE 앱 > Settings > Health Check > Run Diagnostic Tool"
echo "  2. 'Send Log Files to SonicWall CSE Support' 클릭"
echo "  3. 위 출력 결과를 벤더에 전달"
echo ""
