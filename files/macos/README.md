# LLM CLI 설치기 (Mac)

## 소개

고른 CLI만 공식 설치 스크립트로 설치합니다. 관리자 암호를 묻지 않고, 로그인 정보를 받지 않습니다. macOS 13 이상, Apple Silicon과 Intel 모두 지원합니다.

## 받기와 확인

1. GitHub Release에서 ZIP과 `.sha256` 파일을 받습니다.
2. 터미널에서 `shasum -a 256 <ZIP 파일>`을 실행합니다.
3. 출력된 값이 `.sha256` 파일 내용과 같은지 비교합니다.

같은 Release에서 받으므로 손상 확인용일 뿐, 진위를 증명하지는 않습니다.

## 실행(권장)

1. ZIP을 더블클릭해 압축을 풉니다.
2. 응용 프로그램 > 유틸리티 > 터미널을 엽니다.
3. `bash ` 를 입력합니다(뒤에 공백 한 칸).
4. `installer-mac.command`를 터미널 창으로 끌어다 놓습니다.
5. Enter를 누릅니다.
6. 메뉴에서 번호를 고르고 `Y`를 입력합니다.
7. 끝나면 새 터미널 창에서 설치한 CLI의 명령(`codex`, `claude`, `agy`, `grok` 중 설치한 것)을 실행합니다.

직접 입력할 때는 다음과 같이 씁니다.

```
bash installer-mac.command
```

## 더블클릭으로 실행하려면

1. `installer-mac.command`를 더블클릭하면 macOS가 막습니다.
2. 시스템 설정 → 개인정보 보호 및 보안으로 갑니다.
3. 보안 항목의 `그래도 열기`를 누릅니다.
4. 관리자 암호를 입력합니다.
5. 다시 더블클릭합니다.

macOS 15부터는 Control-클릭 → 열기로는 우회되지 않습니다. 설치기는 이 보안 표시를 지우지 않습니다.

## 메뉴 사용법

```

설치할 CLI를 선택하세요.
  1) Codex CLI (OpenAI)
  2) Claude Code (Anthropic)
  3) Antigravity CLI (Google 개인 계정, Gemini CLI 후속)
  4) Grok CLI (xAI)
  5) 전체 설치 (1~4 모두)
  0) 설치하지 않고 종료
여러 개는 쉼표로 구분합니다(예: 1,3). 아무것도 입력하지 않고 Enter를 누르면 전체를 고릅니다.
```

- 쉼표로 여러 개를 고를 수 있습니다(예: `1,3`). Enter만 누르면 전체입니다.
- 설치 계획 확인에서 `Y`를 입력할 때만 설치합니다.
- `N`을 입력하면 다시 고릅니다.
- `0`을 고르면 아무것도 바꾸지 않고 종료합니다.

## 옵션

```
사용법: installer-mac.command [옵션]
  옵션 없이 실행하면 설치할 CLI를 번호로 고르는 메뉴가 나옵니다.
  --components <목록>   메뉴 없이 설치할 CLI 지정 (예: codex,claude). 이름: codex, claude, antigravity, grok, all
  --yes                 확인 질문 없이 진행 (--components와 함께만)
  --non-interactive     질문하지 않음 (--components와 --yes 필요)
  --dry-run             설치하지 않고 계획만 보여 줌
  --log-root <폴더>     로그 저장 위치 변경
  --version             설치기 버전 출력
  --help                이 도움말 출력
```

예:

```
bash installer-mac.command --components codex,claude
bash installer-mac.command --components all --dry-run
```

## 설치 위치

| CLI | 실행 파일 | 설정 폴더 |
| --- | --- | --- |
| Codex | `~/.local/bin/codex` | `~/.codex` |
| Claude Code | `~/.local/bin/claude` | `~/.claude` |
| Antigravity | `~/.local/bin/agy` | `~/.gemini/antigravity-cli` |
| Grok | `~/.grok/bin/grok` (`agent` 명령도 생성) | `~/.grok` |

설치기는 확인을 받은 뒤에만 셸 설정 파일을 바꿉니다. zsh에서는 `~/.zprofile`(bash에서는 `~/.bash_profile`)에 표식 블록(`# >>> llm-cli-installer >>>`)을 한 번 추가하고, 원본을 `<파일>.llmcli-backup-<시각>`으로 남깁니다. 공식 설치 스크립트도 `~/.zprofile`·`~/.zshrc`를 바꿀 수 있습니다.

## 설치 뒤

새 터미널을 열고 명령(`codex`, `claude`, `agy`, `grok`)을 실행하세요. 처음 실행하면 각 CLI가 로그인 방법을 안내합니다.

## 이미 설치된 CLI

위치와 설치 방식에 관계없이 그대로 두고 버전만 확인합니다. 업데이트는 각 CLI의 자체 기능을 쓰세요.

## 보안

- 아래 공식 주소만 사용합니다.
  - Codex: `https://chatgpt.com/codex/install.sh`
  - Claude Code: `https://claude.ai/install.sh`
  - Antigravity: `https://antigravity.google/cli/install.sh`
  - Grok: `https://x.ai/cli/install.sh`
- 설치 스크립트를 파일로 받아 주소와 형식을 검사한 뒤 실행합니다.
- Codex, Claude Code, Antigravity 스크립트는 자체 해시 검증을 합니다. Grok 스크립트는 체크섬 검증이 없습니다(2026-10 조사).
- 관리자 권한을 쓰지 않습니다.
- 로그는 비밀값을 마스킹합니다.

## 로그

`~/Library/Logs/LLMCliInstaller/<시각>-<ID>/` 폴더에 저장됩니다.

- `run.log`
- `events.jsonl`
- `summary.json`
- `native/<id>-install.log`

다른 사람에게 공유하기 전에 내용을 확인하세요.

## 제거(수동)

각 CLI의 공식 안내를 따르세요.

- Codex: https://github.com/openai/codex/blob/main/docs/install.md
- Claude Code: https://code.claude.com/docs/en/setup
- Antigravity: https://antigravity.google/docs/cli/install
- Grok: https://docs.x.ai/build/overview

설치기가 추가한 블록은 `~/.zprofile`(zsh) 또는 `~/.bash_profile`(bash)에서 `# >>> llm-cli-installer >>>` 줄, `# <<< llm-cli-installer <<<` 줄, 그 사이 줄을 지우면 제거됩니다.

## FAQ

- 설치 중 암호를 묻거나 도구 설치 창(Xcode Command Line Tools)이 뜨면, 공급자 스크립트가 요청한 것입니다. 설치기는 관리자 권한을 쓰지 않으므로 취소해도 됩니다. Ctrl+C로 설치기를 멈출 수 있습니다.
- Git이 필요하다는 안내가 나오면 터미널에서 `xcode-select --install`을 실행하세요.
- Windows 사용자는 `installer-win.bat`을 쓰세요.
- 레거시 Gemini CLI는 맥 판에서 지원하지 않습니다.
