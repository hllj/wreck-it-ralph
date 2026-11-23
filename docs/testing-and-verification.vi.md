# Test và verification trong wreck-it-ralph

[English](testing-and-verification.md) · **Tiếng Việt**

Tài liệu này giải thích đơn giản các ý tưởng về test và verification mà plugin áp dụng, để đọc lại sau này. Chi tiết lệnh nằm trong `README.md`, mục "Testing".

## 1. Ý tưởng cốt lõi

1. **Coder không tự chấm bài mình.** Coder viết code và chỉ được `claim` ("tôi nghĩ xong rồi"). Chỉ **tester** mới được đánh dấu `pass`.
2. **Không có bằng chứng thì không PASS.** Tester phải chạy app thật và có kết quả replay cho từng example. Thiếu bằng chứng thì gate tự reset feature về `failing`.
3. **Điều kiện đúng/sai là dữ liệu khoá sẵn, không phải code của coder.** Đó là các *example* (test case) trong `feature_list.json`. Coder không được sửa chúng.
4. **Tester là người đánh giá độc lập.** Nó chạy trong context mới, chỉ đọc code, không được sửa sản phẩm. Gate kiểm tra điều này bằng code chứ không tin vào prompt.
5. **Đo luôn chất lượng của người chấm.** Calibration đếm xem evaluator chấm sai bao nhiêu, đặc biệt là false positive (chấm PASS cho thứ đang hỏng).

## 2. Một session chạy như thế nào

```
coder -> [gate: chạy lệnh verify] -> tester -> [gate: kiểm tra, reset nếu sai luật]
```

- **Coder:** làm đúng một feature, theo thứ tự RED rồi GREEN (xem mục 4), rồi `claim`.
- **Gate chạy `verify`:** các lệnh `verify` của feature (ví dụ `pytest ...`) do gate chạy, coder không giả được. Fail thì feature bị fail luôn, không tới tester.
- **Tester:** replay example, thử thêm vài tình huống ngoài example, kiểm tra regression, rồi ra verdict.
- **Gate cuối session (`step.sh end`):** reset mọi feature "pass" mà không có đủ bằng chứng, hoặc do tester sửa code sản phẩm, hoặc do coder tự pass.

## 3. Example: cách viết test case

Example là một test case khoá sẵn của feature. Nó gồm `input`, `expect` và `assertions` (cách so sánh):

```json
{
  "id": "EX001",
  "name": "tạo user hợp lệ",
  "input":  {"method": "POST", "path": "/users", "body": {"name": "Ada"}},
  "expect": {"status": 201, "body": {"name": "Ada"}},
  "assertions": {"body": "partial"}
}
```

- **Adapter** thực hiện lời gọi thật vào app đang chạy: `http` (gửi `method/path/body`, so `status/headers/body`) hoặc `cli` (gửi `args/stdin`, so `exit_code/stdout/stderr`). Example không bao giờ chứa shell command.
- **Kiểu so sánh** cho từng key của `expect`: `exact` (bằng hệt), `partial` (expect là tập con của actual, mặc định khi expect là object), `contains`, `regex`.
- **Nhiều bước:** một example có thể có `steps: [...]`, kèm `setup` và `cleanup` để dựng và dọn dữ liệu.
- **Ai viết example:** initializer viết khi tạo feature list. Muốn thêm case mới, dùng `/wreck-it-ralph:example` (đề xuất, bạn duyệt) hoặc tester/coder gửi *proposal* qua `backlog.sh propose`. Không ai được tự sửa example để cho app "đúng".
- **Nên có trong mỗi feature:** trường hợp bình thường, input sai, thiếu field bắt buộc, giá trị lạ (unicode, rỗng), và đường báo lỗi.

Chạy thử bằng tay: `.harness/replay.sh <ID>` (hoặc `--example EX001`).

## 4. RED rồi GREEN (làm test trước)

Với feature có example, coder phải:

1. Làm cho test/example **fail đúng lý do** trước khi viết code, rồi chạy `.harness/feature-list.sh red <ID>`. Lệnh này chạy `verify` và replay, và chỉ ghi RED nếu thật sự có cái fail.
2. Viết code đến khi pass (GREEN).
3. `claim` bị từ chối nếu chưa có RED. Nếu hành vi đã tồn tại sẵn, dùng `red <ID> --skip "<lý do>"` và tester sẽ thấy lý do đó.

Mục đích: chứng minh test có khả năng bắt lỗi, không phải test luôn xanh.

## 5. Verdict của tester

Tester ra verdict bằng `.harness/report.sh <ID> <verdict> "<ghi chú>"`:

| Verdict | Ý nghĩa |
|---|---|
| `pass` | Đúng. Bị từ chối nếu chưa replay đủ mọi example trong lần chạy này. |
| `fail` | Hỏng, có cách tái hiện. Tính là một lần thử thất bại. Kèm `--findings file.json` để coder nhận lỗi có cấu trúc. |
| `blocked` | Không test được (app không chạy, môi trường hỏng). Không tính là lỗi logic. |
| `inconclusive` | Chưa đủ bằng chứng hoặc mô tả mơ hồ. Thành câu hỏi gửi cho người. |

Mỗi verdict ghi `evidence/<ID>/report.json` và `report.md`: example nào pass, coverage, và lệnh để bạn tự replay lại.

Ngoài example, tester còn phải: kiểm tra các "known issues" của coder, thử thêm 3 đến 5 tình huống từ mô tả feature (biên, rỗng, unicode, lặp nhanh, restart), và kiểm tra regression 1-2 feature đã pass có liên quan.

## 6. Coverage: nhìn thấy chỗ chưa được test

`.harness/coverage.sh run --id <ID>` chạy test suite dưới coverage. `coverage.sh gaps <ID>` liệt kê nhánh code mà diff của feature thêm vào nhưng chưa chạy tới. Tester phải phân loại từng gap (cần thêm example, code thừa, nhánh phòng thủ, hoặc đã kiểm tra bằng probe có bằng chứng).

Hai nguyên tắc: coverage là để **nhìn thấy**, không phải mục tiêu phần trăm; và chạm tới một nhánh chưa có nghĩa là nhánh đó đúng. Có thể bật ratchet (`coverage.mode: gate`) để coverage không được tụt so với baseline do người ghi.

## 7. Tester chỉ đọc (read-only)

- Tester được đọc code, chạy app, test, replay, trình duyệt. Chỉ được ghi trong `.harness/` (evidence, progress, sửa `init.sh`) và thư mục tạm.
- Gate chụp "dấu vân tay" của cây sản phẩm (mọi thứ ngoài `.harness/`) lúc tester bắt đầu và lúc kết thúc.
  - Sửa file đã track, hoặc commit file mới: gate **hoàn tác**, reset mọi feature tester đã pass trong session đó, và báo `TESTER_EDITED`.
  - Chỉ để lại file mới chưa track (rác từ probe): gate xoá và cảnh báo, verdict giữ nguyên.
- Giới hạn: gate phát hiện và hoàn tác sau khi xong, không chặn ghi ngay trong lúc chạy. Muốn chặn cứng thì chạy tester trong một checkout riêng.
- Cấu hình: `tester.read_only` (mặc định true), `tester.allow_paths`.

## 8. Calibration: đo chất lượng người chấm

Nguy hiểm nhất là **false positive**: evaluator nói PASS nhưng feature hỏng, rồi vòng lặp xây tiếp trên cái sai đó. `.harness/calibrate.sh` đo điều này từ ba nguồn:

| Nguồn | Là gì | Sự thật lấy từ đâu |
|---|---|---|
| `comparator` | Các case có đáp án biết trước, đưa qua engine so sánh của replay. Có sẵn 16 case (bình thường, input sai, thiếu field, unicode, sai kiểu, regression...) trong `.harness/calibration/cases.json`. | trường `truth` của case |
| `scan` + `label` | Feature đã pass nhưng sau đó fail thì thành "candidate". Bạn gắn nhãn `false_positive`, `regression` hoặc `dismiss`. | nhãn của bạn |
| `record` | Bạn (hoặc tester) ghi lại một verdict sai mà bạn phát hiện. | bạn |

Ví dụ một bảng calibration:

| Case | Truth | Evaluator | Kết quả |
|---|---|---|---|
| input bình thường | PASS | PASS | đúng |
| input sai bị nhận nhầm | FAIL | PASS | **false positive** |
| thiếu field bắt buộc | FAIL | FAIL | đúng |
| unicode | PASS | PASS | đúng |

`calibrate.sh report` cho biết: số false positive và tỉ lệ (trên các case có truth là fail), false negative và tỉ lệ, tỉ lệ phát hiện regression, và độ phủ tiêu chí chấp nhận (bao nhiêu example đã có replay pass còn hiệu lực, bao nhiêu feature chưa có example nào).

Gate dùng nó ở ba chỗ: không cho bắt đầu run mới (mã 13) nếu engine so sánh để lọt một case sai đã biết; cuối mỗi session quét và cảnh báo feature "pass rồi fail"; và khôi phục lại cases nếu agent sửa chúng.

Chưa làm: đo phần "phán đoán" của tester (LLM). Hiện chỉ có nhãn của bạn và `record`. Chưa có "planted defect" (cài lỗi đã biết rồi xem tester có bắt được không).

## 9. Bản đồ nhanh: lệnh nào làm gì

| Mục đích | Lệnh |
|---|---|
| Xem example của feature | `.harness/feature-list.sh examples <ID>` |
| Replay example | `.harness/replay.sh <ID> [--example EX001]` |
| Ghi RED | `.harness/feature-list.sh red <ID>` |
| Verdict của tester | `.harness/report.sh <ID> pass\|fail\|blocked\|inconclusive "..."` |
| Coverage | `.harness/coverage.sh run\|gaps\|classify\|ratchet` |
| Calibration | `.harness/calibrate.sh run\|record\|scan\|label\|report` |
| Đề xuất thêm example | `/wreck-it-ralph:example` hoặc `.harness/backlog.sh propose` |
| Kiểm tra sức khoẻ harness | `/wreck-it-ralph:doctor` |

## 10. Những điều nên nhớ

- Bằng chứng nằm trong `.harness/evidence/` và bị git ignore. Muốn giữ thì copy ra.
- Gate (code) là nơi giữ luật, không phải prompt. Prompt chỉ hướng dẫn; việc reset, hoàn tác, khoá spec đều do `step.sh` thực hiện.
- Pre-release: các cơ chế này mới được kiểm bằng test script, chưa chạy với `claude` thật.
