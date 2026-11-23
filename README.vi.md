# wreck-it-ralph

[English](README.md) · **Tiếng Việt**

> **Trạng thái: 0.0.8, bản pre-release.** Harness đã được kiểm bằng bộ test của chính nó (`bash tests/run-tests.sh`) và một lần chạy end-to-end nhỏ (một API Python, hai session, ba feature). Có thể còn lỗi vặt; hãy đọc mục [Giới hạn đã biết](#giới-hạn-đã-biết) trước khi dựa vào nó. Số phiên bản nội bộ trước đây (3.x) đã được đặt lại về 0.0.1; xem `CHANGELOG.md`.
>
> Đây là bản dịch tiếng Việt của `README.md`. Nếu hai bản khác nhau, bản tiếng Anh là bản chuẩn.

Plugin Claude Code để xây phần mềm **từng bước, qua nhiều session**, kết hợp ba ý tưởng:

- **Long-running harness** (Anthropic, [Effective harnesses for long-running agents](https://www.anthropic.com/research/effective-harnesses-for-long-running-agents)):
  - Mỗi session chạy trong context mới.
  - Initializer viết danh sách feature, `init.sh`, progress log và lịch sử git.
  - Mỗi session sau làm đúng một feature, kiểm tra end-to-end rồi để lại cây git sạch.
- **Ralph loop** (Geoffrey Huntley): cứ đưa cùng một việc cho agent đến khi thật sự xong. Harness dùng nó làm vòng lặp trong: feature thất bại được thử lại trong context mới, và mỗi lần thử được cho biết lần trước hỏng vì sao.
- **Loop engineering**: bản thân vòng lặp là sản phẩm.
  - Luật dừng, bộ kiểm tra, ngân sách và điểm chuyển cho người được khai báo trong config và được thực thi bằng script xác định (các *gate*), không để cho trí nhớ của model.
  - Agent viết code không bao giờ là agent quyết định code đó pass.

Plugin cũng kèm **Ralph loop** gốc trong session (`/wreck-it-ralph:ralph`) cho việc lặp nhanh một tác vụ đơn.

## Cài đặt

Repo này tự là một marketplace chứa một plugin (`.claude-plugin/marketplace.json`), nên Claude Code có thể cài thẳng từ GitHub hoặc từ một thư mục trên máy.

### Yêu cầu

- **Claude Code 2.1.275 trở lên** cho cách cài một bước `--marketplace`. Bản cũ hơn dùng cách hai bước bên dưới. Kiểm tra bằng `claude --version`.
- **`bash`**, **`git`** (đã đặt `user.name` và `user.email`), và **`jq`**.
- **macOS hoặc Linux.** Windows chưa được hỗ trợ vì script cần bash và công cụ POSIX; WSL có thể chạy nhưng chưa kiểm.
- **Tuỳ chọn:** `gh` (intake issue và pull request ở rollout L2) và `npx` (tester trình duyệt Playwright của preset `web`).

### Từ GitHub

Trong Claude Code:

```
/plugin install wreck-it-ralph --marketplace <owner>/wreck-it-ralph
```

Thay `<owner>/wreck-it-ralph` bằng repo GitHub chứa plugin. Tương đương từ terminal:

```bash
claude plugin install wreck-it-ralph --marketplace <owner>/wreck-it-ralph
```

Với Claude Code cũ, thêm marketplace trước rồi cài từ đó:

```
/plugin marketplace add <owner>/wreck-it-ralph
/plugin install wreck-it-ralph@wreck-it-ralph
```

### Từ thư mục trên máy

Cài vĩnh viễn từ một thư mục:

```bash
claude plugin install wreck-it-ralph --marketplace /path/to/wreck-it-ralph
```

Cài từ thư mục được đọc trực tiếp nên không có gì để cập nhật: sửa file có hiệu lực ở session kế tiếp, hoặc ngay lập tức với `/reload-plugins`.

Để thử trong một session mà không cài gì:

```bash
claude --plugin-dir /path/to/wreck-it-ralph
```

### Phạm vi (scope)

Mặc định cài vào user settings, nên plugin có mặt ở mọi dự án. Thêm `--scope project` để ghi vào `.claude/settings.json` của dự án, mọi người dùng repo đều nhận được. `--scope local` chỉ áp dụng cho dự án này trên máy bạn.

### Kiểm tra

Trong Claude Code chạy `/wreck-it-ralph:help`. Rồi trong một dự án, chạy `/wreck-it-ralph:setup --check` để kiểm tra điều kiện, hoặc `/wreck-it-ralph:doctor` khi đã có harness.

### Cập nhật hoặc gỡ

Với cài từ GitHub:

```bash
claude plugin update wreck-it-ralph@wreck-it-ralph
```

Gỡ (cả hai kiểu cài):

```bash
claude plugin uninstall wreck-it-ralph@wreck-it-ralph
```

Sau khi cập nhật, chạy `/wreck-it-ralph:setup --refresh` trong từng dự án. `/wreck-it-ralph:run` cũng tự làm khi bắt đầu, để các wrapper `.harness/*.sh` trỏ tới bản mới. Gỡ plugin không xoá thư mục `.harness/` của dự án.

> Nâng cấp từ `wreck-it-ralph-loop` 2.x:
> - Lệnh nay ngắn hơn (`/wreck-it-ralph:run` thay cho `/wreck-it-ralph-loop:harness-run`).
> - Các thư mục `.harness/` có sẵn vẫn chạy như cũ.
> - Chạy `/wreck-it-ralph:setup --refresh` một lần, rồi `/wreck-it-ralph:trust`, vì bản ghi trust nay còn bao gồm lệnh verify, các bước `use:` trong pipeline và hook.

## Bắt đầu nhanh

```bash
/wreck-it-ralph:init "Build a todo web app with auth, lists, and drag-and-drop"
/wreck-it-ralph:run                  # tương tác: subagent context mới ngay trong session này
/wreck-it-ralph:add "Export lists as CSV and import them back"   # thêm việc vào backlog bất cứ lúc nào
/wreck-it-ralph:backlog              # đề xuất, câu hỏi từ vòng lặp, độ ưu tiên
/wreck-it-ralph:run-headless         # không giám sát: các tiến trình `claude -p` riêng
/wreck-it-ralph:status
/wreck-it-ralph:cancel               # dừng sau session hiện tại
```

| Lệnh | Làm gì |
|---|---|
| `setup [--preset web\|cli\|none] [--check] [--refresh] [--force]` | Tạo hoặc sửa scaffold `.harness/`. Kiểm tra điều kiện, ghi config theo preset, wrapper và các dòng `.gitignore`. Chạy lại an toàn. |
| `init "<mục tiêu>" [--brownfield] [--preset P] [--branch NAME] [--allow-dirty]` | Chạy setup, rồi agent **initializer** viết `feature_list.json`, `init.sh` và `progress.md` (và `stop.sh` nếu init.sh khởi động server). Spec sau đó bị khoá và commit. `--brownfield` lập bản đồ code có sẵn trước. |
| `add "<yêu cầu>" [--approve]` | Agent **planner** biến yêu cầu thành các feature nhỏ, kiểm chứng được và nộp một **proposal**. Bạn xem (kể cả mọi lệnh verify) rồi duyệt. Dùng được ở mọi dự án đã khởi tạo, bất cứ lúc nào. |
| `backlog [list\|approve\|reject\|answer\|drop\|priority ...]` | Quản lý backlog sống: duyệt hoặc từ chối proposal, trả lời câu hỏi vòng lặp chuyển lên, bỏ hoặc đổi ưu tiên feature. |
| `trust` | Xem lại config do repo cung cấp (quyền, lệnh, MCP server, agent tuỳ biến, lệnh verify) và tin nó. |
| `run [--max-sessions N]` | Vòng lặp tương tác. Session này điều phối các subagent coder và tester context mới. |
| `run-headless [--max-sessions N] [--once]` | Vòng lặp không giám sát với các tiến trình `claude -p` riêng. |
| `status` / `cancel` / `help` | Tiến độ, câu hỏi và proposal / dừng sau session hiện tại / giải thích. `.harness/status.sh --json` là dạng máy đọc được. |
| `trigger cron\|launchd\|github\|loop [--every 2h] [--rollout L1]` | Bắt đầu run mà không cần bạn: in một dòng cron, ghi LaunchAgent hoặc workflow GitHub Actions (theo lịch, hoặc khi CI fail), hoặc một `/loop`. Mặc định rollout L1 với 3 session mỗi run. |
| `intake [github] [--label ralph]` | Biến issue GitHub mới có nhãn (hoặc mục của tracker khác qua công cụ MCP của nó) thành proposal của planner để bạn duyệt. |
| `demo <ID> [--run\|--example EX\|--step N\|--from A --to B\|--keep]` | Replay các example đã khoá của feature trên app đang chạy (liệt kê, tất cả, một cái, hoặc từng bước) và hiện expected so với actual. |
| `example <ID> "<case>"` | Đề xuất một example mới cho hợp đồng của feature. Nó chỉ vào spec sau khi bạn duyệt. |
| `doctor` | Kiểm tra sức khoẻ: công cụ, git, config, feature list, trust, wrapper, calibration, tester read-only, và mọi phần mở rộng pipeline (agent, skill của plugin khác) cùng hook có resolve được không. |
| `ralph "<prompt>" [--max-iterations N] [--completion-promise T]` / `cancel-ralph` | Ralph loop gốc trong session. |

Mọi lệnh đều có tiền tố: `/wreck-it-ralph:<lệnh>`.

## Một session chạy thế nào

```
begin gate ─▶ coder (mới) ─▶ verify gate ─▶ tester (mới) ─▶ [agent tuỳ biến] ─▶ end gate
   │             chỉ claim      chạy lệnh verify    vai duy nhất được      reviewer, cleaner,    khoá spec, cây sạch,
   │                            của feature         `pass`                 ...                   chuyển người, phát hiện kẹt
   └─ chọn feature SẴN SÀNG kế tiếp: chưa pass, không chờ người, mọi depends_on đã pass, theo độ ưu tiên
```

| Thành phần | Vai trò |
|---|---|
| **initializer** (`agents/initializer.md`) | Chạy một lần. Viết `feature_list.json` (tất cả `todo`), `init.sh`, `progress.md`. Không implement gì. |
| **planner** (`agents/planner.md`) | Chạy từ `/add`. Chia yêu cầu thành feature có `steps`, `verify`, `depends_on`, `tags` và nộp thành một proposal. Không implement và không duyệt gì. |
| **coder** (`agents/coder.md`) | Một feature mỗi session. Làm theo quy trình khởi động (progress, git log, `init.sh` + smoke test, hỏng thì sửa trước), implement, chạy lệnh verify, **claim**, commit, ghi log. Có thể `ask` người hoặc đề xuất tách feature thay vì đoán. |
| **verify gate** (`step.sh verify`) | Chạy `verify_static` (từ config) và các lệnh `verify` của feature **trong gate, không phải trong agent**. Nếu một lệnh fail, feature fail và tester bị bỏ qua. Log nằm ở `.harness/sessions/NNN-verify-<ID>.log`. |
| **curator** (`agents/curator.md`) | Mỗi 10 session (pipeline mặc định), chắt lọc `progress.md` và lịch sử lỗi thành `.harness/learnings.md`: lệnh chạy được, quy ước, cách tiếp cận đã thất bại, và các quyết định. Mọi agent đọc nó đầu tiên. |
| **tester** (`agents/tester.md`) | Người kiểm độc lập, đa nghi. Replay các example đã khoá trên app đang chạy, đọc các khoảng trống coverage và thăm dò chúng, kiểm tra known issues của coder, và ghi một trong bốn verdict (`pass`, `fail`, `blocked`, `inconclusive`) kèm bằng chứng. Chỉ đọc code sản phẩm. Là vai duy nhất đánh dấu feature `passing`. |
| **agent tuỳ biến** | Mọi `.harness/agents/<name>.md`; mẫu ở `templates/agents/` (`reviewer`, `cleaner`). Thêm vào pipeline bằng `every` / `when`. |
| **extension** | Các bước pipeline `use:` agent, skill, slash command của plugin khác hoặc lệnh shell chạy bởi gate. Xem "Làm việc với plugin khác". |
| **gates** (`scripts/harness-step.sh`) | Luật xác định dùng chung cho hai chế độ chạy: trust, khoá, kiểm tra cây bẩn và identity, giới hạn session, phát hiện kẹt, hàng đợi sẵn sàng, verify gate, reset pass chưa được tester xác minh, khoá spec, bảo vệ tester read-only, calibration, chuyển người và bản tóm tắt. |

### Backlog sống

`.harness/feature_list.json` là nguồn sự thật. Một feature trông như sau:

```json
{ "id": "F012", "category": "functional", "priority": 12,
  "description": "Export a list as CSV", "steps": ["Open a list", "Click Export", "The CSV has one row per item"],
  "verify": ["npm test -- -t 'csv export'"], "depends_on": ["F004"], "tags": ["export"],
  "status": "todo", "passes": false, "attempts": [] }
```

- **Trạng thái**: `todo`, `claimed`, `passing`, `failing`, `needs_human` hoặc `dropped`.
  - Agent chỉ đổi trạng thái qua `.harness/feature-list.sh claim|pass|fail|ask`.
  - `attempts[]` giữ 20 sự kiện gần nhất.
  - Tệp v2 chỉ có `passes`/`claimed` vẫn được đọc bình thường.
- **Spec bị khoá.** Nếu agent sửa spec (description, steps, verify, depends_on, ...), gate khôi phục lại.
- **Spec lớn lên qua proposal.**
  - `.harness/backlog.sh propose` (planner dùng, hoặc coder dùng để tách feature) ghi payload `add` / `amend` / `drop` vào `.harness/proposals.json`.
  - Người duyệt bằng `/wreck-it-ralph:backlog approve`: lệnh này kiểm tra kết quả, khoá lại spec và chỉ commit các file của harness.
  - Việc duyệt bị từ chối khi đang có session chạy. Nếu vẫn xảy ra (ví dụ agent sửa trực tiếp file khoá) thì bị hoàn tác ở `end`. Proposal được nộp trong session vẫn được giữ.
- **Amend một feature** đổi description, steps hoặc lệnh verify của nó và mở lại, kể cả khi nó đã pass.

### Chuyển cho người thay vì quay vòng

- **Hỏi người.** Coder hoặc tester cần một quyết định thì chạy `feature-list.sh ask <ID> "<câu hỏi>"`. Feature chờ ở `needs_human` và **vòng lặp tiếp tục với các feature khác**.
- **Tự chuyển.** Sau `escalate_after_failures` lần fail liên tiếp, đếm từ lần pass hoặc lần người trả lời gần nhất (mặc định 3, `0` là tắt), gate tự chuyển feature, lấy ghi chú lỗi cuối làm câu hỏi.
- **Trả lời.** Trả lời bằng `/wreck-it-ralph:backlog answer F012 "dùng UTF-8"`. Coder kế tiếp nhận câu trả lời, cùng ghi chú lỗi trước đó, trong thông điệp tác vụ.
- **Thử lại.** Mỗi lần thử lại một feature đã fail đều được báo vì sao lần trước hỏng và không được lặp lại cách đó.

### Mã dừng

| Mã | Lý do |
|---|---|
| 0 | Mọi feature pass (và `final_verify_command` thành công), hoặc cờ STOP (`/cancel`) |
| 2 | Đạt `max_sessions` |
| 3 | Kẹt: `stuck_limit` session liên tiếp không có feature pass mới hoặc chuyển người mới |
| 4 / 5 / 6 / 7 | Cây bẩn / config chưa được tin / chưa có git identity / đã có vòng lặp khác đang chạy |
| 8 | Mọi feature còn lại đang chờ người trả lời |
| 9 | Các feature còn lại có phụ thuộc không bao giờ pass (ví dụ một vòng phụ thuộc) |
| 10 | Hết ngân sách của run: `budget.max_cost_usd`, `max_tokens` hoặc `max_wall_minutes` |
| 11 | Một session thay đổi quá `budget.max_diff_lines` dòng và `on_large_diff` là `stop` (xem lại rồi chạy tiếp) |
| 12 | Lỗi nhánh rollout: detached HEAD, repo rỗng, hoặc nhánh bị đổi giữa chừng |
| 13 | Calibration thất bại: engine so sánh của replay để lọt một case sai đã biết (`calibrate.sh run`) |

### Ngân sách và ledger

Mọi lần chạy agent được ghi vào `.harness/ledger.jsonl` (bị git ignore).

**Cái gì được ghi:**
- **Chế độ headless** đọc cost, token, thời lượng và số lượt từ `claude -p --output-format json`.
  - JSON thô được giữ thành `NNN-<agent>.json` cạnh file `.log` dễ đọc.
  - Khi CLI cài đặt hỗ trợ `--max-budget-usd`, mỗi lời gọi còn bị giới hạn bởi phần ngân sách còn lại của run.
- **Chế độ tương tác** để bộ điều phối ghi số token và thời lượng mà công cụ Agent báo. Ở đó không có cost bằng đô la, nên dùng `max_tokens` và `max_wall_minutes` để giới hạn run tương tác. Mức dùng được báo bằng **token**, không phải đô la: `TOTAL = input + output + cache creation`; cache read hiện riêng (`CACHE_READ`) và không được tính. Cost chỉ xuất hiện khi CLI báo. `.harness/step.sh ledger report [--all] [--by session]` in bảng; các run trong session chỉ báo tổng, nên dòng của chúng được đánh dấu `*`. Ngân sách token (`max_tokens`) được kiểm giữa các agent, không bao giờ giữa một lời gọi; chỉ giới hạn bằng đô la mới có thể chặn cả một lời gọi đơn.

**Giới hạn hoạt động thế nào:**
- Ngân sách áp dụng **theo run**. Mỗi `run --new-run` bắt đầu ngân sách mới, nên nâng giới hạn hoặc chạy lại sẽ tiếp tục công việc.
- `0` nghĩa là không giới hạn.
- Các gate kiểm giới hạn trước mỗi session và sau khi nó kết thúc.
- `/status`, các dòng log theo session và `.harness/last-run.md` cho thấy đã tiêu bao nhiêu. `.harness/step.sh ledger total` in tổng.

## Test: example, replay, coverage

Tóm tắt dễ đọc bằng lời đơn giản: [docs/testing-and-verification.vi.md](docs/testing-and-verification.vi.md) ([English](docs/testing-and-verification.md)).

Phần test của harness dựa trên ba nguyên tắc: **không có bằng chứng thì không PASS**; **coverage là để nhìn thấy, không phải để chứng minh đúng**; và **agent chỉ ra khoảng trống, người quyết định**.

### Hợp đồng, example, replay

| Thuật ngữ | Nghĩa | Nằm ở đâu |
|---|---|---|
| Contract (hợp đồng) | Hành vi phải đúng | `description` của feature trong `feature_list.json` (bị khoá) |
| Example | Một trường hợp cụ thể của hợp đồng, dưới dạng dữ liệu | `examples[]` của feature (khoá cùng spec) |
| Replay | Cách chạy một example trên app thật | một adapter: `http` hoặc `cli` |

```json
"examples": [{
  "id": "EX001", "name": "empty cart", "description": "Reject checkout when the cart is empty",
  "input": {"method": "POST", "path": "/checkout", "body": {"items": []}},
  "expect": {"status": 400, "body": {"error": "cart cannot be empty"}},
  "assertions": {"status": "exact", "body": "partial"}
}]
```

- **Kiểu assertion:** `exact`, `partial` (giá trị mong đợi là tập con của giá trị thực), `contains`, `regex`. Mặc định là `exact`, hoặc `partial` khi giá trị mong đợi là object. `expect` phải kiểm được bằng máy; lời văn như "chạy đúng" không phải là oracle.
- **Adapter:** `http` nhận `{method, path, headers, query, body}` và so sánh `status`, `headers` (tên chữ thường) và `body`. `cli` nhận `{args, stdin, env}` và so sánh `exit_code`, `stdout`, `stderr`. Lệnh đến từ `replay.command` đã được tin, đối số truyền dưới dạng mảng, và một example không bao giờ chứa lệnh shell.
- **Luồng và fixture:** một example có thể có `steps` (chạy theo thứ tự, dừng ở lần fail đầu tiên), `setup` và `cleanup` (các bước fixture dùng cùng adapter). Tên có thể dùng `{{namespace}}`, một id riêng cho mỗi lần chạy, để cleanup chỉ xoá những gì lần chạy đó tạo ra. `--keep` để lại dữ liệu cho bạn kiểm tra.
- **Bị khoá:** example là một phần của spec. Coder hoặc tester không được sửa. Cái mới đến qua proposal (`/wreck-it-ralph:example`, hoặc `add_examples` trong một proposal) mà bạn duyệt; duyệt một cái sẽ đưa feature về `todo` vì hợp đồng của nó đã đổi.

### RED, rồi GREEN

Với feature có example, coder làm test trước. `.harness/feature-list.sh red <ID>` chạy các lệnh `verify` của feature **và replay các example** trên app đang chạy, và chỉ ghi RED nếu có gì đó fail. `claim` bị từ chối cho đến khi có RED. Khi hành vi đã tồn tại sẵn, coder dùng `red <ID> --skip "<lý do>"`, và tester thấy được điều đó.

### Bằng chứng của tester

`.harness/replay.sh <ID>` replay các example (exit 0 pass, 1 fail, 3 blocked: app không với tới được, 4 chưa cấu hình). Kết quả nằm ở `.harness/evidence/<ID>/<EX>/result.json` cùng commit, hash của example và output thực tế. Bằng chứng bị git ignore.

Tester đưa verdict bằng `.harness/report.sh <ID> <verdict> "<ghi chú>"`:

| Verdict | Nghĩa |
|---|---|
| `pass` | Đã kiểm và đúng. Bị từ chối trừ khi mọi example có replay pass từ lần chạy này. |
| `fail` | Đã kiểm và hỏng. Tính là một lần thử thất bại. |
| `blocked` | Không test được (app hoặc môi trường). Feature giữ nguyên trạng thái claimed và không tính lần thử. Nếu mọi feature claimed đều blocked, vòng lặp dừng với mã 9. |
| `inconclusive` | Chưa đủ bằng chứng; thành một câu hỏi cho bạn (`needs_human`). |

`fail` còn nhận `--findings <file.json>`: một mảng JSON các `{kind, criterion, input, expected, observed, severity}`. Findings được lưu trong `report.json` và nhắc lại trong tác vụ kế tiếp của coder, để coder nhận được điều tester quan sát thay vì một bản diễn đạt lại.

Cuối mỗi session, gate reset mọi feature có example đã pass mà không có bằng chứng replay đầy đủ. `report.json` và `report.md` trong thư mục evidence cho thấy các example, coverage và cách bạn tự replay.

### Tester chỉ đọc trên sản phẩm

Tester được thiết kế là người đánh giá độc lập, nên harness không để điều đó cho prompt. Khi tester bắt đầu, gate chụp dấu vân tay cây sản phẩm (mọi thứ ngoài `.harness/`, dưới dạng một git tree object); cuối session nó chụp lại.

- **File đã track bị sửa, hoặc một file mới bị commit:** gate trả mọi file về (và commit bản hoàn tác), reset mọi feature đã pass trong session đó về `failing` kèm lý do, và in `TESTER_EDITED=<files>`. Verdict từ một tester đã sửa code đang được kiểm không phải là bằng chứng.
- **Chỉ có file mới chưa track (rác từ probe):** chúng bị xoá và báo như cảnh báo; verdict vẫn giữ.
- Tester được ghi trong `.harness/` (evidence, `progress.md`, sửa `init.sh`) và trong một thư mục tạm. Một lỗi quay về coder dưới dạng `report.sh <ID> fail "..." --findings <file>`.
- `tester.allow_paths` (config) loại đường dẫn khỏi phép kiểm, ví dụ một thư mục fixture sinh tự động. `tester.read_only: false` tắt bảo vệ. Cả hai là một phần của config được tin.

Giới hạn: cơ chế này phát hiện và hoàn tác vi phạm sau khi xảy ra; nó không ngăn tiến trình tester ghi trong lúc session chạy. Chặn ở mức công cụ cần quyền ghi theo đường dẫn cho từng agent mà Claude Code không cung cấp cho agent của plugin. Dự án muốn ranh giới cứng có thể chạy bước tester trong một checkout riêng.

### Calibration người chấm

Một harness chỉ tốt bằng các verdict của nó, và lỗi nguy hiểm là **false positive**: evaluator nói PASS mà feature đang hỏng. `.harness/calibrate.sh` đo điều đó.

| Nguồn | Là gì | Sự thật (ground truth) lấy từ |
|---|---|---|
| `comparator` | Các case có đáp án biết trước đưa qua engine so sánh của replay (`scripts/harness-compare.jq`): input bình thường, input sai bị nhận, thiếu field, unicode, vi phạm hợp đồng, field thừa, regex, regression. Seed ở `.harness/calibration/cases.json`; bạn thêm case riêng. | trường `truth` của case |
| `scan` | Các feature tester đã pass nhưng sau đó fail. `calibrate.sh scan` liệt kê chúng thành candidate; bạn gắn nhãn từng cái `false_positive`, `regression` (đúng lúc pass, bị thay đổi sau đó làm hỏng) hoặc `dismiss`. | nhãn của bạn |
| `human` | `calibrate.sh record <ID> <evaluator> <truth> --case "..." --category <c>` cho một verdict sai bạn tự tìm ra. Tester cũng dùng nó khi nhận ra một PASS trước đó là sai. | bạn |

`calibrate.sh report` hiện false positive và tỉ lệ của nó (trên các case có truth là fail), false negative và tỉ lệ, tỉ lệ phát hiện regression, và độ phủ tiêu chí chấp nhận (số example đã khoá có bằng chứng replay pass còn hiệu lực, và số feature hoàn toàn không có example). `report --check` exit 1 khi vượt `calibration.max_false_positive_rate` (mặc định 0).

Gate dùng nó ở ba chỗ: một run mới từ chối bắt đầu (mã 13) nếu engine so sánh để lọt một case sai đã biết; mỗi session kết thúc bằng một lần quét và cảnh báo khi có feature đã pass rồi fail; và nếu agent sửa các case calibration thì chúng được khôi phục. `/wreck-it-ralph:doctor` và `status.sh` hiện các con số.

Điều chưa đo được: phán đoán của chính tester (phần LLM). Tỉ lệ false positive của nó chỉ đến từ nhãn `scan` và `record`, nên đầy đủ đến mức bạn gắn nhãn. Chạy planted-defect (cài một lỗi đã biết, kiểm tra tester có bắt được không) chưa được làm.

### Coverage

`.harness/coverage.sh run --id <ID>` chạy bộ test dưới coverage và ghi báo cáo đã chuẩn hoá vào `.harness/coverage/`.

| Stack | Cách làm |
|---|---|
| Python | `coverage.py` với `--branch`, từ `.venv` của dự án (không bao giờ cài giúp bạn) |
| Node | JSON Istanbul từ vitest, jest, c8 hoặc nyc, dùng binary trong `node_modules/.bin` |
| Go | `go test -coverprofile`; chỉ có statement, **không có dữ liệu branch** (`branches` là `null`, không bao giờ là 0%) |
| Khác | `coverage.cmd` ghi dữ liệu `coverage.py`, Istanbul hoặc Go-profile vào `$COVERAGE_JSON`, với `coverage.format` nêu định dạng |

- **Không bao giờ trộn phạm vi.** `repository.json` là cả repo; `<ID>.json` bao các file thay đổi từ khi session bắt đầu và nói rõ như vậy: đó là coverage của file thay đổi, không phải coverage của feature.
- **Gap.** `coverage.sh gaps <ID>` liệt kê các branch và dòng của diff chưa bao giờ chạy. Tester phân loại từng cái (`needs_example`, `redundant_code`, `defensive_branch`, `inconclusive`, hoặc `verified_by_probe` kèm bằng chứng về hành vi đã kiểm, không chỉ là branch đã được chạm tới) kèm mức tin cậy. Không có gì bị xoá vì một gap, và không có test nào được viết chỉ để nâng một con số.
- **Baseline và ratchet.** Người ghi `coverage.sh baseline` (được commit; gắn với một commit, phiên bản công cụ và dấu vân tay config). `coverage.sh ratchet` sau đó fail nếu coverage tụt, theo hai tầng: cả repo, và từng file thay đổi có mục trong baseline. File mới chỉ được báo cáo, đổi tên theo `git diff -M`, và so đúng tỉ lệ `covered/total`. Nếu thiếu baseline, config hoặc công cụ đã đổi, hoặc bộ test đang đỏ, kết quả là "không so sánh được" (exit 4) và không bao giờ chặn. `baseline --update` chỉ nâng lên; hạ xuống cần `--accept-decrease "<lý do>"`; cả hai bị từ chối trong một session của vòng lặp.
- **Chế độ.** `coverage.mode` mặc định là `report` (chỉ tham khảo). Với `"gate"`, một session mà các feature đã pass làm tụt coverage sẽ bị fail chúng.

### Giới hạn đã biết

- **Pre-release.** Một lần chạy end-to-end với agent thật trên một API Python nhỏ; ngoài ra không có gì. Các lệnh `jest`, `vitest`, `nyc` và toàn bộ đường Go (chỉ kiểm với profile viết tay) chưa chạy trên dự án thật. Các cơ chế mới (tester read-only, calibration, findings) mới được kiểm bằng test script, chưa chạy với `claude` thật.
- **Replay** chỉ hỗ trợ `http` và `cli`; không có adapter Playwright, nên dự án `web` chỉ được kiểm ở mức endpoint. Adapter `http` luôn gửi JSON, nên không gửi được body sai định dạng (`raw_body` chưa được làm).
- **Coverage tính theo session.** Khi nhiều feature được xác minh trong một batch, hoặc các coder chạy song song, gate không quy được một regression cho một feature và fail tất cả.
- **Mutation testing** và việc tự động kiểm test không có assertion chưa được làm. Xem `docs/ROADMAP-v4-testing.md`.
- **Calibration** chưa đo phần phán đoán của tester ngoài nhãn của bạn; chưa có planted-defect.
- **Bảo vệ tester read-only** là phát hiện và hoàn tác sau, không chặn ghi trong lúc chạy.

## Mở rộng quy mô và phạm vi

### Coder song song (headless)

```json
"parallel": { "max_workers": 3 }
```

Khi `max_workers > 1`, runner headless chia bước coder ra nhiều **git worktree** (`.harness/worktrees/<id>`, bị git ignore).

- **Chọn batch.** Batch là feature sẵn sàng kế tiếp cộng các feature sẵn sàng khác có `tags` không giao với batch. Feature không có tag không bao giờ chạy song song vì không biết vùng của nó, nên hãy gắn tag (`api`, `ui`, `db`, …) để cho phép.
- **Worker.** Mỗi worker là một coder headless context mới trên nhánh `harness/wt-<session>-<id>` riêng. Nó được dặn ở yên trong feature của mình và nhận phần ngân sách còn lại chia đều.
- **Cổng merge.** Sau khi mọi worker xong, từng nhánh được merge vào cây chính.
  - File spec và trạng thái không bao giờ merge. Gate tự áp dụng claim, câu hỏi hoặc proposal của từng worker, nên khoá spec vẫn nguyên vẹn.
  - `progress.md` dùng union merge của git.
  - Xung đột merge chỉ làm fail feature đó, kèm ghi chú. Nhánh được giữ để tham khảo, và lần thử sau bắt đầu từ code đã merge.
- **Sau merge.** Verify gate và tester sau đó kiểm mọi claim như thường.
- **Gián đoạn.** Worktree bỏ lại bởi một run bị ngắt được dọn ở run sau, và công việc của chúng được commit vào nhánh của chúng trước.

Run tương tác vẫn tuần tự, vì subagent không thể ghim đáng tin vào thư mục của một worktree.

### Bộ nhớ

- **`learnings.md`** ngắn và được tuyển chọn, mọi agent đọc nó trước `progress.md`. Curator viết lại nó mỗi 10 session.
- **Xoay vòng `progress.md`.** Vượt `progress_max_kb` (mặc định 64), gate chuyển các mục cũ sang `progress/archive-NNN.md`, cắt ở một tiêu đề mục, và giữ khoảng 150 dòng mới nhất.
- **`attempts[]`** của mỗi feature giữ lịch sử lỗi mà cả hai cái trên dựa vào.

### Preset và dự án có sẵn

`setup --preset` / `init --preset`:

| Preset | Pipeline | Hướng dẫn cho initializer và tester |
|---|---|---|
| `web` | coder → tester (+ Playwright MCP) → curator | các bước là thao tác trên trình duyệt |
| `api` | coder → tester → curator | các bước là HTTP request kèm status và body mong đợi |
| `cli` | coder → tester → curator | chạy lệnh, kiểm tra output và exit code |
| `data` | coder → tester → curator | chạy pipeline trên mẫu cố định, kiểm tra output |
| `docs` | coder → tester → curator | feature là các trang; verify bằng build docs và kiểm tra link |
| `library` | coder → curator (không có tester) | mỗi feature cần test `verify`: verify gate là người kiểm |
| `none` | coder | |

`init --brownfield "<mục tiêu>"` lập bản đồ code có sẵn:
- `init.sh` được viết từ lệnh build và run thật, và không sửa code sản phẩm.
- Hành vi thiết yếu đã chạy được ghi thành feature **baseline** (`status: claimed`, `source: baseline`). Tester xác minh chúng ở session 1, và sau đó chúng canh regression.
- Việc mới của mục tiêu nằm sau đó dưới dạng feature `todo`.

### Model theo bước và dọn dẹp

- **Model:** `"model"` trên một bước pipeline (ví dụ `{ "agent": "tester", "when": "claimed", "model": "haiku" }`) ghi đè model toàn cục cho bước đó. Run tương tác nhận `sonnet`, `opus`, `haiku` và `fable`; run headless truyền mọi tên model cho `claude -p`.
- **Model theo vai:** khối `agents` trong `.harness/config.json` đặt model cho từng vai. Mặc định: initializer, planner và tester dùng `opus` (người kiểm yếu để lọt pass sai), coder `sonnet`, curator `haiku`. **Nâng cấp:** `agents.coder.escalate_model` (mặc định `opus`) thay model của coder khi feature đích có `escalate_after` (mặc định 1) lần thử thất bại, trước khi `escalate_after_failures` giao nó cho người; `model` đặt trên bước pipeline ghim model và tắt nâng cấp. `.harness/step.sh ledger report [--all]` hiện số run, số lần nâng cấp, cost và token theo vai và model. Thứ tự ưu tiên: `model` của bước pipeline > `agents.<role>.model` > `model` cấp cao nhất > mặc định của session; `"inherit"` hoặc `""` nghĩa là không ghi đè. Khối này thuộc bản ghi trust.
- **Planner ở plan mode:** planner luôn chạy chỉ đọc (`tools: Read, Grep, Glob`, `--permission-mode plan` khi headless) và không config nào đổi được điều đó. Nó trả về một payload JSON; `/add` và `/intake` nộp bằng `backlog.sh propose`, và bạn vẫn là người duyệt. Headless: `.harness/run.sh --plan "<yêu cầu>"`. Agent của plugin không đặt được `permissionMode` trong frontmatter, nên chế độ này được thực thi bằng danh sách công cụ và runner.
- **`.harness/stop.sh`:** do initializer viết khi `init.sh` khởi động server. Gate chạy nó khi một vòng lặp kết thúc, và nó nằm trong phạm vi trust.

## Rollout, trigger và intake

Xây dựng lòng tin vào một vòng lặp từng bước, rồi để nó chạy mà không có bạn.

### Các mức rollout

Đặt `"rollout"` trong config, hoặc truyền `--rollout` cho `run` / `run-headless` / `.harness/run.sh`.

| Mức | Chuyện gì xảy ra | Nhánh của bạn |
|---|---|---|
| **L1 shadow** | Vòng lặp làm việc trên `harness/shadow-<time>`, rồi chuyển về và để lại một báo cáo (`last-run.md`, kèm số commit và diffstat). | không bao giờ bị chạm |
| **L2 assisted** | Vòng lặp làm việc trên `harness/run-<time>`. Với `rollout_push` nó push nhánh; với `rollout_pr` nó còn mở PR qua `gh`. Một run mới tiếp tục cùng nhánh nếu đang checkout nó. | không bao giờ bị chạm |
| **L3 unattended** | Vòng lặp commit trên nhánh hiện tại (mặc định và hành vi trước đây). | commit rơi vào đây |

- **Theo dõi:** nhánh gốc được ghi ở `git config branch.<run-branch>.harnessBase`.
- **Đổi nhánh:** nếu ai đó đổi nhánh giữa run, session kế tiếp dừng với mã 12 và cách sửa.
- **Trust:** `rollout_push` và `rollout_pr` thuộc bản ghi trust, vì chúng gửi code ra ngoài.

### Trigger

`/wreck-it-ralph:trigger` (hoặc `.harness/trigger.sh`) thiết lập các run bắt đầu mà không có bạn. Trigger mới mặc định **L1, 3 session mỗi run**: chuyển sang L2 khi các báo cáo shadow trông đúng. Không có gì được cài vào hệ thống của bạn thay bạn.

| Loại | Bạn nhận được |
|---|---|
| `cron --every 30m\|2h\|daily\|weekly` | một dòng crontab để thêm bằng `crontab -e` |
| `launchd --every …` | một plist LaunchAgent dưới `.harness/triggers/` (git ignore), kèm lệnh `launchctl load` |
| `github --cron "0 3 * * *" [--on-failure "CI"] --plugin-repo owner/name` | `.github/workflows/wreck-it-ralph.yml`, xem dưới |
| `loop --every 2h` | lệnh `/loop 2h /wreck-it-ralph:run …` cho một session tương tác đang mở |

Workflow GitHub:
- chạy headless với `ANTHROPIC_API_KEY`;
- mở PR ở L2, hoặc chỉ tải báo cáo lên ở L1;
- từ chối L3, để CI không bao giờ commit lên nhánh mặc định;
- chấp nhận config `.harness` đã commit mà không qua bước duyệt trust tương tác, nên chỉ dùng nếu thay đổi trong `.harness/` đi qua code review. File nói rõ điều này ở đầu.

### Intake từ issue tracker

`/wreck-it-ralph:intake` lấy các issue mở mới có nhãn `ralph` (`--label`, `--limit`, `--repo`) bằng `gh`. Với Linear, Jira và các tracker khác, nó dùng công cụ MCP của tracker đó nếu đã kết nối.
- Mỗi issue đi tới planner và thành một proposal `by intake:github#12`.
- Id đã nhập được ghi ở `.harness/intake.json`, nên không có gì bị nhập hai lần.
- Nội dung issue được coi là **không đáng tin**: planner được dặn không làm theo chỉ dẫn trong đó, và việc duyệt một proposal như vậy in lại các lệnh verify của nó kèm cảnh báo. Việc duyệt luôn là của bạn.

### Thông báo

- **`setup --notify`** thêm hook `needs_human` và `run_ended` gọi `.harness/notify.sh`. Nó dùng thông báo desktop trên macOS (`osascript`) hoặc Linux (`notify-send`), và quay về tiếng chuông terminal.
- **Run tương tác** còn gửi `PushNotification` khi vòng lặp cần bạn hoặc kết thúc, nếu công cụ đó có sẵn.
- **Mọi thứ khác** (Slack, email, pager) chỉ cách một hook `cmd:`.

## Làm việc với plugin khác

Harness là một host: agent, skill và command của bất kỳ plugin nào đã cài đều có thể là một bước trong pipeline của nó, và mọi công cụ đều có thể theo dõi tiến độ của nó.

### Extension của pipeline

```json
"pipeline": [
  { "agent": "coder", "blocking": true },
  { "agent": "tester", "blocking": true, "when": "claimed" },
  { "name": "review",   "use": "agent:pr-review-toolkit:code-reviewer", "when": "passed", "optional": true },
  { "name": "security", "use": "skill:security-review", "when": "tag:auth", "optional": true },
  { "name": "changelog","use": "command:/docs:changelog", "every": 10, "optional": true },
  { "name": "build",    "use": "cmd:npm run build" }
]
```

| `use` | Chạy như |
|---|---|
| `agent:<name>` | một agent của harness (`.harness/agents/`, `agents/` của plugin, `templates/agents/`) |
| `agent:<plugin>:<agent>` | subagent type của plugin khác. Run headless uỷ quyền cho nó từ một session `claude -p` |
| `skill:<name>` · `skill:<plugin>:<skill>` · `command:/<plugin>:<cmd> args` | một subagent mới gọi nó bằng công cụ Skill |
| `cmd:<shell>` | một bước shell do chính gate chạy; exit code là kết quả |

Trường của bước:
- Bước `use:` mặc định `blocking: false`.
- `optional: true` bỏ qua bước kèm một ghi chú khi plugin chưa cài, nên plugin thiếu không bao giờ làm hỏng một run.
- `when` còn nhận `passed` (một feature đã pass trong session này) và `tag:<tag>` (feature đích có tag đó).

Các bước extension được báo phạm vi commit của session và những feature nào đã pass. Chúng có thể `fail` một feature chúng thấy hỏng, hoặc `propose` các feature tiếp theo. Chúng không bao giờ được `pass` một feature hay sửa spec. Chạy `/wreck-it-ralph:doctor` để xem những tham chiếu nào resolve được trên máy này.

### Sự kiện và hook

Mỗi chuyển trạng thái của gate được thêm vào `.harness/events.jsonl` (git ignore), mỗi dòng một đối tượng JSON:

| Sự kiện | Trường thêm |
|---|---|
| `run_started` | |
| `session_started` | `target` |
| `feature_claimed` | |
| `verify_failed` | `command` |
| `feature_passed` | `feature` |
| `feature_failed` | `note` |
| `needs_human` | `question` |
| `session_ended` | `stats` |
| `run_ended` | `reason`, `code` |
| `step_finished` | |
| `proposal_filed` | |
| `proposal_approved` | |

`hooks` trong config gắn trình xử lý shell vào các sự kiện này:

```json
"hooks": {
  "needs_human": ["cmd:osascript -e \"display notification \\\"$HARNESS_QUESTION\\\" with title \\\"Harness\\\"\""],
  "run_ended":   ["cmd:./scripts/notify.sh"]
}
```

- Mỗi trình xử lý nhận JSON của sự kiện qua stdin và `HARNESS_EVENT`, `HARNESS_FEATURE`, `HARNESS_REASON`, `HARNESS_CODE`, `HARNESS_QUESTION`, … trong môi trường.
- Output đi vào `.harness/sessions/hooks.log`.
- Một trình xử lý lỗi được báo nhưng không bao giờ dừng vòng lặp.
- Hook và bước `cmd:` thuộc bản ghi trust, nên chúng không chạy cho đến khi bạn xem qua bằng `/wreck-it-ralph:trust`.

### Hợp đồng status

`.harness/status.sh --json` in một ảnh chụp có phiên bản (`"schema": 1`) cho status line, dashboard và plugin khác:
- số feature theo trạng thái, và `next`
- `questions` và `proposals_pending`
- trạng thái `runner` và `session`
- `spend`
- `last_event`

### Thiết kế vòng lặp

Skill `loop-design` đi kèm dạy Claude cách thiết lập và tinh chỉnh một vòng lặp: các mức verify, ngân sách, chuyển người, công thức pipeline, hook, và checklist trước khi chạy không giám sát. Ví dụ hãy hỏi: "giúp tôi làm cứng vòng lặp này cho một run qua đêm".

## Cấu hình (`.harness/config.json`)

```json
{
  "version": 3,
  "max_sessions": 100,
  "stuck_limit": 3,
  "escalate_after_failures": 3,
  "budget": { "max_cost_usd": 25, "max_tokens": 0, "max_wall_minutes": 480, "max_session_minutes": 90, "max_agent_minutes": 45, "max_diff_lines": 800, "on_large_diff": "warn" },
  "verify_static": "npm run lint && npx tsc --noEmit",
  "final_verify_command": "npm test",
  "permission_mode": "acceptEdits",
  "allowed_tools": "Bash,Read,Edit,Write,Glob,Grep,NotebookEdit,mcp__playwright",
  "mcp_config": ".harness/mcp.json",
  "pipeline": [
    { "agent": "coder",    "blocking": true },
    { "agent": "tester",   "blocking": true, "when": "claimed" },
    { "agent": "reviewer", "blocking": false, "every": 5 }
  ],
  "allow_dirty": false,
  "lock_timeout_minutes": 120,
  "tester": { "read_only": true, "allow_paths": [] },
  "calibration": { "enabled": true, "max_false_positive_rate": 0 },
  "replay": { "adapter": "", "base_url": "http://127.0.0.1:3000", "command": "", "timeout_seconds": 30 },
  "coverage": { "tool": "", "cmd": "", "format": "coveragepy", "runner": "", "branch": true, "omit": [], "max_gaps": 50, "mode": "report",
                "ratchet": { "enabled": true, "scope": ["repository", "changed_files"], "allow_new_files": true, "tolerance": 0 } }
}
```

- **Agent của pipeline được tìm ở đâu:** `.harness/agents/`, rồi `agents/` của plugin, rồi `templates/agents/`.
- **`every`:** chạy agent mỗi N session.
- **`when`:** `always`, `claimed` hoặc `failing`. Verify gate chạy trước bước `claimed` đầu tiên.
- **Không có tester:** nếu pipeline không có `tester`, các claim vượt qua verify gate được chấp nhận là pass.
- **`tester`:** `read_only` (mặc định true) bật bảo vệ cây sản phẩm, `allow_paths` liệt kê đường dẫn nó bỏ qua. **`calibration`:** `enabled` (mặc định true) chạy các case đáp án biết trước ở đầu một run, `max_false_positive_rate` là ngưỡng cho `calibrate.sh report --check`.
- **`replay`:** `adapter` là `http` hoặc `cli` (mặc định theo preset: `api` và `web` dùng `http`, `cli` dùng `cli`); `base_url` (hoặc biến môi trường `BASE_URL`) là app đang chạy; `command` là file thực thi cho adapter `cli`.
- **`coverage`:** `tool` tự phát hiện (`go.mod` → go, `package.json` → node, dấu hiệu Python → python); `cmd` và `format` thay runner có sẵn; `runner` chọn vitest, jest, c8 hoặc nyc; `omit` nhận glob; `mode` là `report` hoặc `gate`.

## Mô hình an toàn

- **Công việc của bạn được bảo vệ.**
  - Commit của harness dùng `git add -A`, nên `init` từ chối bắt đầu trong một dự án git có thay đổi chưa commit. Dùng `--branch NAME` để làm trên một nhánh riêng, hoặc `--allow-dirty` để gộp chúng vào.
  - Bắt đầu một vòng lặp trên cây bẩn bị từ chối trừ khi đặt `allow_dirty`. Thay đổi dưới `.harness/` không tính.
- **Trust.**
  - Một số cài đặt đến từ repo và có thể chạy lệnh: `permission_mode`, `allowed_tools`, `final_verify_command`, `verify_static`, `replay.command`, `coverage.cmd`, `claude_bin`, `model`, cấu hình MCP, agent tuỳ biến trong `.harness/agents/`, các lệnh `verify` của feature, và `tester`.
  - Một vòng lặp từ chối bắt đầu cho đến khi bạn xem chúng bằng `/wreck-it-ralph:trust`. Bản ghi được giữ trong `.harness/.trusted` (bị git ignore).
  - Config do setup sinh ra được tin tự động. Lệnh verify do initializer viết trong session của bạn, hoặc do bạn duyệt trong một proposal, cũng vậy.
- **Quyền headless.** Mặc định là `acceptEdits` với danh sách công cụ tường minh. Runner cảnh báo về `bypassPermissions`. Hãy dùng sandbox hoặc một checkout bỏ đi cho các run không giám sát.
- **Tester độc lập.** Coder chỉ được `claim`. Ở `end`, mọi feature trở thành passing mà không ở trạng thái claimed khi tester bắt đầu đều bị reset. Tester không sửa được sản phẩm (xem "Tester chỉ đọc trên sản phẩm").
- **Một vòng lặp mỗi dự án.** Một khoá heartbeat đảm bảo điều này; xoá khoá cũ bằng `.harness/step.sh unlock`.
- **Commit an toàn.**
  - Lỗi commit được báo, không bị nuốt. File trên 5 MB gây cảnh báo.
  - Các bộ ignore theo ngôn ngữ được thêm và phát hiện lại mỗi lần vòng lặp bắt đầu.
  - Các wrapper `.harness/*.sh` chứa đường dẫn riêng theo máy, nên chúng bị git ignore và tự phục hồi.

## Log và bản tóm tắt

- **Output agent headless:** `.harness/sessions/NNN-<agent>.log`.
- **Output verify gate:** `NNN-verify-<ID>.log`.
- **Ghi chú tương tác:** `NNN-notes.md`.
- **Chi phí mỗi lần chạy agent:** `.harness/ledger.jsonl`. Bản tóm tắt hiện tổng của run.
- **Tường thuật session:** `.harness/progress.md`.
- **Tóm tắt run:** mỗi lần dừng ghi `.harness/last-run.md`, gồm lý do dừng, mọi feature kèm trạng thái và ghi chú, câu hỏi còn mở, proposal đang chờ, các commit và ghi chú của agent.

Chạy test script bằng `bash tests/run-tests.sh`. Nó dùng một `claude` giả, và CI chạy nó trên Linux và macOS cùng `shellcheck`.

---

## Ralph loop trong session

`/wreck-it-ralph:ralph "<prompt>" --max-iterations 20 --completion-promise "DONE"` bắt đầu một vòng lặp ngay trong session hiện tại của bạn:
1. Một Stop hook chặn Claude kết thúc lượt của nó.
2. Nó đưa lại **cùng một prompt**, nên Claude thấy công việc trước đó của chính nó trong file và git.
3. Vòng lặp kết thúc khi:
   - promise (nếu đặt) được đưa ra **và** lệnh `--verify` (nếu đặt) exit 0;
   - đạt `--max-iterations` hoặc `--max-minutes`;
   - với `--allow-blocked`, Claude kết thúc trung thực bằng `<promise>BLOCKED: what I need</promise>`;
   - bạn chạy `/wreck-it-ralph:cancel-ralph`.

`--verify 'npm test'` là một phép kiểm thật: hook chạy nó, và nếu fail thì đưa phần đuôi output lại cho Claude cùng prompt. Vì vậy "tôi xong rồi" là chưa đủ để kết thúc vòng lặp.

Mọi kết thúc được ghi vào `.claude/ralph-loop.last.md` (kết quả, số lần lặp, prompt). `/wreck-it-ralph:add --from-ralph` biến tác vụ đó thành các feature trong backlog khi nó lớn vượt một vòng lặp đơn.

Vòng lặp chỉ có phạm vi trong session đã bắt đầu nó.

Dùng cho một tác vụ được xác định rõ có phép kiểm tự động (ví dụ `--verify 'npm test'`). Với việc trải qua nhiều feature, hãy dùng harness, thứ thêm context mới, một tester độc lập và một backlog có theo dõi.

Mẹo viết prompt:
- **Đưa tiêu chí hoàn thành vào prompt.**
- **Làm theo giai đoạn hoặc theo TDD.**
- **Luôn đặt `--max-iterations` (hoặc `--max-minutes`)**, và ưu tiên `--verify` hơn là chỉ một promise.
- **Nói rõ phải làm gì khi kẹt:** ghi lại chỗ vướng, liệt kê những gì đã thử.

Windows: hook là một script bash và cần Git for Windows. Nếu `bash` resolve tới một WSL hỏng, hãy trỏ `hooks/hooks.json` tới `"C:/Program Files/Git/bin/bash.exe"` trong bản plugin đã cache.

## Giấy phép và ghi công

Apache-2.0 (xem `LICENSE` và `NOTICE`). Dẫn xuất từ plugin Ralph Loop của Anthropic. Kỹ thuật Ralph Wiggum được ghi công cho Geoffrey Huntley, và thiết kế harness cho bài viết về long-running agents của Anthropic. Các roadmap nằm ở `docs/ROADMAP-v3.md` (harness) và `docs/ROADMAP-v4-testing.md` (testing).
