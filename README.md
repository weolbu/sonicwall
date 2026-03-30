# SonicWall CSE Service Tunnel Diagnostic Scripts

SonicWall CSE(Cloud Secure Edge) 환경에서 Service Tunnel이 동작하지 않거나 특정 서버에 접근이 안 될 때 사용하는 자동 진단 스크립트입니다.

## 사전 준비

> **반드시 SonicWall CSE 앱에서 Service Tunnel을 활성화한 상태에서 실행하세요.**

1. SonicWall CSE (Banyan) 앱을 실행합니다.
2. 홈 화면에서 **Service Tunnel**을 선택합니다.
3. **파란색 Power 버튼**을 눌러 "Connected" 상태로 만듭니다.
4. 터널이 연결된 것을 확인한 후 아래 스크립트를 실행합니다.

터널이 꺼진 상태에서는 peer 연결이 없어 진단 결과가 무의미합니다.

---

## 사용법

### macOS

```bash
# 기본 진단
curl -sL https://raw.githubusercontent.com/weolbu/sonicwall/main/sonicwall-diag-mac.sh | sudo bash

# 특정 서버 연결 테스트
curl -sL https://raw.githubusercontent.com/weolbu/sonicwall/main/sonicwall-diag-mac.sh | sudo bash -s -- <서버IP>

# 서버 + 포트 테스트
curl -sL https://raw.githubusercontent.com/weolbu/sonicwall/main/sonicwall-diag-mac.sh | sudo bash -s -- <서버IP> <포트>
```

**예시:**
```bash
curl -sL https://raw.githubusercontent.com/weolbu/sonicwall/main/sonicwall-diag-mac.sh | sudo bash -s -- 10.50.1.100 3306
```

### Windows (관리자 PowerShell)

```powershell
# 기본 진단
irm https://raw.githubusercontent.com/weolbu/sonicwall/main/sonicwall-diag-win.ps1 | iex

# 특정 서버 연결 테스트
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/weolbu/sonicwall/main/sonicwall-diag-win.ps1))) "서버IP"

# 서버 + 포트 테스트
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/weolbu/sonicwall/main/sonicwall-diag-win.ps1))) "서버IP" "포트"
```

**예시:**
```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/weolbu/sonicwall/main/sonicwall-diag-win.ps1))) "10.50.1.100" "3306"
```

> Windows에서 실행 정책 오류가 나면 먼저 `Set-ExecutionPolicy Bypass -Scope Process -Force` 를 실행하세요.

---

## 진단 항목

| 단계 | 내용 | 확인 기준 |
|------|------|-----------|
| 1 | CSE 앱 설치 확인 | WireGuard 바이너리 존재 여부 |
| 2 | WireGuard 서비스 상태 | 실행 중이 아니면 자동 재시작 시도 |
| 3 | 터널 연결 상태 | peer 존재, handshake 180초 이내, transfer 증가 |
| 4 | DNS 설정 | 내부 도메인이 올바른 DNS로 해석되는지 |
| 5 | 서버 연결 테스트 | ping, DNS 조회, TCP 포트 연결 |

---

## 결과 해석

### Handshake 기록 없음
- Service Tunnel이 **꺼져있거나** peer 설정이 내려오지 않은 상태입니다.
- CSE 앱에서 Service Tunnel Power 버튼을 켜고 다시 실행하세요.

### Handshake 180초 초과
- 터널이 불안정합니다. 네트워크 상태를 확인하거나 서비스를 재시작하세요.

### 특정 서버만 접속 불가
- `wg` 출력의 **allowed ips**에 해당 서버 IP가 포함되어 있는지 확인하세요.
- 포함되어 있지 않다면 CSE 관리자에게 해당 IP/CIDR을 터널 정책에 추가 요청해야 합니다.

### DNS 조회 실패
- CSE 터널 DNS 설정에서 해당 도메인이 누락되었을 수 있습니다. 관리자에게 문의하세요.

---

## 스크립트가 변경하는 것

이 스크립트는 **읽기 전용 진단**이 기본입니다. 유일한 예외:

- WireGuard 서비스(`banyan-wgs`)가 **꺼져있을 때만** 재시작을 시도합니다.
- 그 외에는 시스템에 아무런 변경을 하지 않습니다.

---

## 해결이 안 될 때

1. CSE 앱 > **Settings** > **Health Check** > **Run Diagnostic Tool**
2. **Send Log Files to SonicWall CSE Support** 클릭
3. 이 스크립트의 출력 결과를 함께 벤더에 전달

참고: [SonicWall CSE Service Tunnel Troubleshooting (공식 가이드)](https://www.sonicwall.com/ko-kr/support/knowledge-base/sonicwall-cse-service-tunnel-troubleshooting/kA1VN0000000UED0A2)
