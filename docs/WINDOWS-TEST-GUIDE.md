# Windows 11 x64 시험 가이드 (v2)

폐기 가능한 VM을 우선 사용하세요. 실제 노트북에서는 기존 도구를 제거하거나 설정을 초기화하지 않습니다.

1. Windows build, x64 여부, Windows PowerShell 5.1, 관리자 여부만 기록합니다. 전체 환경 변수는 수집하지 않습니다.
2. 기존 `pwsh`, `git`, `node`, `npm`, `python`, `codex`, `claude`, `agy`/`antigravity`, `grok` 버전을 기록합니다.
3. 앱 폴더만 별도 경로에 복사하고 `install.ps1 -Components all -NonInteractive -WhatIf`로 기존 설치 미리보기를 먼저 확인합니다.
4. `install.ps1 -Components all`을 실행하고 UAC, 진행 단계, 종료 코드, 로그와 지원 ZIP 경로를 기록합니다. 로그인하거나 API 키를 입력하지 않습니다.
5. 새 Windows Terminal에서 모든 버전 명령을 다시 실행합니다. `gemini --version`은 Legacy Gemini를 명시 선택한 시험에서만 실행합니다.
6. 같은 명령을 재실행하고 설치/제거 호출 없이 모두 skip 후 verify되는지 확인합니다.
7. 지원 ZIP을 해제해 심어 둔 테스트 marker, 토큰, 쿠키, 암호, 사용자 이름이 없는지 검사합니다.
8. 앱 폴더만 ZIP으로 만들고 다른 경로에 해제한 뒤 module import, `-WhatIf`, Pester를 반복합니다.

## 필수 시나리오 (v1)

- 깨끗한 Windows 11 x64 표준 사용자에서 `all`
- 2회차 멱등 실행
- UAC 거부, 네트워크 차단, PATH 지연, 설치기 raw 3010, 일부 CLI 실패
- Python 3.11 이하 또는 없음 → Manager 설치 → 3.14 list 확인 → exec 검증
- Node 없음에서 `antigravity` 선택 시 Node 설치 호출 0건
- `all`에서 Legacy Gemini npm 호출 0건
- `legacy-gemini -AllowLegacyGemini` 고급 경로

## 이전(v2) 시나리오

1. custom npm prefix의 Grok/Legacy Gemini: keep 후 무변경, `-ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok` 후 공식 npm 제거와 정본 재설치.
2. npm Codex/Claude 단일 P3 후보: 명시 이전; `.codex`/`.claude` 파일 hash 유지.
3. portable/수동 복사 CLI: keep 성공, migrate 61/63, 파일 불변.
4. 동일 명령 후보 2개: 62, 제거 0건.
5. junction/symlink 후보: 64, 대상 불변.
6. 실행 중 잠긴 binary: 64, 강제 종료 없음.
7. 제거 뒤 네트워크 차단: 66, 복구 명령 출력, 재실행 시 제거 없이 재설치.
8. 외부 프로세스가 사용자 PATH를 동시 수정: 67, 외부 변경 보존.
9. Python Manager 정확한 tag 이전과 unmanaged Python keep-only.
10. 설치기 두 개 동시 실행: 두 번째는 65, 변경 0건.
11. committed 이전 뒤 재실행: 설치/제거 0건.

## 증거 기록

실행 ID, OS build, 앱 `manifest.sha256`, 선택 구성요소, 시작 상태, 명령, 종료 코드, 지원 ZIP SHA256를 기록합니다. 실제 Windows 증거가 없으면 결과를 “mock/static 검증, Windows E2E NOT_RUN”으로만 표시합니다.

## 보류 항목 (Deferred / Windows-only)

다음은 Windows 실기기 없이는 검증할 수 없어 이번 수정 라운드에서 구현하지 않았습니다. 이전(migration) 기능은 §14.8 release gate(`$script:MigrationGateOpen = $false`)로 비활성 상태이며, 아래 항목과 위 이전 시나리오를 Windows 11에서 확인한 뒤에만 gate를 엽니다.

- User PATH 복원 시 `REG_EXPAND_SZ` 형식(미확장 `%VAR%` 항목) 보존.
- npm을 `cmd.exe`로 실행할 때 인자의 cmd 메타문자(`&`, `|`, `^`, `%` 등) quoting.
- 실제 `pymanager list --only-managed --format=json` 출력으로 inventory가 관리 런타임에 도달하는지 확인.
- UacHelper elevation 경로 연결(설치 전용)과 UAC 거부/시간 초과 동작.
- 공식 설치 스크립트 redirect(Codex→releases.openai.com, Claude→downloads.claude.ai) 실제 설치 성공과 로그의 downloadSha256/executedSha256 확인.
- hostile npm prefix(cmd 메타문자) 거부와 npm.cmd 정상 설치.
- timeout 시 하위 프로세스 잔존 여부(process tree 종료 미구현).
- Anthropic/OpenAI 서명 인증서의 실제 O 값.
- 이전 gate를 열기 전 필수: RemovalStarted 복구 판정을 journal prefix 직접 조회로 강화, 복구 불가 journal 정리 절차, PATH snapshot 정리.
