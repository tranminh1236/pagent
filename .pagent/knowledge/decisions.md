# Decision Log — pipelineAgent

_Nhật ký quyết định thiết kế (ADR). Append-only: mục mới nối ở cuối, mục cũ bất biến._

## ADR 2026-07-03 — Thêm hàng stat cards total per-project vào card chat

- **Context:** Card section chat cần hiển thị các con số tổng (total spend...) thay đổi theo từng project, theo mẫu screenshot yêu cầu.
- **Decision:** Tách riêng helper `fmtSpend` (2 số lẻ, dạng `$84.88`) cho card headline thay vì tái dùng `fmtCost` (4 số lẻ); giữ nguyên `fmtCost` cho bảng chi tiết/history. Màu spend đưa qua CSS-variable `--spend` theo convention repo. Giữ nguyên thứ tự section `chat → workflow → live` vì task chỉ yêu cầu thêm stat cards.
- **Consequences:** Định dạng tiền tách làm hai lớp (headline vs chi tiết) cần đồng bộ về sau; token màu tập trung ở `:root` dễ chỉnh theme.
- **Ref:** features/2026-07-03-20260703T013837-36378-1226.md

## ADR 2026-07-03 — Mở rộng agent roster: +architecture/performance/security, reviewer→Leader Code, rewire pipeline

- **Context:** Pipeline cần review sâu và tách trách nhiệm rõ hơn: chất lượng cấu trúc, hiệu năng và bảo mật đang dồn vào một agent review chung, orchestrator lại làm việc trực tiếp với coder/reviewer nên thiếu tầng điều phối business.
- **Decision:** Thêm 3 agent review chạy trước coder (architecture, performance, security); nâng reviewer thành "Leader Code" (senior full task + business, thống nhất/cân đối review của 3 agent để ra rule code cho coder); orchestrator kiêm Project owner và chỉ làm việc qua Leader Code, không trực tiếp với coder/reviewer; tester phối hợp performance+security cho test hiệu năng/bảo mật và orchestrator cho test business; coder phải tự viết unit test cho function mình sinh ra.
- **Consequences:** Chuỗi review nhiều tầng hơn (nặng hơn mỗi run nhưng bắt lỗi sớm và phân cấp bảo mật theo feature); assertion test co-located phải cập nhật theo wording mới; còn 1 fail `model=opus` là pre-existing, để dọn riêng ngoài scope.
- **Ref:** features/2026-07-03-20260703T035422-36378-8410.md

## ADR 2026-07-03 — Hoàn thiện tầng review 3 auditor → Leader Code ép coder sửa lỗi

- **Context:** 3 auditor (architecture/performance/security) review code coder gen ra và báo Leader Code để bắt coder sửa, nhưng quality gate còn hở: auditor/reviewer có `Bash` trần (write-capable), verdict parse bằng grep toàn file dễ leak PASS giả, và diff bị chạy lại 3× song song tốn token.
- **Decision:** Bỏ `Bash` trần khỏi 4 agent read-only (architecture/performance/security/reviewer), thêm `disallowed_tools` backstop (Write/Edit/NotebookEdit/Bash) + `max_turns`; neo verdict parse vào block `## VERDICT` fail-closed CHANGES_REQUESTED thay vì grep toàn file; snapshot diff 1×/vòng dùng chung read-only; coder thêm mục xử lý verdict CHANGES_REQUESTED (sửa hết BLOCKING/MAJOR, xuất `## CHANGES` mới mỗi vòng); clamp `eff_max_round` vào `[1,cap]`.
- **Consequences:** Quality gate read-only chắc hơn và chặn PASS giả nhưng chuỗi review thêm ràng buộc cấu hình cần đồng bộ; giữ 1 fail `model=opus` pre-existing ngoài scope. Repo verify bằng static-assertion shell test (không chạy pipeline live).
- **Ref:** features/2026-07-03-20260703T060557-36378-7134.md

## ADR 2026-07-03 — Gate auditor arch/perf/sec theo business logic (code-touch guard)

- **Context:** Không phải task nào cũng cần 3 auditor (architecture/performance/security); task thuần logic/prompt/meta không chạm code không nên kéo cả 3, nhưng gộp `config` vào bucket bỏ auditor vô điều kiện lại khiến config nhạy cảm (rotate creds, nới auth, nâng rate limit) không bao giờ được review.
- **Decision:** Bước 0 orchestrator là nơi DUY NHẤT chọn auditor theo code-touch; thêm carve-out "config runtime chạm bề mặt rủi ro → GIỮ auditor tương ứng" (`security`: auth/secret/credential/permission/CORS/TLS/PII; `performance`: rate-limit/pool/cache/worker/timeout/tài nguyên), bullet-2 THẮNG bullet-1; chỉ config không chạm bề mặt mới rơi bucket bỏ auditor. Leader Code (reviewer.md) đồng bộ luật, chỉ prune được chứ không thêm.
- **Consequences:** Task prompt/meta thuần vẫn = `["coder","reviewer"]` (không auditor), tránh dư review; nhưng terminology carve-out phải giữ đồng bộ giữa orchestrator và reviewer; diff prompt-only nên không có unit test, chỉ smoke-test wiring hiện có.
- **Ref:** features/2026-07-03-20260703T064021-36378-2178.md

## ADR 2026-07-03 — Đảo thứ tự section web: chat → live → workflow

- **Context:** ADR trước (stat cards) giữ thứ tự `chat → workflow → live`; nay ưu tiên hiển thị Live ngay dưới chat, workflow đẩy xuống sau.
- **Decision:** Hoán vị nguyên vẹn 2 khối `<section id="workflow-section">` và `<section id="live-section">` trong `kit/web/index.html`, thứ tự DOM mới `chat → live → workflow → agent → history`. Không đổi id/class; vị trí render do thứ tự DOM (main stack block flow, style.css không có `order`/grid-area override). app.js chỉ truy cập qua id (workflow-list/live-list/live-dot/live-count/workflow-count) nên không neo vào thứ tự DOM. Đảo quyết định "giữ nguyên thứ tự" ở ADR stat cards cùng ngày.
- **Consequences:** Đổi thuần vị trí DOM, không ảnh hưởng logic JS/CSS.
- **Ref:** kit/web/index.html

## ADR 2026-07-03 — Bổ sung 2 agent mới: devops (CI/CD + Docker + env) và docs (swagger + admin config)

- **Context:** Pipeline thiếu tầng hạ tầng và tài liệu: chưa có agent chốt env/CI/CD và setup file Docker cho dev+deploy, cũng chưa có agent cập nhật swagger/OpenAPI và config admin page khi API thay đổi.
- **Decision:** Thêm `devops` là writer-agent (Write/Edit/Bash) chạy SỚM trước coder (khối `[1c]`) để hạ tầng/env sẵn cho coder+deploy dựa vào — sinh Dockerfile/compose dev+deploy, `.gitlab-ci.yml`, đồng bộ `.env.pagent`/`.env.pagent.example`; thêm `docs` scope-hẹp (mô phỏng workflow-extractor) chạy CUỐI sau tester (khối `[4d]`) với `disallowed_tools: Bash,NotebookEdit` chặn sửa code runtime, chỉ cập nhật swagger + admin config. Cả hai gate qua `agent_enabled` hiện có, tách khỏi vòng ENABLED_AUDITORS và KHÔNG ràng buộc reviewer (không phải auditor).
- **Consequences:** Pipeline dài thêm 2 chặng đầu-cuối (nặng hơn mỗi run nhưng hạ tầng/tài liệu tự động hoá); `disallowed_tools` chỉ chặn theo tên tool nên scope doc-only của docs phải dựa thêm ràng buộc prompt; valid-values `required_agents` + guard orchestrator + roster web/source-summary phải giữ đồng bộ. Verify bằng static-assertion (`test_devops_docs.sh`: 48 passed).
- **Ref:** features/2026-07-03-20260703T070528-11542-6972.md

## ADR 2026-07-03 — Bổ sung rule CI/CD chi tiết cho agent devops

- **Context:** Agent `devops` cần rule cụ thể hơn cho hạ tầng: phân biệt file dev-code (compose) với deploy-server (Dockerfile), và `.gitlab-ci.yml` phải phủ deploy/clean, giới hạn log, chọn runner, network-host, push image và cache theo stack.
- **Decision:** Chỉ sửa `kit/agents/devops.md` (prompt-only): nhánh dev-code BẮT BUỘC `docker-compose.yml`, nhánh deploy-server BẮT BUỘC `Dockerfile` multi-stage; mở rộng `.gitlab-ci.yml` thêm stage `deploy`+`clean` (prune giữ N=`KEEP_IMAGE_VERSIONS` mặc định 3), log ≤1GB mount ra `LOG_HOST_DIR`, `tags` từ `RUNNER_TAGS`, toggle `USE_NETWORK_HOST`, flag `pushImage` (false → build trên server né registry), cache pnpm/go mount ra host; đồng bộ biến mới vào `.env.pagent`+`.env.pagent.example` và block Output `## ENV_VARS`. Không đổi frontmatter/cấu trúc để giữ invariant test.
- **Consequences:** Rule hạ tầng chi tiết hơn giúp devops sinh file nhất quán và tối ưu disk/log server, nhưng thêm nhiều biến ENV (`RUNNER_TAGS`, `USE_NETWORK_HOST`, `pushImage`, `LOG_HOST_DIR`, `KEEP_IMAGE_VERSIONS`, `CACHE_PNPM_DIR`/`CACHE_GO_DIR`) cần giữ đồng bộ; tên biến cache là placeholder, devops bám convention repo target khi sinh thật. Verify bằng static-assertion (`test_devops_docs.sh`: 48 passed).
- **Ref:** features/2026-07-03-20260703T072908-11542-9534.md

## ADR 2026-07-03 — Web: section riêng hiển thị AI workflow spec (agent-workflow.md)

- **Context:** Web UI chưa hiển thị AI workflow spec do workflow-extractor sinh ra ở `REPORTS/<proj>/agent-workflow.md`; cần bổ sung nhưng không được trộn lẫn với Workflow log sẵn có.
- **Decision:** Tách hoàn toàn nguồn AI workflow khỏi Workflow log — loader/parser/route/section/hàm/CSS đều namespace riêng (`agent-workflow`/`ai-wf-*`); nguồn neo `REPORTS/<proj>/agent-workflow.md` (KHÔNG phải `.pagent/knowledge/`); parser split-by-`## ` giữ raw `content` + `blocks`; render bằng `textContent` chống XSS. KHÔNG generalize `read_workflow` hay đụng `#stat-workflows`/extractor.
- **Consequences:** Parser chịu được format lệch (fallback raw) và file rỗng mà không vỡ trang; empty-state (`exists=false`) là đường mặc định hiện tại; namespace `agent-workflow`/`ai-wf-*` phải giữ tách biệt khỏi workflow log về sau.
- **Ref:** features/2026-07-03-20260703T074256-28903-7680.md

## ADR 2026-07-13 — Flag opt-in PAGENT_SAVE_TOKEN (gate model rẻ runtime + nới guard auditor)

- **Context:** Khi chạy backend rẻ (opencode 9router/Free) muốn save token mà KHÔNG hạ chất lượng thực thi/review, và KHÔNG được phá hành vi mặc định của mọi run hiện có.
- **Decision:** Thêm 1 flag opt-in `PAGENT_SAVE_TOKEN` (mặc định `0` = TẮT) gate **2 trục** độc lập. Trục (1) — model rẻ runtime: tại DISPATCH (`call_agent`), nếu flag bật và agent thuộc nhóm 'đơn giản' (`orchestrator`/`docs`/`workflow-extractor`/`designer`) thì query list model từ gateway (`ANTHROPIC_BASE_URL` `/v1/models`, seam test/manual `PAGENT_SAVE_TOKEN_MODELS`), chọn model rẻ (ưu tiên `free` → `haiku/mini/flash/lite/small/nano/8b`) và đè per lần gọi backend (opencode: giữ prefix `provider/`, claude/openrouter: tên trần); coder/reviewer/auditor/tester/devops GIỮ model mạnh. Trục (2) — nới guard: inject `[RUNTIME] PAGENT_SAVE_TOKEN=<val>` vào system prompt orchestrator để khi bật thì ưu tiên hạng thấp/bỏ auditor cho nhiều task hơn (tối thiểu `["coder","reviewer"]`), GIỮ carve-out config runtime security/performance. Flag=0 → không chạy cả 2 nhánh (không query gateway, guard nguyên trạng). Query list model lỗi/rỗng → fallback im, không fail run.
- **Model gán ở RUNTIME thay vì frontmatter:** tôn trọng commit `f7836cd` (kit-agents-drop-model) đã CỐ Ý gỡ `model:` khỏi `kit/agents/*.md` để 9router combo tự phân phối model. Thêm lại `model:` vào frontmatter sẽ mâu thuẫn quyết định đó (và test_opencode_backend khẳng định opencode KHÔNG lấy model từ frontmatter). Vì vậy model rẻ chỉ áp ở tầng dispatch qua biến per-call, không đụng file agent.
- **Consequences:** Bất biến flag=0 = 0 regression (verify: test_env_provider 7/7, test_opencode_backend 33/33 không đổi). Nhóm agent 'đơn giản' và heuristic keyword model rẻ là danh sách cứng trong `pagent` (`savetoken_is_simple`/`savetoken_cheap_model`) — nếu thêm agent/đổi tên gateway model phải cập nhật đồng bộ. Guard nới ở trục (2) là thay đổi prompt-only nên phụ thuộc orchestrator tuân directive; carve-out security/performance phải giữ đồng bộ giữa nhánh save-token và Bước 0/0b. Verify: test_save_token.sh 24/24.
- **Ref:** kit/agents/orchestrator.md, pagent (savetoken_*), tests/test_save_token.sh
