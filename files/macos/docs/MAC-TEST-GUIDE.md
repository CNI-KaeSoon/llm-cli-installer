# 맥 실기기 시험 가이드 (릴리스 게이트)

릴리스 전에 실제 맥에서 직접 시험합니다. 자동 테스트와는 별개입니다.

## 준비

- 깨끗한 macOS 사용자 계정 (가능하면 arm64와 x86_64 각 1대)
- 네트워크 연결
- Safari로 받은 배포 ZIP

## 시험 항목

각 항목마다 결과, 종료 코드, 출력 일부, `summary.json`의 버전 기록을 남깁니다.

1. ZIP을 풀었을 때 최상위에 `installer-win.bat`, `installer-mac.command`, `README.md`, `files`만 보이는지 확인합니다.
2. 터미널에서 `bash `를 입력하고 `installer-mac.command`를 끌어다 놓아 실행합니다.
3. 메뉴에서 `1`만 고릅니다. Codex만 설치되는지, `ls ~/.local/bin`으로 확인합니다.
4. 메뉴에서 `2`, `3`, `4`를 각각 시험합니다.
5. 같은 선택을 다시 실행합니다. 새로 설치되는 것이 0건이어야 합니다.
6. `2`를 고르고 `n`을 입력한 뒤 `0`으로 종료합니다. 실행 전후의 `ls -la ~` 결과를 비교해 차이가 없어야 합니다.
7. 더블클릭 → 차단 → 시스템 설정의 `그래도 열기` → 다시 실행합니다.
8. `agy --version`, `grok --version`, `codex --version`, `claude --version`의 실제 출력을 기록합니다(카탈로그의 `version_args` 확정용).
9. 새 터미널에서 네 명령을 실행합니다.

## 기록 위치

프로젝트의 `09_logs/macos/<YYMMDD>_mac-real-device.md`에 적습니다. 자동 테스트 결과와 섞지 않습니다.
