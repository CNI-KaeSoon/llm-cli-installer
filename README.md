# Windows LLM CLI Installer v2.0.1

Windows 11 x64에서 PowerShell 7, Git, Node.js LTS, Python 3.12+와 Codex CLI, Claude Code, Antigravity CLI, Grok CLI를 공식 배포처를 통해 설치하고 새 프로세스에서 버전을 검증합니다. v2는 비표준 위치의 기존 설치를 **유지(기본)**하거나, 사용자가 명시적으로 선택한 경우 소유권이 증명된 항목만 공식 제거기로 제거한 뒤 정본 위치에 재설치(**이전**)합니다.

Google 계정의 기본 도구는 **Antigravity CLI**입니다. `all`, `google`, `gemini` 선택은 Antigravity를 설치하며 Legacy Gemini CLI를 설치하지 않습니다. Legacy Gemini는 지원되는 Enterprise/Google Cloud/유료 API 키 사용자가 고급 옵션으로 직접 선택할 때만 설치합니다.

## 빠른 시작

### 내려받은 ZIP 확인(권장)

GitHub Release에서 `llm-cli-installer-v2.0.1.zip`과 `llm-cli-installer-v2.0.1.zip.sha256`을 함께 내려받고, 압축을 풀기 전에 두 값이 같은지 확인합니다.

```powershell
(Get-FileHash .\llm-cli-installer-v2.0.1.zip -Algorithm SHA256).Hash.ToLower()
Get-Content .\llm-cli-installer-v2.0.1.zip.sha256
```

이 비교는 내려받는 중 파일이 손상됐는지만 확인합니다. ZIP과 `.sha256`은 같은 GitHub Release에서 받으므로 배포 채널이 변조되면 둘이 함께 바뀔 수 있고, 따라서 누가 만든 파일인지(진위)는 증명하지 않습니다. 자세한 한계는 [SECURITY.md](SECURITY.md)의 "릴리스 무결성"을 참고하세요.

`install.ps1`은 실행 전에 `manifest.sha256`의 모든 파일 hash와 추가 실행 파일 여부를 검사하며, 하나라도 다르면 종료 코드 23으로 멈춥니다.

### 실행

가장 쉬운 방법: 압축을 푼 폴더에서 `install.bat`을 더블클릭합니다. 모든 구성요소(`-Components all`)를 설치하고, 끝나면 종료 코드를 보여 준 뒤 창을 닫지 않고 기다립니다. 실행 정책은 이번 실행에만 `Bypass`로 적용되고 시스템 설정은 바뀌지 않습니다. 인자를 주면 그대로 `install.ps1`에 넘깁니다(예: `install.bat -Components codex,claude`).

`.\install.ps1`을 직접 실행하면 인터넷에서 받은 파일이어서 "디지털 서명되지 않았습니다" 오류로 막힐 수 있습니다. 이때는 `install.bat`을 쓰거나 아래 명령을 사용하세요.

PowerShell에서 직접 실행하려면 ZIP을 압축 해제한 디렉터리에서 Windows PowerShell 5.1을 열고 실행합니다.

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Components all
```

개별 선택 예:

```powershell
.\install.ps1 -Components codex,claude,antigravity,grok
.\install.ps1 -Components google
.\install.ps1 -Components legacy-gemini -AllowLegacyGemini
```

실제 변경 없이 계획과 기존 설치 진단(후보, 출처 등급, 정본 여부, 예상 제거기)만 확인:

```powershell
.\install.ps1 -Components all -NonInteractive -WhatIf
```

GitHub 원격 한 줄 부트스트랩은 저장소 소유자, 릴리스 URL과 고정 SHA256이 확정되기 전까지 제공하지 않습니다. 검증되지 않은 원격 스크립트를 `iex`로 실행하지 마세요.

## 기존 설치: 유지(A) 또는 이전(B)

> 현재 배포본에서는 Windows 11 실기기 검증 전까지 이전(B)이 비활성화되어 있습니다(release gate). `-ExistingInstallPolicy Migrate`는 변경 없이 종료 코드 2로 끝나고, 대화형에서는 이전 선택지를 묻지 않습니다. `-WhatIf` 미리보기만 가능합니다.

- **A 유지(기본)**: 파일, 패키지, PATH, 설정을 바꾸지 않고 발견된 실행 파일만 검증합니다.
- **B 이전**: 출처 등급 P3(패키지 관리자 소유가 독립적으로 증명됨)인 단일 후보만 공식 제거기로 제거하고 정본 위치에 재설치합니다. 대화형에서는 미리보기 뒤 정확히 `이전`을 입력해야 하며, 비대화형에서는 아래 세 옵션이 모두 필요합니다.

```powershell
.\install.ps1 -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok
```

- `all`은 설치 대상 선택일 뿐 이전 동의가 아닙니다. `-MigrationComponents`에 없는 구성요소는 유지됩니다.
- 허용되는 제거기는 `npm uninstall -g --prefix <기존 prefix> <package>`(Codex/Claude/Grok/Legacy Gemini의 npm 설치)와 `pymanager uninstall --yes <정확한 tag>`(관리형 Python)뿐입니다. 폴더 재귀 삭제, 프로세스 강제 종료, pymanager purge 옵션은 사용하지 않습니다.
- native Codex/Claude/Antigravity, PowerShell/Git/Node는 유지만 지원합니다. 이전은 관리자 권한을 요청하지 않습니다.
- `.codex`, `.claude`, `.gemini` 등 설정/인증/세션 경로는 읽거나 지우지 않습니다.
- 이전 기록은 `%LOCALAPPDATA%\LLMCliInstaller\State\migration-journal.jsonl`에 남으며, 중단된 이전은 다음 실행에서 먼저 복구합니다(완료된 제거는 반복하지 않음).

## 동작 원칙

- 기존 정상 설치는 건너뛰고 자동 다운그레이드·재부팅을 하지 않습니다. 제거는 위 이전(B) 경로에서만 일어납니다.
- PowerShell 7과 Python 3.12+는 독립 필수 항목입니다. Git은 Claude, Node 22+는 Grok과 명시 선택한 Legacy Gemini의 선행 항목입니다.
- Antigravity는 native 설치 경로이며 Node를 요구하지 않습니다.
- 공급자 설치 명령이 성공해도 새 프로세스의 버전 확인이 실패하면 성공으로 처리하지 않습니다.
- 로그인, API 키, 토큰, 쿠키를 요청하거나 저장하지 않습니다. 설치 후 인증은 각 CLI에서 사용자가 별도로 수행합니다.
- 실패한 구성요소와 독립적인 다른 구성요소는 계속 처리합니다.
- 보안 신뢰 경계와 알려진 잔여 위험은 [SECURITY.md](SECURITY.md)를 참고하세요.
- 알려진 제한: `-AllowUpgrade`는 현재 효과가 없습니다. 하한 미만의 Node.js는 검증 실패로 보고 공식 채널로 설치를 시도합니다.

## 로그와 지원 번들

기본 로그는 `%LOCALAPPDATA%\LLMCliInstaller\Logs\<run-id>`에 생성되며, 쓸 수 없으면 `%TEMP%` 아래로 한 번 대체합니다. 사람이 읽는 `run.log`, 구조화된 `events.jsonl`(schemaVersion 2), `summary.json`, 이전 미리보기 `migration-preview.json`, 마스킹된 journal 사본과 지원 ZIP을 생성합니다. 지속 기록 전에 알려진 비밀 패턴과 사용자 프로필 경로를 마스킹합니다.

문제 발생 시 [문제 해결](docs/TROUBLESHOOTING.md)과 [Windows 시험 가이드](docs/WINDOWS-TEST-GUIDE.md)를 참고하세요.

## 개발 검증

Pester 5와 PSScriptAnalyzer가 설치된 PowerShell 7에서:

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
.\tests\Run-Tests.ps1
.\tools\Update-Manifest.ps1   # 파일을 고친 뒤 반드시 실행(안 하면 install.ps1이 23으로 멈춤)
.\tools\New-ReleasePackage.ps1  # 깨끗한 git 작업 트리에서만. ZIP과 .sha256은 app 폴더 밖에 생성
```

실제 WinGet, npm, pymanager, UAC, Registry PATH, Python App Installer alias, 공식 설치기는 Windows 11 x64 VM 또는 실기기에서만 검증할 수 있습니다. 현재 상태: mock/static 검증 통과, Windows E2E NOT_RUN. Windows release gate 충족 전 배포본에서 이전 기능은 사용하지 마세요.
