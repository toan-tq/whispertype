# Bàn giao: review lỗi treo, hiệu năng và hướng chạy model local (11/2026)

Tài liệu này dành cho người (hoặc session Claude) tiếp theo mở branch
`claude/review-project-performance-p8kyla` để **build, test và kiểm chứng lại**. Nó ghi rõ:
đã sửa gì, đã kiểm được gì, **chưa kiểm được gì**, và những dữ liệu nào chỉ là
**nghi vấn / lấy từ đoạn trích tìm kiếm** cần mở nguồn gốc để xác nhận.

Ưu tiên kiểm tra đầu tiên của chủ dự án: **PhoWhisper** → xem [mục 5](#5-kế-hoạch-test-phowhisper-ưu-tiên-1).

---

## 0. Trạng thái tóm tắt

| Hạng mục | Trạng thái |
|---|---|
| Sửa lỗi treo/kẹt + log thời gian + tuỳ chọn model local | Đã commit trên branch |
| Build trên macOS | **CHƯA** — session review chạy trên Linux, không có macOS SDK |
| Kiểm tra cú pháp ObjC++ | Đạt: `tools/linux-syntax-check/run.sh` (clang `-fsyntax-only` với header Apple giả lập) |
| `tools/bench_local.py` + `tools/build-bench.sh` | Đã chạy trọn vẹn trên Linux (CPU) với model test `for-tests-ggml-tiny.bin` (không có trọng số → output rỗng, chỉ chứng minh pipeline chạy) |
| Chạy với model thật, mạng thật, Groq thật | **CHƯA** — session bị chặn mạng tới huggingface.co, api.groq.com, arxiv.org, *.hf.space |
| Số liệu so sánh model tiếng Việt | **Chỉ từ đoạn trích kết quả tìm kiếm**, chưa mở được bài gốc — xem [mục 4](#4-nguồn-chưa-mở-được--số-liệu-cần-xác-minh) |

Domain cần mở trong network settings nếu session kiểm tra cũng chạy trên cloud:
`huggingface.co`, `cdn-lfs.huggingface.co` (tải model), `*.hf.space` (leaderboard),
`arxiv.org`, `aclanthology.org`, `api.groq.com`.

---

## 1. Những gì đã thay đổi

### 1.1 Lỗi gây treo / kẹt

| # | Vấn đề | Triệu chứng người dùng | Sửa ở đâu |
|---|---|---|---|
| B1 | Event tap của hotkey chạy trên **main run loop**. Mọi phím bấm trong phiên đăng nhập (kể cả phím app tự gõ bằng `CGEventPost`) phải chờ callback của tap. Khi main thread bận (nạp model, gõ transcript dài, mic khởi động chậm) → gõ phím ở **mọi app** bị khựng cho tới khi macOS timeout tap. | "Treo máy", bàn phím đứng vài giây | `src/globalhotkey.mm` — tap chạy trên thread riêng (`m_tapThread`, dòng ~94), QoS user-interactive |
| B2 | Mic không khởi động được (đổi thiết bị, quyền bị thu hồi…) nhưng app vẫn vào trạng thái `Recording`. Lần bấm sau gọi `stopRecording()` → không có gì để dừng → **kẹt Recording vĩnh viễn**, chỉ restart mới thoát. | Menu ghi "Recording..." mãi, hotkey vô dụng | `VoiceRecorder::startRecording()` trả `bool` (`src/voicerecorder.mm:241`); `AppController::toggleRecording()` chỉ vào Recording khi thành công (`src/appcontroller.mm:386`) |
| B3 | Nếu `AVAudioRecorder` không gọi delegate sau `stop` (recorder đã tự dừng vì mất thiết bị) → cũng kẹt Recording. | Như B2 | Watchdog 1,5 s trong `VoiceRecorder::stopRecording()` (`src/voicerecorder.mm:309`), mọi đường kết thúc đi qua `VoiceRecorder::finish()` (`:342`) và chỉ chạy một lần |
| B4 | Tạo recorder mới thất bại → code cũ **dùng lại recorder của lần trước** (đã dừng, file đã xoá) và ghi đè vào file cũ. | Bản ghi lạ / sai | `helper.recorder = nil` trước khi tạo (`startRecording`) |
| B5 | Model whisper (~1,6 GB) nạp **trên main thread** lúc khởi động và lúc bật trong menu. | Menu bar đứng vài giây; app mở chậm | `WhisperTranscriber::loadModelAsync()` (`src/whispertranscriber.mm:215`): nạp / suy luận / giải phóng đều trên một serial queue nền |
| B6 | Model local giữ ~2 GB RAM kể cả khi đã tắt trong menu. | Máy RAM 8–16 GB bị swap → chậm cả máy | `WhisperTranscriber::release()` (`:192`), gọi khi tắt Local Model |
| B7 | Giữ ⌥Space hơi lâu → auto-repeat → bật rồi tắt ngay. ⌘⌥Space (Finder search), ⌃⌥Space… bị app nuốt. | Bản ghi cực ngắn, lỗi "audio too short"; phím tắt khác hỏng | `src/globalhotkey.mm:44` (đúng mỗi Option), `:49` (bỏ qua autorepeat) |

### 1.2 Lỗi khác

| # | Vấn đề | Sửa ở đâu |
|---|---|---|
| B8 | Tải model: trang lỗi HTTP (404/5xx) được lưu thành file model | `src/whispertranscriber.mm:49` kiểm tra `statusCode` |
| B9 | File `.tmp` sót lại làm mọi lần tải sau thất bại | `:63` xoá `.tmp` trước khi move |
| B10 | Nạp model lỗi → tự tải lại 1,6 GB mỗi lần mở app | Giờ báo lỗi "Cannot load … (delete it to re-download)" lên menu (`onLoadFailed`) |
| B11 | Timeout tổng cố định 45 s cho Groq → bản ghi dài (cho phép tới 600 s ≈ 19 MB) luôn bị cắt | `src/groqtranscriber.mm:304`: `max(45 s, 30 s + size / 64 KB/s)`; vẫn 45 s cho bản ghi 30 s mặc định. Cancel do hết ngân sách được báo "Timed out … (upload too slow)" và vẫn retry/fallback như timeout thường |
| B12 | Nói "Enter" → Whisper trả "Enter." → app gõ chữ thay vì nhấn Return | `src/textinjector.mm:103` bỏ dấu câu khi so lệnh đứng riêng |
| B13 | Đọc audio local bằng một lần `ExtAudioFileRead` (định dạng nén có thể trả thiếu frame) | Vòng lặp đọc (`src/whispertranscriber.mm:379`) |
| B14 | Bắt trong block một tham chiếu `const std::string&` sẽ treo (dangling) sau `dispatch_async` (lỗi tiềm ẩn trong bản viết lại, đã tránh) | `WhisperTranscriber::postError(std::string, std::string)` nhận theo giá trị |

### 1.3 Chẩn đoán "chậm ở đâu" (mới)

Xem log:
```bash
log stream --style compact --predicate 'process == "Whispertype"' \
  | grep -E "Timing|Groq timing|Recording started|Recording finished|Local transcription|Bluetooth"
```

| Dòng log | Ý nghĩa | Code |
|---|---|---|
| `Recording started in N ms from <mic> (<built-in/USB/Bluetooth>)` | Thời gian khởi động mic + loại mic. Có cảnh báo riêng nếu mic Bluetooth | `src/voicerecorder.mm:181`, `:241` |
| `Recording finished: …, N KB, file ready N ms after stop` | Kích thước file, thời gian chốt file | `finish()` |
| `Groq timing (upload): h2, new/reused connection, dns, connect (tls), upload N ms for N KB (N KB/s), server N ms, download, total` | Chia nhỏ thời gian mạng từ `NSURLSessionTaskMetrics` | `src/groqtranscriber.mm:132` |
| `Groq timing (prewarm): …` | Request mở sẵn kết nối khi bắt đầu ghi | `GroqTranscriber::prewarm()` (`:241`) |
| `Timing: stop->file, queued, groq/local N s, typing N ms => stop->text N s` | **Dòng quan trọng nhất**: tổng thời gian người dùng cảm nhận | `src/appcontroller.mm:265` |
| `Local transcription: N s of audio in N s (decode, inference, Nx real time)` | Tốc độ model local | `doTranscribe()` |

### 1.4 Tính năng mới cho hướng local

| Key `defaults` | Tác dụng |
|---|---|
| `LocalModelFile` | Tên file trong `~/Library/Application Support/TQT/Whispertype/` hoặc **đường dẫn tuyệt đối** (`~` được mở rộng). Mặc định `ggml-large-v3-turbo.bin` |
| `LocalModelURL` | URL tải khi file chưa có. Mặc định: repo `ggerganov/whisper.cpp` trên HF cùng tên file |
| `PreferLocalModel` | Chạy local trước, Groq làm dự phòng. Menu: **Use Local Model First (no upload)**. Bật nó cũng bật Local Model; tắt Local Model thì nó tắt theo |
| `KeepRecordings` | Giữ mọi bản ghi đã chép + file `.txt` (nội dung đã gõ) trong `~/Library/Caches/com.tqt.whispertype/samples/` làm bộ test. Không tự xoá |

Công cụ:
- `tools/build-bench.sh` — build `whisper-server` + `whisper-quantize` từ submodule (cùng commit whisper.cpp với app, Metal trên Mac) vào `build-bench/bin/`.
- `tools/bench_local.py` — chạy nhiều model (và `groq:<model>`) trên bộ test, in bảng: thời gian nạp, mean/p50/p90/max, RTF, **WER/CER**, **punct % / caps %** (tỷ lệ output có dấu câu / chữ hoa — WER bỏ qua hai thứ này nhưng gõ văn bản thì cần), RAM. Chỉ dùng thư viện chuẩn Python 3.9+.
- `tools/linux-syntax-check/run.sh` — kiểm cú pháp `src/*.mm` khi không có Mac.

Bộ test cũng có thể lấy từ `~/Library/Caches/com.tqt.whispertype/failed/` (bản ghi lỗi, chưa có `.txt`).

---

## 2. Đã kiểm chứng trong session review

1. `tools/linux-syntax-check/run.sh`: 9/9 file `.mm` sạch lỗi và cảnh báo (`-Wall -Wextra`).
   Hiệu chỉnh: code gốc (HEAD trước khi sửa, vốn build được trên Mac) cũng qua sạch; cố tình
   gõ sai tên hàm thì bị bắt.
2. `tools/build-bench.sh` build được trên Linux; `tools/bench_local.py` chạy đầu-cuối:
   khởi động server, đợi `/health`, warm-up, POST từng file, ghi hypothesis, tính bảng.
3. Hàm WER: chuẩn hoá NFC/NFD, bỏ dấu câu, lowercase; ví dụ tiếng Việt cho kết quả đúng
   (2 lỗi cho "…tên là toàn… trời đẹp" vs "…tên toàn… trời rất đẹp").

**Kiểm cú pháp KHÔNG chứng minh** tên/chữ ký API của Apple là đúng (stub viết theo trí nhớ)
và không link. Xem A8 ở mục 3.

---

## 3. Chưa kiểm chứng / nghi vấn kỹ thuật (cần Mac)

Mỗi mục ghi: giả định → vì sao quan trọng → cách kiểm.

| # | Giả định / nghi vấn | Cách kiểm |
|---|---|---|
| A1 | Event tap ở `kCGSessionEventTap` **nhìn thấy cả sự kiện app tự `CGEventPost(kCGSessionEventTap, …)`**, nên khi main thread bận gõ thì chính các phím giả cũng bị chặn chờ. Đây là cơ sở của B1. | Build bản cũ (`git checkout 5b1d07b`), bật local model, gõ liên tục ở TextEdit trong lúc bật/tắt Local Model trong menu → có khựng không. Lặp với bản mới → không khựng. |
| A2 | macOS timeout tap khoảng ~1 s (con số nhớ lại, chưa có nguồn). | Không cần chính xác; chỉ để giải thích. |
| A3 | Khi quyền micro bị từ chối, `-[AVAudioRecorder record]` trả `NO`. Trên macOS **có thể** trả `YES` và ghi im lặng → khi đó B2 không xảy ra theo đường này, nhưng vẫn xảy ra khi mất thiết bị. | `tccutil reset Microphone com.tqt.whispertype`, từ chối quyền, bấm hotkey. Mong đợi: beep + "Microphone: …", trạng thái về Ready; bấm lại không kẹt. Ghi lại hành vi thật. |
| A4 | `AVAudioRecorder` có thể không gọi `audioRecorderDidFinishRecording` nếu đã tự dừng trước `stop` (cơ sở của watchdog B3). | Ghi bằng mic USB/AirPods rồi rút/ngắt giữa chừng, bấm dừng. Mong đợi: log "Recorder did not report… finishing it anyway" hoặc "Recording failed", app không kẹt. |
| A5 | `GET /openai/v1/models` của Groq **không tính** vào quota audio-seconds; **chưa biết** có tính vào RPM/RPD (requests per minute/day) của free tier không. Prewarm gửi tối đa 1 request / 20 s khi bắt đầu ghi. | Xem Groq docs/console mục rate limits. Nếu có tính → tăng `kPrewarmInterval` hoặc bỏ prewarm (`src/groqtranscriber.mm:30`). |
| A6 | Upload sẽ **dùng lại** kết nối đã prewarm (HTTP/2, cùng `NSURLSession`). | Log `Groq timing (upload): … reused connection`. Nếu luôn `new` → prewarm vô ích, gỡ. |
| A7 | `didFinishCollectingMetrics` thường đến trước `didCompleteWithError`; code **không phụ thuộc** thứ tự này (nhãn upload/prewarm lấy theo HTTP method). | Chỉ cần thấy dòng log xuất hiện. |
| A8 | Tên API viết theo trí nhớ, stub không xác minh được: `AVCaptureDevice.transportType`, `+defaultDeviceWithMediaType:` (có thể cảnh báo deprecated), `kAudioDeviceTransportTypeBluetoothLE/Virtual`, `NSURLSessionTaskTransactionMetrics.countOfRequestBodyBytesSent / isReusedConnection / networkProtocolName`, `NSURLSessionTaskMetrics.taskInterval`, `pthread_setname_np(const char*)`, `pthread_set_qos_class_self_np`, `CFMachPortInvalidate`, `dispatch_queue_attr_make_with_qos_class`. | `./build.sh`. Lỗi build nào → sửa đúng chỗ đó. |
| A9 | Model f16 turbo chiếm "~2 GB" khi nạp (1,6 GB trọng số + buffer). | Activity Monitor trước/sau khi bật/tắt Local Model; hoặc cột RAM của bench. |
| A10 | **Nghi vấn số liệu cũ:** commit `a41b2b5` ghi FLAC từ `AVAudioRecorder` *lớn hơn* WAV (~33 KB/s) và *chất lượng kém hơn*. FLAC là nén **không mất dữ liệu** — đúng ra nhỏ hơn (~50–60 % WAV với giọng nói) và transcript phải **giống hệt**. Có thể `AVAudioRecorder` đã ghi FLAC ở độ sâu bit/tần số khác, hoặc khác biệt chỉ là do Groq không tất định. Nếu FLAC đúng → upload giảm gần một nửa. | Lấy một WAV trong `samples/`, `ffmpeg -i in.wav -c:a flac out.flac` (hoặc `afconvert -f flac -d flac in.wav out.flac` — cú pháp afconvert chưa thử), so kích thước; gửi cả hai lên Groq vài lần (`tools/bench_local.py groq:whisper-large-v3` trên 2 thư mục). |
| A11 | Whisper tiếng Việt hay "ảo giác" khi audio im lặng/nhiễu (câu kiểu "Hãy subscribe cho kênh … để không bỏ lỡ những video hấp dẫn"). Được báo nhiều trong cộng đồng, **chưa thấy trong app này**. | Ghi 5 s im lặng vài lần, xem transcript (Groq và local). Nếu có → thêm VAD/trim im lặng hoặc lọc câu. |
| A12 | `whisper-server` của bench nhận các field `language`, `no_timestamps`, `temperature`, `response_format=json` (đã đọc trong `examples/server/server.cpp` của submodule, chưa thử với model thật). | Chạy bench `--limit 3`, xem `build-bench/results/<model>/*.txt`. |

---

## 4. Nguồn chưa mở được + số liệu cần xác minh

Session review **không mở được** các trang dưới (mạng bị chặn); mọi con số ở đây đến từ
**đoạn trích kết quả tìm kiếm** — có thể sai cột, sai bộ test. Cần mở bản gốc để xác nhận
trước khi dùng làm căn cứ.

| # | Thông tin (theo đoạn trích) | Nguồn | Cần kiểm |
|---|---|---|---|
| D1 | Bảng trên model card ChunkFormer: ChunkFormer (110M) 8,31; **PhoWhisper-large (1,55B) 8,85**; whisper-large-v3 14,89 (WER trung bình; các cột riêng 4,67 / 8,14 / 13,75 cho PhoWhisper-large — **tên cột không đọc được**). | https://huggingface.co/khanhld/chunkformer-large-vie | Tên các bộ test (VIVOS? Common Voice? VLSP?), có chuẩn hoá giống nhau không |
| D2 | Vietnamese Open ASR Leaderboard: cột trung bình cuối **có vẻ** là PhoWhisper-medium 7,61; Qwen3-ASR-1.7B 9,84; Qwen3-ASR-0.6B 12,44; "NVIDIA Parakeet Vietnamese" 12,81. **Header bị lỗi, chưa chắc đúng cột.** | https://vietaudio-team-vietnamese-asr-leaderboard.hf.space/ | Mở leaderboard: PhoWhisper-large/small, whisper-large-v3-turbo, Zipformer có mặt không; RTF nếu có. Lạ: medium xếp trên large? |
| D3 | Zipformer-30M-RNNT-6000h: SOTA WER 12,29 % (VLSP2020-Test-T1), 10,40 % (VLSP2023-PublicTest); 0,3 s cho 12 s audio trên CPU. | Bài "Vietnamese Automatic Speech Recognition: A Revisit": https://arxiv.org/pdf/2603.14779 (cũng ở https://aclanthology.org/2026.findings-eacl.345.pdf) | Bảng kết quả đầy đủ, có PhoWhisper/whisper-turbo không |
| D4 | Số giờ huấn luyện Zipformer-30M: **6.000 giờ** (docs sherpa-onnx) **mâu thuẫn** với **~70.000 giờ** (trang PyPI `phostt`). phostt báo ~7,7 % WER trên GigaSpeech2-vi (clean), model ~75 MB. | https://huggingface.co/hynt/Zipformer-30M-RNNT-6000h · https://k2-fsa.github.io/sherpa/onnx/pretrained_models/offline-transducer/zipformer-transducer-models.html · https://pypi.org/project/phostt/ | Model card gốc |
| D5 | VietASR (2025): Whisper large-v3 TB 16,44; Azure Speech 11,78; Zipformer 68M train từ đầu 20,54 (TB có trọng số theo số từ trên GigaSpeech 2 / Common Voice / FLEURS). | https://arxiv.org/pdf/2505.21527 | Bảng gốc |
| D6 | Qwen3-ASR (0.6B/1.7B) có hỗ trợ tiếng Việt; bản int4 cộng đồng: WER tiếng Việt 9,21 % → 13,00 % (100 mẫu FLEURS). Số ngôn ngữ mâu thuẫn giữa các nguồn (11 / 30 / 52). | https://huggingface.co/vrfai/Qwen3-ASR-0.6B-int4 | Model card chính thức của Qwen |
| D7 | Apple `SpeechTranscriber` (macOS 26): danh sách ngôn ngữ lúc ra mắt **không có tiếng Việt**; một bài nói ~40 locale nhưng không liệt kê. Có `DictationTranscriber` cho ngôn ngữ khác. | https://blog.addpipe.com/apple-speechanalyzer-api/ · https://developer.apple.com/forums/thread/797835 | Chạy trên Mac (đoạn Swift bên dưới) |
| D8 | Bản ggml PhoWhisper có sẵn trên HF: **chỉ tìm thấy bản tiny** (`vongocanhthi/ggml-PhoWhisper-tiny`, Q8_0 ~42 MiB). | https://huggingface.co/vongocanhthi/ggml-PhoWhisper-tiny | Tìm "ggml PhoWhisper medium/large" — nếu có thì khỏi tự convert (nhưng nên tự convert để chắc nguồn) |
| D9 | Phiên bản whisper.cpp mới nhất: mâu thuẫn (1.8.6 tháng 6/2026 vs 1.9.3 tháng 8/2026). Submodule đang ở `941bdab` (2026-02-04); trong bản này flash-attn **đã bật mặc định**, có VAD Silero. | https://github.com/ggml-org/whisper.cpp/releases | Không gấp; chỉ cập nhật nếu cần tính năng mới |
| D10 | Thông tin PhoWhisper (theo trí nhớ, **chưa kiểm**): VinAI, fine-tune từ Whisper đa ngôn ngữ trên ~844 giờ tiếng Việt, có bản tiny/base/small/medium/large; bản large dựa trên large-v2 (80 mel). Giấy phép: chưa rõ. **Có xuất dấu câu/chữ hoa hay không: chưa rõ** (rủi ro lớn nhất — xem 5.4). | https://huggingface.co/vinai/PhoWhisper-medium · https://github.com/VinAIResearch/PhoWhisper | Model card, `config.json` (`num_mel_bins`, số lớp decoder), license, ví dụ output |

Kiểm `SpeechTranscriber` có tiếng Việt không (macOS 26, chưa chạy thử đoạn này):
```bash
cat > /tmp/locales.swift <<'EOF'
import Speech
let st = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
let dt = await DictationTranscriber.supportedLocales.map(\.identifier).sorted()
print("SpeechTranscriber vi:", st.filter { $0.hasPrefix("vi") }, "of", st.count)
print("DictationTranscriber vi:", dt.filter { $0.hasPrefix("vi") }, "of", dt.count)
EOF
swift /tmp/locales.swift
```

---

## 5. Kế hoạch test PhoWhisper (ưu tiên 1)

Mục tiêu: trả lời 4 câu — (1) chính xác hơn Groq/turbo bao nhiêu trên giọng của bạn,
(2) có dấu câu + chữ hoa không, (3) nhanh tới đâu trên Mac của bạn, (4) tốn bao nhiêu RAM.

### 5.1 Chuẩn bị (Mac Apple Silicon)

```bash
git fetch origin claude/review-project-performance-p8kyla
git checkout claude/review-project-performance-p8kyla
git submodule update --init --recursive
./build.sh                      # app; cấp lại quyền Accessibility + Microphone (README)
tools/build-bench.sh            # build-bench/bin/whisper-server, whisper-quantize
```

Bộ test (làm song song, càng sớm càng tốt):
```bash
defaults write com.tqt.whispertype KeepRecordings -bool true
# đọc như bình thường 30–50 lần, đủ kiểu câu (ngắn, dài, có tên riêng, số, tiếng Anh xen kẽ)
ls ~/Library/Caches/com.tqt.whispertype/samples/
```
Sau đó **sửa tay từng `.txt`** cho đúng với điều bạn đã nói (giữ dấu câu/viết hoa như bạn
muốn thấy). Chưa sửa thì WER chỉ đo mức "giống Groq", và Groq sẽ ~0 % với chính nó.

### 5.2 Chuyển PhoWhisper sang ggml

Bắt đầu với **medium** (cân bằng tốc độ/độ chính xác), sau đó small và large nếu cần.

```bash
python3 -m venv ~/venv-pho && source ~/venv-pho/bin/activate
pip install torch transformers numpy "huggingface_hub[cli]"

git clone --depth 1 https://github.com/openai/whisper ~/src/whisper     # chỉ cần mel_filters.npz
hf download vinai/PhoWhisper-medium --local-dir ~/src/PhoWhisper-medium
#   (bản huggingface_hub cũ: huggingface-cli download vinai/PhoWhisper-medium --local-dir ...)
#   Đừng dùng "git clone https://huggingface.co/..." khi chưa có git-lfs: chỉ được file con trỏ.

ls ~/src/PhoWhisper-medium      # cần: config.json, vocab.json, model.safetensors hoặc pytorch_model.bin
# Script convert đọc added_tokens.json nhưng KHÔNG dùng nội dung; repo mới thường không có file này:
[ -f ~/src/PhoWhisper-medium/added_tokens.json ] || echo '{}' > ~/src/PhoWhisper-medium/added_tokens.json

mkdir -p ~/models/out
python3 external/whisper.cpp/models/convert-h5-to-ggml.py ~/src/PhoWhisper-medium ~/src/whisper ~/models/out
mv ~/models/out/ggml-model.bin ~/models/ggml-phowhisper-medium.bin          # f16
build-bench/bin/whisper-quantize ~/models/ggml-phowhisper-medium.bin ~/models/ggml-phowhisper-medium-q5_0.bin q5_0
build-bench/bin/whisper-quantize ~/models/ggml-phowhisper-medium.bin ~/models/ggml-phowhisper-medium-q8_0.bin q8_0
```

Kiểm nhanh file convert: chạy bench `--limit 3` (bước 5.3) rồi xem
`build-bench/results/ggml-phowhisper-medium.bin.server.log` — phải thấy model type `medium`,
`n_mels = 80`, không có "tensor … not found"/"wrong shape".

Sự cố hay gặp khi convert (dự đoán, chưa gặp thực tế):
- `KeyError` trong `config.json` (vd. `max_length`): script đã tự xử lý `max_length`; key khác thiếu → đối chiếu `config.json` với `openai/whisper-medium`.
- Lỗi tensor lạ khi nạp → so `num_mel_bins` (80 vs 128) và cấu trúc lớp với model gốc.

### 5.3 Chạy so sánh

```bash
S=~/Library/Caches/com.tqt.whispertype/samples
# vòng nhanh: 3 mẫu, xem output có hợp lý không
tools/bench_local.py --samples $S --limit 3 ~/models/ggml-phowhisper-medium-q5_0.bin
# vòng đầy đủ
tools/bench_local.py --samples $S --download \
    ~/models/ggml-phowhisper-medium.bin \
    ~/models/ggml-phowhisper-medium-q8_0.bin \
    ~/models/ggml-phowhisper-medium-q5_0.bin \
    large-v3-turbo-q5_0 large-v3-turbo \
    groq:whisper-large-v3
```
Kết quả: bảng trên màn hình + `build-bench/results/summary.md`; transcript từng mẫu ở
`build-bench/results/<engine>/`. Groq dùng key trong `defaults` của app hoặc `GROQ_API_KEY`.

Tuỳ chọn thêm: `--vad-model <ggml-silero-*.bin>` (bỏ đoạn im lặng; tải bằng
`external/whisper.cpp/models/download-vad-model.sh`), `--threads N`.

### 5.4 Đọc kết quả — tiêu chí chọn

| Câu hỏi | Xem cột | Ngưỡng gợi ý |
|---|---|---|
| Chính xác hơn không? | WER %, CER % (trên `.txt` **đã sửa tay**) | ≤ Groq, hoặc kém hơn không quá ~1 điểm |
| Dùng gõ văn bản được không? | **punct %**, **caps %** + đọc tay vài file trong `results/` | Gần bằng Groq. **Nếu PhoWhisper ra chữ thường không dấu câu** (khả năng có thật vì dữ liệu tiếng Việt công khai thường như vậy) thì WER vẫn đẹp nhưng không dùng gõ trực tiếp được → hoặc thêm model khôi phục dấu câu, hoặc dùng turbo |
| Nhanh hơn chờ upload không? | p50/p90 so với dòng `groq:` (đo trên mạng của bạn) | p90 local < p90 Groq |
| RAM | RAM MB | q5_0/q8_0 nếu máy 8–16 GB |
| Ảo giác | Mẫu im lặng/nhiễu trong `results/` | Không có câu bịa |

Ghi bảng `summary.md` + nhận xét vào cuối tài liệu này (mục 8) để lưu lại.

### 5.5 Dùng trong app

```bash
defaults write com.tqt.whispertype LocalModelFile -string ~/models/ggml-phowhisper-medium-q5_0.bin
defaults write com.tqt.whispertype LocalModelEnabled -bool true
defaults write com.tqt.whispertype PreferLocalModel -bool true      # hoặc menu: Use Local Model First
# khởi động lại app, rồi:
log stream --style compact --predicate 'process == "Whispertype"' | grep -E "loaded in|Local transcription|Timing"
```
Mong đợi: `Whisper model ggml-phowhisper-medium-q5_0.bin loaded in N s`, mỗi lần đọc có
`Timing: … local N s …`. Lỗi nạp hiện trên menu: "Local model: Cannot load …".

---

## 6. Checklist test thủ công các bản sửa (Mac)

| Test | Thao tác | Mong đợi |
|---|---|---|
| Build | `./build.sh` | Không lỗi; ghi lại warning mới nếu có (A8) |
| B1 | Bật Local Model (model đã có sẵn) rồi gõ liên tục trong TextEdit; đọc một đoạn dài cho app gõ ra trong khi bạn cũng gõ | Không khựng bàn phím |
| B2/A3 | `tccutil reset Microphone com.tqt.whispertype`, từ chối quyền, bấm ⌥Space 2 lần | Beep + "Microphone: …", không kẹt "Recording..." |
| B3/A4 | Ghi bằng mic USB/AirPods, ngắt thiết bị giữa chừng, bấm dừng | App về Ready/Transcribing trong ≤ 1,5 s |
| B7 | Giữ ⌥Space 2 giây | Chỉ bắt đầu ghi, không tự dừng |
| B7 | ⌘⌥Space | Mở cửa sổ tìm kiếm Finder, app không phản ứng |
| B5/B6 | Bật/tắt Local Model trong menu, xem Activity Monitor | Menu không đứng; RAM giảm khi tắt |
| B11 | `MaxRecordingSeconds 120`, ghi ~2 phút với Network Link Conditioner ~100 KB/s | Không bị cắt ở 45 s; log ghi `total Ns` theo kích thước |
| B12 | Chỉ nói "Enter" | Nhấn Return, không gõ chữ "Enter." |
| Log | Đọc vài lần | Có đủ dòng `Recording started`, `Groq timing`, `Timing:` |
| A6 | Ghi 2 lần cách nhau < 20 s | Lần 2: `reused connection` |
| KeepRecordings | Bật key, đọc 2 lần | `samples/` có `.wav` + `.txt` |
| PreferLocal | Tick menu | Log `Timing: … local …`; tắt mạng vẫn gõ ra chữ |

---

## 7. Đề xuất chưa làm (backlog)

1. **Lệnh giọng nói inline** (`src/textinjector.mm`): "tab" và "xoá" kích hoạt cả giữa câu
   ("mở tab mới" → nhấn Tab; "xoá file này" → xoá phần đã gõ). Whisper thường viết "xóa"
   (đặt dấu kiểu cũ) nên trigger "xoá" hiện có thể không bao giờ khớp. Cần quyết định hành vi
   (chỉ khi đứng riêng? có tiền tố "lệnh …"?) rồi chuẩn hoá Unicode/kiểu bỏ dấu khi so.
2. **Tự dừng sau 30 s không báo gì** → phần nói sau đó mất. Thêm âm báo hoặc tăng mặc định.
3. **Giảm dung lượng upload**: cắt im lặng đầu/cuối (VAD), kiểm lại FLAC (A10).
4. **Chạy song song (hedge)**: nếu Groq chưa xong sau N giây và local sẵn sàng → chạy local,
   lấy kết quả đến trước.
5. **Engine sherpa-onnx** cho Zipformer-30M (rất nhẹ, nhanh) + model khôi phục dấu câu, nếu
   PhoWhisper/turbo không đạt.
6. Lọc câu ảo giác (A11) nếu thấy xảy ra.

---

## 8. Kết quả test (session kiểm tra điền vào)

Session kiểm tra 2026-11-03, M1 Pro / 16 GB, macOS 27.2, whisper.cpp submodule `941bdab` (Metal).

**Bộ test.** Chưa có `samples/` (cần app mới + `KeepRecordings`), và `failed/` chỉ có 2 bản ghi
thật, không có `.txt`. Nên dùng **FLEURS vi_vn test**: 40 câu ngẫu nhiên (seed 42), đáp án
`raw_transcription` có dấu câu và chữ hoa, chuyển sang s16 16 kHz như app ghi. Lưu ý: FLEURS là
giọng đọc câu Wikipedia, nhiều tên nước ngoài, nên **thiên về Whisper gốc**. Bộ này không thay được
giọng của bạn.

PhoWhisper-medium tự convert từ `vinai/PhoWhisper-medium`:
- `pytorch_model.bin` → `model.safetensors` (`torch.load(weights_only=True)`), vì transformers 5.2 +
  torch 2.5 từ chối nạp `.bin`.
- Sau đó chạy `convert-h5-to-ggml.py`. File f16 nặng 1.533.763.076 byte, trùng kích thước với
  `dongxiat/ggml-PhoWhisper-medium`.
- Server log: `type = 4 (medium)`, `n_mels = 80`, không có lỗi tensor.

| Ngày | Máy (chip/RAM) | Model | WER % | punct % | caps % | p50 s | p90 s | RAM MB | Ghi chú |
|---|---|---|---|---|---|---|---|---|---|
| 2026-11-03 | M1 Pro / 16 GB | PhoWhisper-medium f16 | 9,7 | 100 | **0** | 1,02 | 1,27 | 1854 | FLEURS 40; CER 6,8; **0 dấu phẩy** (đáp án 50), không chia câu |
| 2026-11-03 | M1 Pro / 16 GB | PhoWhisper-medium q8_0 | 9,7 | 100 | 0 | 0,98 | 1,26 | 1119 | như f16 |
| 2026-11-03 | M1 Pro / 16 GB | PhoWhisper-medium q5_0 | 9,6 | 100 | 0 | 0,94 | 1,16 | 827 | như f16 |
| 2026-11-03 | M1 Pro / 16 GB | large-v3-turbo q5_0 | 10,0 | 98 | 100 | 0,98 | 1,05 | 736 | CER 5,1; 55 dấu phẩy, 6/7 chỗ chia câu |
| 2026-11-03 | M1 Pro / 16 GB | large-v3-turbo f16 | 9,7 | 98 | 100 | 0,87 | 0,95 | 1818 | CER 4,9 |
| 2026-11-03 | M1 Pro / 16 GB | groq:whisper-large-v3 | 9,2 | 89 | 100 | 2,84 | 4,94 | – | **19 câu đầu** (giới hạn RPM); cùng 19 câu: turbo-q5 9,9 / PhoWhisper-q5 10,2. Mạng chiều 16:50, không phải giờ tối |
| 2026-11-03 | M1 Pro / 16 GB | turbo-q5_0 + VAD Silero v6.2.0 | 10,9 | 98 | 100 | 1,04 | 1,11 | 743 | VAD làm WER tệ hơn (cắt đầu câu) |
| 2026-11-03 | M1 Pro / 16 GB | PhoWhisper-q5_0 + VAD | 8,8 | 100 | 0 | 0,98 | 1,21 | 838 | |

**Hai bản ghi giọng thật trong `failed/`** (không có đáp án, `build-bench/results-real/`):

| Engine | `…222212_138` (5,6 s) | `…214137_081` (1,7 s) |
|---|---|---|
| Groq large-v3 | Nếu nói 3-5 ngày Tết một lần thì phải có lý do chứ. | Lâu lâu thế bạn có lang chạy không đấy? |
| turbo f16 / q5_0 | Nếu nói 3 đến 5 ngày Tết một lần nó phải có lý do chứ | Bao lâu thế bạn có đang chạy không đấy? |
| PhoWhisper q5_0 | nếu nói ba đến năm ngày tết là lần nó phải có lý do chứ. | bao lâu thế bạn có đang chạy không đấy. |
| turbo q5_0 + VAD | (như không VAD) | **Thế** bạn có lang chạy không đấy (mất "Bao lâu") |

**Ảo giác (A11)**: 5 s im lặng, nhiễu hồng nhẹ và nhiễu nâu (`build-bench/results-silence/`).

| Engine | Kết quả |
|---|---|
| Groq | "Hãy subscribe cho kênh La La School Để không bỏ lỡ những video hấp dẫn" / "Cảm ơn các bạn đã theo dõi." |
| turbo (cả hai bản) | Giống Groq, thêm "… và hẹn gặp lại." |
| PhoWhisper | Câu bịa trông như thật ("đó là sự tấn công lớn nhất của hội việt nam vào thời điểm này.") nên **không lọc được bằng danh sách** |
| Có VAD | Cả 3 file ra rỗng (0,02 s) |

**Kết luận**

1. **PhoWhisper-medium không dùng gõ trực tiếp được.** Toàn chữ thường, không có dấu phẩy, mỗi
   đoạn chỉ một dấu chấm cuối (kể cả câu hỏi), số viết bằng chữ ("ba đến năm"). WER trên FLEURS
   ngang turbo; CER tệ hơn (6,8 so với 4,9), chủ yếu do tên riêng. Muốn dùng phải thêm model khôi
   phục dấu câu và chữ hoa.
2. **large-v3-turbo-q5_0 là ứng viên local tốt nhất cho máy này:**
   - WER 10,0 so với Groq 9,2 trên cùng 19 câu là 9,9: chênh 0,7 điểm, trong ngưỡng 5.4.
   - Dấu câu và chữ hoa đầy đủ.
   - p50 ~1,0 s, p90 1,05 s, so với Groq p50 2,8 s / p90 4,9 s **ngay cả lúc mạng tốt**.
   - RAM ~740 MB.
   - Trên 2 câu thật, turbo cho câu 2 hợp lý hơn Groq ("Bao lâu…đang chạy" so với "Lâu lâu…lang chạy");
     chủ dự án cần xác nhận câu đã nói.
   - f16 nhanh hơn một chút (0,87 s) nhưng tốn 1,8 GB, không đáng.
3. **Ảo giác có thật và xảy ra cả với Groq hiện tại.** VAD chặn được 100 %, nhưng nếu dùng VAD để
   *cắt* audio thì mất đầu câu ngắn. Đề xuất: dùng VAD làm **cổng**: không có tiếng nói → không gửi
   và không gõ gì; có tiếng nói → gửi nguyên audio. Hoặc tăng `--vad-speech-pad-ms`, nhưng chưa thử.

**Ghi chú về từng mục A1–A12, D1–D10**

- **A1–A7, A9: chưa kiểm.** Cần cài app mới vào /Applications (phải cấp lại quyền) và test tay theo
  mục 6. Session này chỉ build `--no-install` để khỏi đụng quyền của bản đang dùng.
- **A8: đạt.** `./build.sh --no-install` (Xcode SDK 26.5, target 26.0) build sạch; không có cảnh báo
  nào trong `src/`. Các tên API viết theo trí nhớ đều đúng.
- **A10: đúng.**
  - `ffmpeg -c:a flac -sample_fmt s16` trên 2 bản ghi thật cho 61 % và 54 % kích thước WAV.
  - Giải mã ra PCM giống hệt từng bit (md5 khớp), nên transcript chỉ có thể khác do Groq không
    tất định.
  - Bản FLAC kém trước đây là do `AVAudioRecorder` ghi 24-bit. Muốn dùng FLAC phải tự mã hoá 16-bit
    (vd. `AVAudioFile`/`ExtAudioFile` với ASBD 16-bit, hoặc libFLAC), không qua `AVAudioRecorder`.
  - Chưa gửi bản FLAC lên Groq.
- **A11: đúng, nặng hơn dự đoán** (bảng trên).
- **A12: đúng.** `whisper-server` nhận `language`, `no_timestamps`, `temperature`,
  `response_format=json`; output không có timestamp.
- **Mới: `tools/bench_local.py` chưa bao giờ đo được Groq.** Cloudflare của Groq trả 403
  (error code 1010) cho User-Agent `Python-urllib/x.y`, trong khi curl với cùng key trả 200. Đã sửa:
  gửi User-Agent `whispertype-bench/1.0`.
- **Mới: bằng chứng cho B7/B2 trên bản đang cài.** 57/59 file trong `failed/` là WAV rỗng 4 KB (chỉ
  header). Các loạt lớn có 15 và 13 file (18/10) và 21 file (26/10), mỗi file cách nhau ~67 ms
  (nhịp auto-repeat); ngoài ra có loạt nhỏ 1–3 file vào 4/10, 5/10, 9/10, 16/10.
- **D1: đúng.** Các cột là VIVOS / Common Voice / VLSP Task 1 / TB; số đã chuẩn hoá (bỏ hoa và dấu
  câu). Số của PhoWhisper-large chép từ bài PhoWhisper.
- **D2: đúng số, nhưng là cột N-WER (bỏ hoa và dấu câu), trung bình bộ "Natural".**
  - Đứng đầu là **hynt/Zipformer-30M-RNNT-6000h 6,77**, đoạn trích cũ bỏ sót.
  - PhoWhisper-medium có O-WER (giữ hoa và dấu câu) tốt nhất bảng là 16,73, nhưng vẫn gấp đôi N-WER.
  - Không có large-v3/turbo/PhoWhisper-large, không có cột tốc độ.
- **D3: sai nguồn.**
  - Bài arXiv 2603.14779 (PhoASR, VinAI) không nói gì về Zipformer. Các số 12,29 / 10,40 / 0,3 s
    nằm trên model card hynt/Zipformer-30M.
  - Bài PhoASR cho thấy PhoWhisper-small O-WER 33,90 so với N-WER 8,97, tức yếu dấu câu/chữ hoa,
    khớp với kết luận 1.
- **D4: 6.000 giờ đúng.**
  - Con số ~70.000 giờ của `phostt` là của model khác (`sherpa-onnx-zipformer-vi-2025-04-20`,
    VietASR 68M).
  - Giấy phép Zipformer-30M là **CC-BY-NC-ND-4.0**: không thương mại, không phái sinh.
- **D5: đúng** (arXiv 2505.21527, Bảng 3).
- **D6: đúng** (Qwen3-ASR có tiếng Việt; card chính thức không có WER riêng cho tiếng Việt).
- **D7: đã chạy.** `SpeechTranscriber`: không có `vi` (0/45 locale). `DictationTranscriber`: **có
  `vi_VN`** (trong 54). Đây là hướng on-device không cần model riêng, chưa đánh giá chất lượng.
- **D8: sai.** HF có `dongxiat/ggml-PhoWhisper-{base,small,medium}`, `Briansss/ggml-PhoWhisper-large`,
  `hoangecg/phowhisper-large-ggml`.
- **D9: cả hai con số đều cũ.**
  - Mới nhất là v1.9.5 (2026-10-06): có encoder trên Apple Neural Engine (tuỳ chọn) và tinh chỉnh
    Metal cho M1–M3 (v1.9.4).
  - Submodule đã bật flash-attn mặc định.
- **D10:**
  - Giấy phép BSD-3-Clause; 80 mel, 24+24 lớp, d_model 1024; dữ liệu 844 giờ.
  - WER trong bài: medium VIVOS 4,97 / CMV 8,27 / VLSP T1 14,12.
  - Model card/bài báo không nói gì về dấu câu; thực tế: **không có chữ hoa và dấu phẩy**.
