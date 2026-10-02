# LLM CLI 설치기

Codex, Claude Code, Antigravity, Grok 중 고른 것만 공식 배포처에서 설치합니다.

## 폴더 구성

| 이름 | 설명 |
| --- | --- |
| `installer-win.bat` | Windows에서 실행합니다. |
| `installer-mac.command` | 맥에서 실행합니다. |
| `README.md` | 이 안내입니다. |
| `files` | 설치기 내부 파일입니다. 건드리지 마세요. |

## Windows에서 설치

1. 받은 ZIP을 오른쪽 클릭하고 `모두 압축 풀기`를 고릅니다. ZIP 안에서 바로 실행하지 말고 먼저 압축을 풉니다.
2. 풀린 폴더에서 `installer-win.bat`을 더블클릭합니다.
   - `Windows의 PC 보호` 창이 뜨면 `추가 정보` → `실행`을 누릅니다. `열린 파일 - 보안 경고` 창이 뜨면 `실행`을 누릅니다. (압축을 풀기 전에 ZIP 파일 오른쪽 클릭 → 속성 → `차단 해제`를 체크하면 이 창이 뜨지 않습니다.)
3. 메뉴에서 번호를 고릅니다(예: `1,3`). Enter만 누르면 전체가 선택됩니다(다음 확인 화면에서 N으로 되돌릴 수 있습니다).
4. 확인 화면에 고른 CLI와 함께 설치될 수 있는 항목(예: Claude Code에 필요한 Git)이 나옵니다. 확인하고 `Y`를 입력합니다.
5. 끝나면 새 터미널(PowerShell)에서 설치한 CLI의 명령(예: `codex`)을 실행합니다.

자세한 내용은 `files/README.md`를 보세요.

## Mac에서 설치

1. ZIP을 더블클릭해 압축을 풉니다.
2. 응용 프로그램 > 유틸리티 > 터미널을 엽니다.
3. `bash ` 를 입력합니다(뒤에 공백 한 칸).
4. 풀린 폴더의 `installer-mac.command`를 터미널 창으로 끌어다 놓습니다.
5. Enter를 누릅니다.
6. 메뉴에서 번호를 고르고, 설치 계획을 확인한 뒤 `Y`를 입력합니다.
7. 끝나면 새 터미널 창을 열고 설치한 CLI의 명령(예: `codex`)을 실행합니다.

- 직접 입력할 때는 다음과 같이 씁니다: `bash installer-mac.command`
- 더블클릭으로 열면 처음에 macOS가 막습니다. 시스템 설정 → 개인정보 보호 및 보안에서 `그래도 열기`를 누르고 다시 더블클릭하세요.

자세한 내용은 `files/macos/README.md`를 보세요.

## 메뉴

```

설치할 CLI를 선택하세요.
  1) Codex CLI (OpenAI)
  2) Claude Code (Anthropic)
  3) Antigravity CLI (Google 개인 계정, Gemini CLI 후속)
  4) Grok CLI (xAI)
  5) 전체 설치 (1~4 모두)
  0) 설치하지 않고 종료
```

여러 개는 쉼표로 구분합니다(예: 1,3). Enter만 누르면 전체가 선택됩니다(다음 확인 화면에서 N으로 되돌릴 수 있습니다).

고른 CLI와 그 CLI에 꼭 필요한 항목(Windows: Claude Code→Git, Grok→Node.js)만 설치하며, `Y`를 입력하기 전에는 아무것도 바꾸지 않습니다. `0`을 고르면 그대로 종료합니다.

## 설치 뒤

처음 실행하면 각 CLI가 로그인 방법을 안내합니다. 이 설치기는 로그인 정보를 받지 않습니다.

## 문제가 생기면

화면 마지막의 종료 코드와 "진단 기록" 폴더를 확인하세요.

- Windows: `files/docs/TROUBLESHOOTING.md`
- Mac: `files/macos/docs/TROUBLESHOOTING.md`
