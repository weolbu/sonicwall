# SonicWall CSE Service Tunnel - Windows Diagnostic & Fix Script
#
# Usage:
#   irm <URL> | iex                                              # 기본 진단만
#   & ([scriptblock]::Create((irm <URL>))) "10.0.1.50"           # 특정 서버 테스트
#   & ([scriptblock]::Create((irm <URL>))) "10.0.1.50" "8080"    # 서버 + 포트 테스트
#
# 또는 로컬 실행:
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   .\sonicwall-diag-win.ps1 10.0.1.50 8080

#Requires -RunAsAdministrator

param(
    [string]$TargetHost = "",
    [string]$TargetPort = ""
)

$ErrorActionPreference = "Continue"

function Print-Header($msg) { Write-Host "`n===== $msg =====" -ForegroundColor Cyan }
function Pass($msg)         { Write-Host "  [OK]   $msg" -ForegroundColor Green }
function Warn($msg)         { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Fail($msg)         { Write-Host "  [FAIL] $msg" -ForegroundColor Red }

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " SonicWall CSE Service Tunnel Diagnostics"   -ForegroundColor Cyan
Write-Host " Windows"                                     -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# --------------------------------------------------
Print-Header "1단계: Banyan 앱 설치 확인"
# --------------------------------------------------
$wgBin = "C:\Program Files\Banyan\resources\bin\wg.exe"

if (Test-Path $wgBin) {
    Pass "WireGuard 바이너리 존재: $wgBin"
} else {
    Fail "WireGuard 바이너리를 찾을 수 없습니다. CSE 앱이 설치되어 있는지 확인하세요."
    exit 1
}

# --------------------------------------------------
Print-Header "2단계: WireGuard 서비스(banyan-wgs) 상태 확인"
# --------------------------------------------------
$svc = Get-Service -Name "banyan-wgs" -ErrorAction SilentlyContinue

if ($null -eq $svc) {
    Fail "banyan-wgs 서비스가 등록되어 있지 않습니다. CSE 앱 재설치를 권장합니다."
} elseif ($svc.Status -eq "Running") {
    Pass "banyan-wgs 서비스 실행 중"
} else {
    Warn "banyan-wgs 서비스 상태: $($svc.Status). 재시작을 시도합니다..."
    try {
        Stop-Service -Name "banyan-wgs" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Start-Service -Name "banyan-wgs"
        Start-Sleep -Seconds 3

        $svc = Get-Service -Name "banyan-wgs"
        if ($svc.Status -eq "Running") {
            Pass "서비스 재시작 성공!"
        } else {
            Fail "서비스 재시작 실패. 상태: $($svc.Status)"
        }
    } catch {
        Fail "서비스 재시작 중 오류: $_"
    }
}

# --------------------------------------------------
Print-Header "3단계: WireGuard 터널 상태 확인"
# --------------------------------------------------
$wgOutput = ""
try {
    $wgOutput = & $wgBin 2>&1 | Out-String
} catch {
    $wgOutput = ""
}

if ([string]::IsNullOrWhiteSpace($wgOutput)) {
    Fail "WireGuard 인터페이스가 활성화되지 않았습니다."
    Write-Host "       -> CSE 앱에서 Service Tunnel Power 버튼을 켜주세요." -ForegroundColor Yellow
} else {
    Pass "WireGuard 인터페이스 활성 상태"
    Write-Host ""
    Write-Host "  --- WireGuard 상세 정보 ---" -ForegroundColor Cyan
    $wgOutput -split "`n" | ForEach-Object { Write-Host "  $_" }
    Write-Host ""

    # Handshake 검사
    $handshakeLine = ($wgOutput -split "`n") | Where-Object { $_ -match "latest handshake" }
    if ($handshakeLine) {
        if ($handshakeLine -match "(\d+)\s+seconds?\s+ago") {
            $secs = [int]$Matches[1]
            if ($secs -le 180) {
                Pass "Latest handshake: ${secs}초 전 (정상, 180초 이내)"
            } else {
                Warn "Latest handshake: ${secs}초 전 (180초 초과 - 터널 불안정 가능)"
            }
        } elseif ($handshakeLine -match "(\d+)\s+minute") {
            $mins = [int]$Matches[1]
            if ($mins -le 3) {
                Pass "Latest handshake: 약 ${mins}분 전 (정상 범위)"
            } else {
                Warn "Latest handshake: 약 ${mins}분 전 (터널 불안정 가능)"
            }
        } else {
            Warn "Handshake 시간 파싱 불가: $handshakeLine"
        }
    } else {
        Fail "Handshake 기록 없음 - 터널이 한 번도 연결되지 않았습니다."
    }

    # Transfer 검사
    $transferLine = ($wgOutput -split "`n") | Where-Object { $_ -match "transfer" }
    if ($transferLine) {
        Pass "Transfer: $($transferLine.Trim())"
    } else {
        Warn "Transfer 정보 없음"
    }

    # Allowed IPs
    $allowedLine = ($wgOutput -split "`n") | Where-Object { $_ -match "allowed ips" }
    if ($allowedLine) {
        Write-Host ""
        Write-Host "  [Allowed IPs - 터널 경유 대상 CIDR]" -ForegroundColor Cyan
        $allowedLine | ForEach-Object { Write-Host "  $($_.Trim())" }
    }

    # Endpoint
    $endpointLine = ($wgOutput -split "`n") | Where-Object { $_ -match "endpoint" }
    if ($endpointLine) {
        Write-Host ""
        Write-Host "  [Endpoint - Access Tier 주소]" -ForegroundColor Cyan
        $endpointLine | ForEach-Object { Write-Host "  $($_.Trim())" }
    }
}

# --------------------------------------------------
Print-Header "4단계: DNS NRPT 규칙 확인"
# --------------------------------------------------
Write-Host "  [NRPT 규칙 목록]" -ForegroundColor Cyan
try {
    $nrpt = Get-DnsClientNrptRule 2>$null
    if ($nrpt) {
        $nrpt | Format-Table -Property Namespace, NameServers, DisplayName -AutoSize |
            Out-String | ForEach-Object { $_ -split "`n" } |
            ForEach-Object { Write-Host "  $_" }
    } else {
        Warn "NRPT 규칙 없음"
    }
} catch {
    Warn "NRPT 규칙 조회 실패: $_"
}

# --------------------------------------------------
Print-Header "5단계: 특정 서버 연결 테스트"
# --------------------------------------------------
if (![string]::IsNullOrWhiteSpace($TargetHost)) {
    Write-Host ""
    Write-Host "  [Ping 테스트: $TargetHost]" -ForegroundColor Cyan
    $pingResult = Test-Connection -ComputerName $TargetHost -Count 3 -Quiet -ErrorAction SilentlyContinue
    if ($pingResult) {
        Pass "Ping 성공"
    } else {
        Fail "Ping 실패"
    }

    Write-Host ""
    Write-Host "  [DNS 조회: $TargetHost]" -ForegroundColor Cyan
    try {
        $dns = Resolve-DnsName -Name $TargetHost -ErrorAction Stop
        Pass "DNS 조회 성공"
        $dns | Format-Table -Property Name, Type, IPAddress -AutoSize |
            Out-String | ForEach-Object { $_ -split "`n" } |
            ForEach-Object { Write-Host "  $_" }
    } catch {
        Fail "DNS 조회 실패 - DNS 설정을 확인하세요"
    }

    if (![string]::IsNullOrWhiteSpace($TargetPort)) {
        Write-Host "  [TCP 포트 테스트: ${TargetHost}:${TargetPort}]" -ForegroundColor Cyan
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $asyncResult = $tcp.BeginConnect($TargetHost, [int]$TargetPort, $null, $null)
            $wait = $asyncResult.AsyncWaitHandle.WaitOne(5000, $false)
            if ($wait -and $tcp.Connected) {
                Pass "포트 $TargetPort 연결 성공"
            } else {
                Fail "포트 $TargetPort 연결 실패 (5초 타임아웃)"
            }
        } catch {
            Fail "포트 $TargetPort 연결 실패: $_"
        } finally {
            $tcp.Close()
        }
    }
} else {
    Write-Host "  인자 없음 - 서버 테스트 건너뛰기"
    Write-Host "  사용법: .\sonicwall-diag-win.ps1 <서버IP> [포트]"
}

# --------------------------------------------------
Print-Header "진단 요약"
# --------------------------------------------------
Write-Host ""
Write-Host "  문제가 지속되면 다음을 수행하세요:"
Write-Host "  1. CSE 앱 > Settings > Health Check > Run Diagnostic Tool"
Write-Host "  2. 'Send Log Files to SonicWall CSE Support' 클릭"
Write-Host "  3. 위 출력 결과를 벤더에 전달"
Write-Host ""
