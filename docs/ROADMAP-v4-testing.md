# Roadmap v4: Evidence-Based Testing

Trạng thái: **M1-M4 đã implement** (examples inline + khóa spec, `red`, claim gate; `replay.sh` + adapter http/cli, evidence ở `.harness/evidence/`). `report.sh` (4 verdict, cổng chặn PASS thiếu evidence, BLOCKED không tính attempt). M5+ chưa làm; setup/cleanup fixture và `--step`/`--keep` để M5. Thay thế phần "tester thử 3-5 input" trong `agents/tester.md`.

## Nguyên tắc

1. **No evidence, no PASS.** Không có bằng chứng chạy lại được thì không có feature "verified".
2. **Coverage is visibility, not correctness.** Coverage chỉ cho biết code nào đã chạy, không cho biết kết quả đúng.
3. **Agent chỉ ra lỗ hổng, con người quyết định.** Không đặt mục tiêu "X%" cho agent; agent không tự xóa code hay tự sửa contract.

## Ba khái niệm tách biệt

| Khái niệm | Ý nghĩa | Nằm ở |
|---|---|---|
| Contract | Hành vi đúng (mô tả + acceptance) | `feature_list.json` (khóa) |
| Example | Một trường hợp cụ thể của contract, dạng dữ liệu | `examples[]` **trong** `feature_list.json` (khóa cùng spec; M3 sinh `.harness/demo/<ID>/examples/EXnnn.json` từ đó để replay) |
| Replay | Cách chạy example trên app thật | adapter (`http`, `cli`, `playwright`) |

### Schema example

```json
{
  "id": "EX001",
  "name": "empty cart",
  "description": "Reject checkout when cart is empty",
  "input": {"items": []},
  "expect": {"status": 400, "body": {"error": "Cart cannot be empty"}},
  "assertions": {"status": "exact", "body": "partial"}
}
```

- Assertion ban đầu: `exact`, `partial` (subset), `contains`, `regex`. Không thêm khi chưa cần.
- **Test oracle bắt buộc kiểm tra được bằng máy.** Không dùng "works correctly" làm điều kiện PASS. UI dùng DOM, URL, accessible name, visible text. LLM chỉ là evaluator bổ sung, không thay assertion.
- Coder và tester **không sửa** example. Muốn đổi contract: proposal qua `/backlog`, người duyệt.

## Replay engine

- Adapter dùng lại được: `adapters/http.sh`, `cli.sh`, `playwright.sh`. Example là **dữ liệu**; **không** chứa lệnh shell tùy ý, **không** `eval`. Adapter chỉ chấp nhận danh sách hành động cho phép.
- Chạy trên **app thật đang chạy**. Tester kiểm tra replay integrity: không mock system under test, không hardcode kết quả.
- Evidence mỗi lần chạy: input, actual, expected, kết quả từng assertion, log, commit SHA.
- Cleanup: fixture tạo trong namespace `ralph_<ID>_<EX>_<runid>`, chỉ xóa tài nguyên thuộc namespace đó. Không đụng dữ liệu có sẵn của project hay của người dùng. `trap` chỉ là best effort (kill -9 sẽ bỏ qua). DB: transaction rollback hoặc test tenant/prefix. Cờ `--keep` giữ lại dữ liệu nếu an toàn.
- Git: **commit** definition (examples, adapters, baseline). **Không commit** evidence hàng loạt: `.harness/evidence/` vào `.gitignore`, chỉ commit report được chọn.

### Giao diện

```
/wreck-it-ralph:demo F001                      # liệt kê examples
/wreck-it-ralph:demo F001 --run                # chạy tất cả
/wreck-it-ralph:demo F001 --example EX001
/wreck-it-ralph:demo F001 --step 1             # mỗi step có id và output riêng
/wreck-it-ralph:demo F001 --from 1 --to 3
/wreck-it-ralph:demo F001 --example EX001 --keep
/wreck-it-ralph:example F001                   # đề xuất example mới -> proposal, không sửa trực tiếp
```

HTTP: một example = một step. UI: một example có nhiều step.

## Tester mới

1. Load contract và examples đã khóa.
2. Validate replay integrity.
3. Chạy replay trên app thật.
4. Đọc coverage gaps.
5. **Coverage-guided exploratory testing** (giữ exploratory, không bỏ): suy ra input kích hoạt nhánh chưa chạy, chạy trên app thật, và **xác nhận hành vi đúng**, không chỉ "đã đi qua nhánh".
6. Regression các feature liên quan.
7. Ghi evidence report.

Phát hiện mới ngoài contract: ghi finding, đề xuất example, qua `/backlog`. Tester không tự thêm example để hợp thức hóa kết quả.

### Kết luận có 4 trạng thái

| Kết luận | Nghĩa |
|---|---|
| PASS | Đã kiểm chứng và đúng |
| FAIL | Đã kiểm chứng và phát hiện lỗi |
| BLOCKED | Không kiểm thử được vì môi trường/dependency (app không khởi động...). **Không tính là lỗi logic, không tốn attempt** |
| INCONCLUSIVE | Chưa đủ bằng chứng; chuyển thành `ask` |

Report JSON lưu: `feature_id`, `status`, `tested_at`, `commit_sha`, số example pass/fail, coverage (nếu có), đường dẫn evidence.

## Coverage

- Ba loại, **chỉ triển khai hai loại đầu**: repository, changed-file. Feature-attributed (cần tracing/coverage contexts) để sau. **Không gọi changed-file coverage là "feature coverage"** trong report.
- Schema chuẩn hóa (`schema_version`, `tool`, `tool_version`, `scope`, `summary`, `files[]` với `missing_lines`, `missing_branches`). Giữ dữ liệu gốc của tool.
- Tool không hỗ trợ branch (ví dụ Go) => `null`/`unsupported`, **không bao giờ 0%**.
- Lưu `covered/total`, không so sánh phần trăm đã làm tròn.
- Mặc định `mode: report`.

### Ratchet hai tầng (chỉ khi `mode: gate`)

```json
"coverage": {
  "cmd": "", "branch": true, "mode": "report",
  "ratchet": {"enabled": true, "scope": ["repository", "changed_files"],
              "allow_new_files": true, "tolerance": 0}
}
```

- Tầng 1: branch coverage toàn repo không giảm.
- Tầng 2: file đã có baseline không giảm (chặn trường hợp repo 80→82% nhưng `checkout.py` 90→60%). File mới: chỉ báo cáo.
- Baseline gắn với commit SHA + version tool + cấu hình chạy. Xử lý file bị xóa/rename, branch bị xóa, đổi version tool, đổi test selection (so sánh khác cấu hình thì cảnh báo, không gate).

### Gap report

Mỗi gap: vị trí, nhánh, điều kiện, phân loại, lý do, evidence, **confidence**, hành động đề xuất.
Phân loại: `needs_example`, `redundant_code`, `defensive_branch` (cần người duyệt, agent **không tự xóa**), `inconclusive`.

## Chống test rỗng (sau Pha 2)

1. Static assertion check: heuristic cảnh báo, không gate (exception, snapshot, exit code, mock assert vẫn hợp lệ).
2. Mutation testing trên changed files (mutmut, Stryker; Go: đánh giá công cụ trước).
3. Tester tự đột biến trong **worktree tạm**, không sửa code project: mutant phải làm ít nhất một example FAIL.

## Milestone

| # | Nội dung | Ưu tiên |
|---|---|---|
| M1 | Schema examples + validate + khóa trong `feature-list.sh` | P0 |
| M2 | RED→GREEN cho coder (chứng minh đỏ trước khi code) | P0 |
| M3 | Replay engine + adapter HTTP/CLI | P0 |
| M4 | Tester integration + evidence report + 4 trạng thái | P0 |
| M5 | `/demo`, `/example` | P1 |
| M6 | Coverage Python + normalized schema (có thể thử sau M3) | P1 |
| M7 | Coverage Node | P1 |
| M8 | Coverage Go | P1 |
| M9 | Gap report + targeted probes | P1 |
| M10 | Ratchet hai tầng | P1 |
| M11 | Static assertion check, rồi mutation testing | P2 |

Coverage chưa được công bố là tính năng chính thức trước khi có đủ test.

## Tiêu chí nghiệm thu Pha 1 (M1-M5)

- [ ] Initializer/planner tạo 1-2 example kiểm chứng được cho mỗi feature.
- [ ] Coder không sửa được example ngoài proposal (verify-lock bắt).
- [ ] Coder chứng minh RED trước khi implement.
- [ ] Replay chạy trên app thật, có actual và expected, chạy lại độc lập, cleanup an toàn.
- [ ] Tester kiểm tra replay integrity; không PASS nếu replay không chạy được.
- [ ] App không khởi động => BLOCKED, không FAIL.
- [ ] Report có hướng dẫn replay; `/demo` chạy được một hoặc tất cả example; `/example` tạo proposal.
- [ ] Preset `library` (không có tester) bắt buộc có example chạy bằng test.

## Việc phải nối với code hiện có

- `agents/{initializer,planner,coder,tester}.md`, `scripts/feature-list.sh` (validate + `SPEC_*` khóa examples), `scripts/harness-step.sh` (pipeline, trạng thái BLOCKED/INCONCLUSIVE, hiện tester `fail` cả feature khi app hỏng), `scripts/harness-setup.sh`, `templates/config.json`, `.gitignore`, `commands/demo.md`, `commands/example.md`, `tests/run-tests.sh`.
