# Thử ECO antenna sau route bằng OpenROAD mới (2026-10-15)

Kết luận: bước 1 đến 3 đạt. Bước 4 dừng ngay ở lượt đầu vì OpenROAD mới crash (segfault) trong `repair_antennas`. Không có gì được sửa hay ghi vào `gemm_ip/runs`. Bước 5 và 6 chưa làm.

## Bước 1: tìm hiểu
Chi tiết ở `BUOC1_tim_hieu.md`. Tóm tắt:
- Bản dùng là LibreLane 3.0.16, bản stable mới nhất (6/10/2026). Image `ghcr.io/librelane/librelane@sha256:4bc9042b…7205051` (amd64), nén 1,51 GB, giải nén **7,33 GB**. OpenROAD trong image là `dcf36133` (17/2/2026); đã kiểm `openroad -version` khớp.
- `Odb.InsertECODiodes` chèn đúng một diode cho mỗi mục, đặt tại instance đích. Step này khoá mọi cell cũ rồi chạy detailed placement, nên chỉ cell mới được dời. Sau đó nó gọi GRT tăng dần (`updateDirtyRoutes`): xoá dây của các net bẩn, route lại bằng FastRoute, lưu guide.
- `Odb.InsertECOBuffers`: chọn được cell buffer. Đích là driver hoặc sink. Khi đặt ở driver, buffer nằm ở trọng tâm driver và các sink, lái toàn bộ net cũ. Như vậy sửa được DRV kiểu "driver yếu", nhưng chỉ một buffer, không chia cây.
- DRT chỉ route lại net bị sửa: net nào còn dây ROUTED được đánh dấu `hasInitialRouting`. Các lượt 0–2 chạy ở chế độ `RipUpMode::INCR`, bỏ qua những net đó, nên chỉ net đã mất dây được route. Từ lượt 3, DRT sửa marker như bình thường, nên vẫn có thể động tới net cũ ở sát chỗ lỗi.
- `drt.tcl` của LibreLane có sẵn vòng sửa antenna sau DRT: `check_antennas` → `repair_antennas DIODE -ratio_margin 10 [-allow_congestion]` → `detailed_route`, tối đa 3 vòng. Số diode trên mỗi gate do bộ kiểm antenna tính theo luật, có xét PWL. Jumper chỉ dùng được khi chưa có detailed route, nên sau DRT chỉ còn cách chèn diode.
- Cần `-allow_congestion`. Nếu không bật, GRT tăng dần sẽ kéo thêm mọi net đi qua ô nghẽn vào để route lại, và đánh dấu guide là congested (DRT dừng với lỗi DRT-352).

## Bước 2: chuẩn bị
- Ổ đĩa: 60,6 GB trước khi pull, 51,3 GB sau khi pull (≥ 40 GB). Hiện còn 51,8 GB; `~/ip_eco_probe` chiếm khoảng 3,7 GB.
- Đã chép DEF cuối (round1, giống hệt `results/final/def`), DEF round2, netlist thường và netlist có chân nguồn của round1, SDC cuối, SPEF min/nom/max, báo cáo antenna và DRC của round1 và round2.
- LEF: tech `sky130_fd_sc_hd__nom.tlef`, `sky130_ef_sc_hd.lef`, `sky130_fd_sc_hd.lef` lấy từ `~/.ciel/sky130A`; `sram_antenna.lef`, `GemmAxiShell_antenna.lef`, `ProcessingElementRow.lef` lấy đúng các file OpenLane đang dùng. Không dùng PDK đi kèm image mới.

## Bước 3: kiểm khớp (đạt)
| | ip_v3r (OpenLane, ARC) | OpenROAD dcf3613 | Ghi chú |
|---|---|---|---|
| DEF round1 đọc rồi ghi lại | – | 3 699 654 cell, 146 562 net (146 306 có dây): 0 khác | file ra cùng số byte |
| Antenna round1 (DEF cuối) | 446 chân | 450 chân / 437 net | trùng 444; bản mới dư 6, thiếu 2 |
| Antenna round2 | 293 chân (báo cáo ghi 294 dòng) | 292 chân / 285 net | trùng 288; dư 4, thiếu 5 |

Con số 294 trong yêu cầu là của round2. DEF cuối của ip_v3r là round1 (446 chân, DRT 0, khớp SPEF signoff), nên bước 4 lấy round1 làm gốc. Thời gian mỗi lần kiểm khoảng 1 phút, RAM đỉnh 2,6 GB.

## Bước 4: dừng ở lượt 1, OpenROAD crash
- `check_antennas` trước khi sửa: 437 net, giống bước 3.
- `repair_antennas sky130_fd_sc_hd__diode_2 -iterations 1 -ratio_margin 10 -allow_congestion` gây **Signal 11** sau 124 s (RAM đỉnh khoảng 2,6 GB). Chưa chèn diode nào, chưa ghi gì. Log ở `s4/r1.log`.
- Nguyên nhân (đọc mã nguồn, không chạy thêm): `ant/src/WireBuilder.cc:641` `dbNetIsLocal()` lấy `*db_net->getGuides().begin()` mà không kiểm tập guide có rỗng hay không. Hàm này được gọi cho mọi net có từ hai chân trở lên, trước cả khi kiểm net đã có detailed route hay chưa (dòng 59–61). DEF không lưu route guide, nên mọi net đọc từ DEF đều không có guide, và lệnh crash ở net đầu tiên. Trong LibreLane không gặp lỗi này vì ODB đi qua các step luôn mang guide từ bước GRT.

## Đề xuất (chờ anh quyết)
1. **Tạo guide từ dây có sẵn** (khuyên dùng): một script đọc DEF round1, với mỗi net phủ các gcell 6,9 µm mà mỗi đoạn dây và via đi qua, theo từng lớp, rồi ghi ra file guide. Trong bản mới chạy `read_guides` trước `repair_antennas`. Guide khi đó bám đúng đường dây thật, nên DRT có tháo một net cũ ra ở lượt ≥ 3 cũng route lại trong cùng hành lang. Kiểm lại bằng cách đọc DEF, đọc guide, ghi DEF và so: phải không đổi gì. Ước lượng chạy: vài phút.
2. Gắn tạm một guide giả (một hộp tại chân driver) cho mỗi net chỉ để vượt qua chỗ crash. Nhanh hơn, nhưng net cũ bị DRT tháo ra ở lượt ≥ 3 sẽ không có hành lang đúng. Tôi không khuyên dùng.
3. Dùng `global_route` của bản mới để sinh guide: không được. GRT bỏ qua net đã có dây (`GlobalRouter.cpp:1322`), nên net cũ vẫn không có guide.

Các bước 5 và 6 đã có sẵn script (`scripts/s5_ol.tcl`, `scripts/ol.sh`) nhưng chưa chạy, theo luật "gặp lỗi thì dừng".

---

# Lần 2: dựng guide từ dây (4a, 4b). Dừng ở 4b, chưa làm 4c và 5

## 4a. Dựng guide
- ip_v3r **không còn file guide nào** của global route vòng 1, vì tmp đã được dọn trước đó. Không đối chứng với OL1 được.
- Script `scripts/mkguide.py` đọc DEF vòng 1 và dựng guide theo lưới GCELLGRID trong DEF (6,9 µm, gốc 0). Đoạn dây phủ mọi ô mà đường tâm đi qua, trên đúng lớp của nó. Via phủ ô của nó trên cả hai lớp. li1 (via L1M1 xuống chân cell) tính vào met1, vì met1–met5 là dải route. Toạ độ nằm đúng trên biên ô thì phủ cả hai ô hai bên.
- Net không dây: có 256 net, đều chỉ có một chân. Đó là `o_weight_shift_out[0..255]` của `g_pe_row[0]`, đầu ra không có tải, chân trên met2. Guide của chúng lấy ô dưới chân, trên lớp met2 (`scripts/guide_pins.tcl`).
- Kết quả: 146 562/146 562 net có guide, 3,55 triệu ô, file 137 MB, sinh trong 17 s.
- Tỉ lệ dây nằm trong guide: 100 % theo cách dựng (guide sinh ra từ chính dây). Không có số % so với guide OL1 vì file đó không còn.

## 4b. Kiểm guide
- Đọc DEF, nạp guide, ghi lại: **giống hệt từng byte** so với DEF gốc. Mọi net không đặc biệt đều có guide.
- `check_antennas` sau khi nạp guide: **450 chân / 437 net**, đúng như trước.
- ECO rỗng (`detailed_route -droute_end_iter 64 -or_seed 42 -verbose 1`, lớp lấy từ `set_routing_layers`): **không đạt**.
  - Lần chạy đầu dừng vì lỗi cú pháp của tôi: bản mới bỏ `-bottom/-top_routing_layer` (DRT-0509). Đã sửa.
  - Lần hai: DRT báo [ERROR] ngay khi xử lý guide, trước khi route. Watcher dừng container sau 565 s; mã 137 là do `docker stop`, không phải hết RAM. RAM lúc vào DRT khoảng 6,3 GB. Không có DEF ra.
  - **DRT-0222 × 256** "Pin … o_weight_shift_out[i] is not visited by any guide": đúng 256 net một chân ở trên. GRT bình thường không tạo guide cho net một chân, nên DRT không bao giờ xử lý chúng. Khi được cho guide, DRT đòi chân phải có điểm truy cập nằm trong guide và báo lỗi. Ràng buộc "mọi net có chân phải có guide" mâu thuẫn ở đây. Chỗ crash của `repair_antennas` chỉ xét net có từ 2 đầu nối trở lên, nên net một chân không cần guide.
  - **DRT-0218 × 42** "Guide is not connected to design": lỗi của bộ dựng guide. DEF có `GCELLGRID X 0 DO 1054 STEP 6900`, ô cuối cùng ôm luôn phần dư tới mép die (x > 7 265 700). Hàm của tôi kẹp chỉ số cuối mà không kẹp chỉ số đầu, nên đoạn dây nằm hẳn trong phần dư bị bỏ. Ví dụ `net1511` (đi tới `addr1[6]` của SRAM ở mép phải) mất đoạn met1, met2 và hai via. Kiểm liên thông offline: bản cũ có 109 net guide bị đứt (DRT kịp báo 42 trước khi dừng). **Đã sửa** (`s4a/v2/round1.guide`): 0 net đứt trên 146 562. **Chưa chạy lại DRT**, theo luật dừng.

## Đề xuất (chờ anh quyết)
1. Dùng guide v2 (đã sửa phần mép die) và **bỏ guide cho 256 net một chân**, giống hệt GRT. Chạy lại 4b đủ ba kiểm tra (DEF giống hệt, antenna 450, ECO rỗng không route lại net nào, 0 DRT), rồi mới sang 4c.
2. Nếu anh muốn giữ đúng câu "mọi net có chân phải có guide", cần thêm bước tạo điểm truy cập cho chân không nối của macro. Tôi chưa thấy cách làm trong DRT bản này, nên không đề xuất.

Ổ đĩa: 50,7 GB trống. Không có container nào đang chạy.

---

# Lần 3: guide v2/v3, chạy lại 4b. DỪNG HẲN theo mục 3, chưa làm 4c và 5

## Nguyên nhân và cách sửa guide
1. **DRT-0218 (guide đứt)**: lỗi của `mkguide.py`. Ô cuối cùng của lưới (`GCELLGRID … DO 1054 STEP 6900`) ôm luôn phần dư tới mép die, mà hàm `cells()` chỉ kẹp chỉ số cuối, không kẹp chỉ số đầu. Đoạn dây nằm hẳn trong phần dư (x > 7 265 700) vì vậy bị bỏ. Đã sửa: kẹp cả hai đầu. Kiểm offline: guide liền mạch ở 146 562/146 562 net (bản cũ có 109 net bị đứt).
2. **Mục 1, chân nằm trong guide**: đã xuất 391 793 chân (`guide_pins_all.tcl`), mỗi chân với lớp và hình bao; li1 318 729, met1 3 249, met2 59 392, met3 4 423, met4 6 000 (gồm chân SRAM, row và ip_shell5). Mỗi chân phải chạm một ô guide của net, ở lớp của chân hoặc lớp kề trên (li1 tính là met1). Guide v2 đạt: 391 793/391 793.
3. **DRT-0222 (chân không được ghé qua)**, chạy 4b với v2: 256 lỗi, đúng 256 net một chân (`g_pe_row[0]/o_weight_shift_out[*]`, đầu ra không tải). Ngoài ra 0 lỗi DRT-0218. Nguyên nhân, đọc từ mã DRT `GuideProcessor.cpp`: `GuidePathFinder::traverseGraph` chạy `số chân − 1` lượt, với net một chân là 0 lượt, rồi trả về true ("skip one-pin net"). Sau đó `commitPathToGuides` không thấy chân nào được ghé qua và báo DRT-0222. Vậy **mọi guide gắn vào net một chân đều chắc chắn gây lỗi**. GRT không bao giờ tạo guide cho những net này. Đã sửa (v3): bỏ guide cho net một chân. `repair_antennas` (chỗ crash ban đầu) chỉ xét net có từ hai đầu nối, nên không ảnh hưởng. v3: 146 306 net nhiều chân đều có guide, liền mạch; 391 537/391 537 chân của chúng được phủ.

## 4b với guide v3 (lần chạy lại cuối được phép)
- Đọc DEF, nạp guide, ghi lại: **giống hệt từng byte**. Đạt.
- `check_antennas`: **450 chân / 437 net**. Đạt.
- ECO rỗng (`detailed_route -droute_end_iter 64 -or_seed 42 -verbose 1`): chạy hết, **0 lỗi DRT ở cuối**, không có [ERROR], antenna sau vẫn 450/437. Thời gian khoảng 57 phút (DEF ghi lúc 21:56, xong lúc 22:53), RAM đỉnh 10,27 GB (vượt 10g một ít, phần dư vào swap).
- **Nhưng DRT đã sửa layout cũ: không đạt.** Ở lượt 0, DRT mới tự tìm thấy **3 vi phạm Metal Spacing (2 trên met2, 1 trên met4)** trên layout vòng 1, mà DRT của OpenLane 1.0.2 báo 0 và Magic signoff không coi là lỗi thật. Diễn biến: lượt 0–2 còn 3, lượt 3–4 còn 2, lượt 5 về 0. Để sửa, DRT **route lại 3 net cũ** (0,002 % số net): `net20371` (tới `wmask0[2]` của SRAM `u_accum_mem g_bank[0].g_lane[27]`), `_08932_` (một đoạn met3 dài bị tách, thêm một nhịp met2 ở x ≈ 6683,6–6685,4 µm, ngay cạnh chân SRAM đó) và `i_weight_shift_in[92]`. Các thay đổi đều là sửa cục bộ quanh chỗ vi phạm; 146 303 net còn lại giữ nguyên hình học, và không có cell nào đổi.
- Theo mục 3 ("DRT gỡ hoặc route lại net cũ dù guide đã đủ: dừng hẳn"), tôi **dừng hẳn**. Chưa chạy 4c, chưa chạy bước 5.

## Nhận định để anh quyết
- Đây không còn là vấn đề guide. **DRT bản mới hiểu luật spacing khác DRT cũ** ở vùng chân SRAM (cùng LEF và tech LEF), nên coi layout vòng 1 có 3 lỗi. Mọi lượt ECO bằng bản mới sẽ sửa luôn 3 chỗ này. Như vậy hai bản không cho kết quả "không đổi gì" trên đúng layout của ip_v3r.
- Hướng nếu muốn đi tiếp: (a) chấp nhận 3 net này bị route lại như một phần của lượt ECO đầu và đo phần còn lại theo ngưỡng 5 %, rồi kiểm 3 chỗ đó bằng Magic và `magic_macro_check.sh` ở bước 5; hoặc (b) dừng hướng này.
- File giữ lại: `s4a/v3/round1.guide`, `s4b/v3/empty_eco.def` (DEF sau ECO rỗng), `s4b/v3/changed.nets`, các log `s4b/v2.log` và `s4b/v3.log`. Ổ còn 48,9 GB; `~/ip_eco_probe` chiếm 6,0 GB. Không có container nào đang chạy.

---

# Lần 4: 4c theo phương án 1. Dừng ở lượt 1 (lỗi DPL-0036); bước 5 chưa chạy

## Đính chính về 3 net của ECO rỗng
Báo cáo trước viết "cả 3 net đều quanh `wmask0[2]`". **Sai, chỉ 2 net ở đó.** Toạ độ và hình học trước/sau của cả 3 net ở `s4c/wmask_3nets.txt`:
- **Chỗ 1**, cạnh SRAM `u_accum_mem g_bank[0].g_lane[27]` (gốc (6581,68; 2847,84) µm), sát đáy SRAM ở chân `wmask0[2]`:
  - `net20371` (tới `wmask0[2]`): đoạn met3/met4 được đi lại; via M3M4 dời từ (6683,34; 2847,50) sang (6684,55; 2847,33).
  - `_08932_`: đoạn met3 dài ở y 2846,82 bị tách, thêm một nhịp met2 6683,57–6685,41 µm với 2 via M2M3.
- **Chỗ 2**, không cạnh SRAM. Nằm trong rãnh giữa row macro `g_pe_row[14]` (y 8157,28–8290,56) và `g_pe_row[13]` (từ y 8312,32), gần mép tây x ≈ 3747 µm:
  - `i_weight_shift_in[92]`: route lại toàn bộ trên met1/met2, vùng x 3723,0–3753,4 µm, y 8286,3–8302,0 µm.

DRT bản mới thấy 3 vi phạm Metal Spacing (met2 × 2, met4 × 1). Theo vị trí thay đổi thì met4 và một met2 ở chỗ 1, met2 còn lại ở chỗ 2. Tôi vẫn đi tiếp vì quyết định của anh là chấp nhận đúng 3 net này. Ở bước 5, phần kiểm riêng sẽ kiểm cả hai chỗ: script `scripts/spot_check.sh` cắt cửa sổ cố định từ GDS cuối (view đầy đủ của SRAM và row) rồi chạy Magic drc(full), không miễn trừ gì.

## 4c, lượt 1: không đạt
- Gốc: DEF vòng 1 cùng guide v3. `check_antennas` trước khi sửa: 450 chân / 437 net.
- `repair_antennas sky130_fd_sc_hd__diode_2 -iterations 1 -ratio_margin 10 -allow_congestion`:
  - GRT-0012: 666 vi phạm khi tính với margin 10 %.
  - GRT-0243: có net không sửa được bằng diode.
  - **Dừng với DPL-0036 "Detailed placement failed" trên 787 diode mới**, kèm DPL-0037 "Use remove_fillers before detailed placement".
  - Không có DEF ra; thời gian khoảng 1,5 phút; RAM khoảng 4,8 GB.
- Nguyên nhân: DEF vòng 1 là layout **cuối, đã lấp kín** bằng 1 895 706 `sky130_ef_sc_hd__decap*`, 605 877 `sky130_fd_sc_hd__decap*` và 524 772 `sky130_fd_sc_hd__fill*`. Tất cả thuộc LEF `CLASS CORE SPACER`, nên không còn site trống nào cho diode. `repair_antennas` khoá mọi cell cũ, nên DPL không đẩy được filler ra.
- Trong LibreLane, ECO đặt ngay sau `DetailedRouting`, tức **trước** `FillInsertion`, nên không gặp chuyện này. DEF của ip_v3r lại ở sau bước lấp filler.

## Đề xuất (chờ anh quyết)
1. Trong cùng tiến trình OpenROAD: `remove_fillers` (gỡ mọi cell CORE SPACER, tức filler và decap, không có dây tín hiệu nên route không đổi) → vòng ECO 4c → lấp lại bằng `filler_placement` với đúng danh sách cell của OL1 (`DECAP_CELL`/`FILL_CELL` của ip_v3r). Bước 5 (Magic, LVS) kiểm lại toàn bộ. Hệ quả: khoảng 3 triệu cell filler/decap bị đặt lại, nên DEF khác ở COMPONENTS, nhưng không đổi dây.
2. Chỉ gỡ filler và decap trong bán kính nhỏ quanh mỗi chân cần diode, rồi lấp lại cục bộ. Thay đổi ít hơn nhưng phải viết thêm script.

Bước 5 chưa chạy. Ổ còn khoảng 49 GB; không có container nào chạy.

---

# Lần 5: 4c (gỡ filler cục bộ) và bước 5

## Cách làm 4c
Script `scripts/s4c_round.py` chạy trong một tiến trình `openroad -python` (dcf3613). Driver `scripts/s4c_try.sh` lo phần dự phòng: ±15 µm, nếu hỏng thì ±30 µm, nếu vẫn hỏng thì `remove_fillers` toàn bộ. **Cả 3 lượt đều qua ngay ở ±15 µm, không cần dự phòng.**
1. **Danh sách đích**: các gate vi phạm khi margin 10 % (mặc định của LibreLane).
   - Python không duyệt được `Violation.gates` vì SWIG không bọc vector. Vì vậy gate được lấy từ báo cáo verbose của `check_antennas` (margin 0), áp đúng phép so của `checkPAR`/`checkPSR`: tỉ lệ đo được > tỉ lệ cho phép × (1 − 0,1). CAR/CSR không có margin.
   - Kiểm chéo bằng `getAntennaViolations(net, diode, 10)` cho từng net: 665/665 khớp, so với 666 mà GRT-0012 báo (lệch 1 net).
   - Net có `diode_count_per_gate = 0` là net không sửa được bằng diode, ghi vào `s4c/rN.nofix.tsv`.
2. **Gỡ filler**: mọi instance `CORE_SPACER` (fill, decap fd/ef) có hình bao giao cửa sổ ±15 µm quanh instance đích. Tap (`CORE_WELLTAP`) và cell có chân tín hiệu không bị đụng.
3. **ECO**: `repair_antennas sky130_fd_sc_hd__diode_2 -iterations 1 -ratio_margin 10 -allow_congestion` → `detailed_route -droute_end_iter 64 -or_seed 42 -verbose 1` → `filler_placement "sky130_ef_sc_hd__decap_12 sky130_fd_sc_hd__decap_8 sky130_fd_sc_hd__decap_6 sky130_fd_sc_hd__decap_4 sky130_fd_sc_hd__decap_3 sky130_fd_sc_hd__fill*"`, đúng `$DECAP_CELL $FILL_CELL` của `fill.tcl` OL1 → global connect như `set_global_connections` của OL1 (VPWR/VPB → vccd1, VGND/VNB → vssd1).
   - Lượt 1 chưa có global connect, nên 65 676 cell mới chưa nối nguồn trong DB. Từ lượt 2 đã thêm; lượt 2 đọc ODB của lượt 1 và nối lại hết: 0 chân nguồn hở.
4. **Kiểm sau mỗi lượt**:
   - ô trống trong hàng: tổng chiều dài hàng trừ tổng bề rộng cell CORE;
   - vị trí mọi cell không phải filler (`compcheck.py`);
   - số net bị route lại: so hình học DEF (`defgeo.py`), so với DEF vào của lượt đó.

## Kết quả từng lượt (gốc: DEF vòng 1, 450 chân / 437 net)
| | Lượt 1 | Lượt 2 | Lượt 3 |
|---|---|---|---|
| Vào | DEF vòng 1 + guide v3 | r1.odb | r2.odb |
| Antenna trước (net) | 437 | 35 | 4 |
| Đích ở margin 10 % | 665 net, 683 gate | 44 net, 47 gate | 5 net, 7 gate |
| Net không sửa được bằng diode | 4 | 1 | 0 |
| Filler/decap bị gỡ (±15 µm) | 65 627 | 6 740 | 565 |
| Diode chèn | 787 | 47 | 7 |
| Lỗi DRT (lượt DR 0 → cuối) | 9 → 0 | 47 → 0 | 4 → 0 |
| Site trống sau DRT → sau khi lấp lại | 533 387 → 0 | 47 518 → 0 | 4 563 → 0 |
| Cell không phải filler bị dời | 0 | 0 | 0 |
| Net bị route lại (so DEF vào) | 878 (0,60 %) | 65 (0,04 %) | 10 (0,01 %) |
| Antenna sau (net / chân) | 35 / 37 | 4 / 6 | **3 / 3** |
| Thời gian (wall) | 1021 s | 1008 s | 993 s |
| RAM đỉnh | 10,28 GB | 10,26 GB | 10,28 GB |

Ghi chú:
- Net bị route lại ở lượt 1 gồm 666 net được gắn diode, 3 net đã chấp nhận (`net20371`, `_08932_`, `i_weight_shift_in[92]`) và các net bị DRT gỡ ra ở chỗ có lỗi.
- **Tổng cộng so với DEF vòng 1: 899/146 306 net bị route lại (0,61 %), 841 diode, 0 cell không phải filler bị dời, 0 site trống.**
- RAM đỉnh vượt 10g khoảng 0,3 GB (phần dư vào swap). Máy không đơ.

Net mà `repair_antennas` báo không sửa được bằng diode (`diode_count_per_gate = 0`):
- Lượt 1: `_10952_` (met3), `net22326` (met3), `r_output_mem_read_data[157]` (met3), `r_output_mem_read_data[528]` (routing level 0).
- Lượt 2: `net47228` (met4).
- Lượt 3: không có.

Không net nào trong số này còn trong danh sách vi phạm cuối: chúng hết vi phạm sau khi DRT route lại ở các lượt sau.

**3 chân còn vi phạm sau lượt 3** (đều là PSR, diện tích cạnh trên met1; mức cho phép 400):
- `net41488` → `_28408_/A1`: 555
- `r_output_mem_read_data[286]` → `_22738_/C`: 658
- `r_output_mem_read_data[888]` → `_27232_/B`: 426

Cả ba đã được gắn diode ở lượt 2 hoặc 3 mà vẫn trượt. Mức cho phép trong báo cáo vẫn là 400, nghĩa là bảng PWL không nâng mức cho phép khi thêm diffusion của diode. Cần xử lý riêng, ví dụ đi lại đoạn met1 lên lớp trên.

## Bước 5
- Nhập vào OpenLane 1.0.2 (`scripts/s5_ol.tcl`, run ở `s5/eco_r3_arc`): đọc DEF `s4c/r3.def`, ghi DEF, ODB, netlist và netlist có chân nguồn. `gemm_ip/runs` không bị đụng.
- **ARC (OL1): 3 chân**, đúng 3 chân trên; tỉ lệ 668/557/427 so với 400, sát với bản mới.
- **DRT: 0** ở cả 3 lượt (`s4c/r*.drt.drc` rỗng).
- **Magic DRC** (run `s5/eco_r3`, cell chuẩn view đầy đủ như `gemm_magic_drc`): **0 lỗi** (`drc.rpt`: COUNT 0). GDS, Magic và SPICE mất khoảng 3,4 giờ.
- **`magic_macro_check.sh`**: **PASS**, không có marker nào để kiểm.
- **`spot_check.sh`** (Magic drc(full) trên GDS cuối, view đầy đủ của SRAM và row, không miễn trừ gì), báo cáo `s5/spot_check.rpt`:
  - Chỗ 1, cửa sổ (6675–6695, 2838–2858) µm quanh `wmask0[2]` của SRAM `u_accum_mem g_bank[0].g_lane[27]`: **0 lỗi**.
  - Chỗ 2, cửa sổ (3715–3762, 8280–8308) µm ở rãnh `g_pe_row[14]`/`g_pe_row[13]`: 1382 hộp lỗi, **tất cả nằm trong dải 0,5 µm sát mép cắt**. Đó là hình bị cắt ngang ở biên cửa sổ (li.1, poly.1a, licon.1… trên những lát mỏng 0,005–0,05 µm ở x = 3715, y = 8280 và y = 8308), cùng cách loại mà `magic_macro_check` dùng. Bên trong cửa sổ: **0 lỗi**. Vùng của `i_weight_shift_in[92]` (3723–3753, 8286–8302) cách mép ít nhất khoảng 6 µm.
- **LVS** (run `s5/eco_r3_lvs`, netgen theo LEF như ip_v3r): **"Circuits match uniquely"**, 120 887 thiết bị và 150 212 net ở cả hai phía, Total errors = 0. Diode tăng từ 36 052 lên 36 893, tức +841, đúng bằng số diode chèn ở 4c. Thời gian khoảng 2 giờ (wall 7408 s cho cả lần nhập và ARC).
- Lỗi phát sinh khi chạy bước 5, đều đã sửa, đều do script của tôi:
  1. `package require openlane 0.9` không có trong image; đổi thành `package require openlane` như các script của repo.
  2. Lần chạy full đầu tiên, LVS hỏng ở `write_powered_def` ("Power port VPWR not found"). Nguyên nhân: script bỏ qua floorplan nên VDD_PIN/GND_PIN mặc định là VPWR/VGND, và VDD_NET không có. Đã thêm đúng đoạn đặt các biến này của `ip_resume.tcl`, rồi chạy lại riêng LVS (chế độ `lvs`). Magic DRC của lần chạy đầu vẫn dùng được vì không phụ thuộc mấy biến này.

## So với ip_v3r
| | ip_v3r (vòng 1) | Sau ECO (s4c/r3) |
|---|---|---|
| Antenna (ARC OL1) | 446 chân | **3 chân** |
| DRT | 0 | 0 |
| Magic DRC (sau `magic_macro_check`) | 0 lỗi thật | 0 |
| LVS | khớp | **khớp** (+841 diode) |
| Net bị route lại | – | 899 / 146 306 (0,61 %), gồm 3 net đã chấp nhận |
| Cell không phải filler bị dời | – | 0 |

Chưa làm: bước 6 (hold, DRV, STA ba corner trên SPEF trích lại). Chưa trích RC hay chạy STA trên layout mới.

Ổ đĩa: còn 23,9 GB (trước 4c khoảng 49 GB); `~/ip_eco_probe` chiếm 31 GB, trong đó s5 17 GB và s4c 8,8 GB. Không còn container nào chạy.

---

# Lần 6: bước 0 và 6a. Dừng trước 6b (ARC = 1, chưa phải 0)

## Bước 0: dọn ổ
- Đã xoá DEF/ODB/geo/sum trung gian của 4b và lượt 1–2 (`s4b/v3/empty_eco.*`, `s4b/guides_rt.geo.tsv`, `s4c/r1.{def,odb,geo.tsv}`, `s4c/r2.{def,odb,geo.tsv}`) và `s4c/tmp`.
- Báo cáo antenna verbose của 4b và lượt 1–2 **nén gzip, không xoá** (giảm 96,6 %).
- Giữ nguyên: lượt 3 (`s4c/r3.{def,odb,geo.tsv}`), guide, script, mọi báo cáo, `in/` (DEF gốc vòng 1), s5, ip_v3r, image LibreLane.
- Ổ trống: **23 937 MiB → 31 615 MiB**; `~/ip_eco_probe`: 31 483 MiB → 23 804 MiB.

## 6a: 3 chân còn lại
**Vì sao diode không cứu được** (phân tích đảo met1 từ dây trong `s4c/r3.def`, script `s6a/islands.py`): ở cả ba net, cổng vi phạm nằm một mình trên một **đảo met1 dài không có diode**. Diode được `repair_antennas` đặt sát cổng, nhưng DRT nối chúng vào những đảo met1 khác của net, đi qua met2. Tỉ lệ riêng phần ở met1 chỉ tính diffusion trên cùng đảo với cổng.
- `net41488`: `_28408_/A1` một mình trên đảo 99,1 µm. 3 diode (`ANTENNA_35197/35647/35673`) nằm trên đảo 4,1 µm bên cạnh; diode thứ tư nằm cùng đảo với `_57257_`.
- `r_output_mem_read_data[286]`: `_22738_/C` một mình trên đảo 117,8 µm. 2 diode (`ANTENNA_35666/35676`) nằm trên đảo 0,46 µm.
- `r_output_mem_read_data[888]`: `_27232_/B` một mình trên đảo 149,6 µm. 4 diode nằm trên các đảo 0,9–4,6 µm.

**Đổi cỡ** (điều kiện: ANTENNAGATEAREA mới ≥ cũ × tỉ lệ vượt × 1,2; tỉ lệ vượt lấy giá trị lớn hơn giữa bản mới và ARC của OL1):
| Cell / chân | Cũ | Cần ≥ | Chọn | Mới |
|---|---|---|---|---|
| `_28408_` mux2_1 / A1 (vượt 1,392) | 0,126 | 0,2105 | **mux2_4** | 0,2475 |
| `_27232_` nand2_1 / B (vượt 1,068) | 0,2475 | 0,3171 | **nand2_2** | 0,495 |
| `_22738_` and3_1 / C (vượt 1,671) | 0,126 | 0,2527 | **không có cỡ đạt** (and3_2: 0,126; and3_4: 0,2475) | – |

Không cell nào nằm trên net clock, và không cỡ nào thuộc DONT_USE.

**Cách đặt** (`scripts/s6a_resize.py`, dcf3613):
1. Gỡ filler ±15 µm quanh hai cell: 140 cell.
2. `swapMaster`, rồi DPL với mọi cell khác bị khoá: chỉ hai cell này dời. `_28408_` từ (4242,12; 938,40) MX sang (4242,12; 935,68) R0, tức một hàng. `_27232_` từ (6704,50; 3266,72) sang (6704,50; 3277,60) MX, tức bốn hàng.
3. GRT tăng dần (`IncrementalGRoute`, `allow_congestion`) cho 7 net của hai cell, rồi `detailed_route` (DR: 15 → 10 → 0 lỗi), rồi `filler_placement` theo danh sách OL1 (0 site trống), rồi global connect (0 chân nguồn hở).

Kết quả so với lượt 3 (`compcheck`):
- **Cell không phải filler bị đổi: đúng 2** (hai cell trên); filler: thay 5.
- **Net bị route lại: 12** (0,01 %): 7 net của hai cell, cộng `_08804_ _08806_ _08808_ _08811_ _08915_` bị DRT gỡ ra ở chỗ lỗi.
- DRT 0. Antenna (dcf3613) 3 → **1**.
- Thời gian 1027 s, RAM đỉnh 10,2 GB.

Ba lần chạy đầu của 6a hỏng do script của tôi, chưa ghi gì:
1. `swapMaster` bị segfault vì callback của dbSta so cell liberty mà chưa nạp lib. Đã nạp lib TT.
2. Vòng mở khoá cuối truy cập tới filler đã bị xoá. Đã xoá filler trước rồi mới khoá.

**ARC (OpenLane 1.0.2, `s5/eco_r4_arc`): 1 chân**, là `_22738_/C` (668,44 / 400) → **chưa đạt điều kiện "ARC phải ra 0", nên dừng, chưa làm 6b.**

## Phương án cho `_22738_/C` (chưa làm, chờ anh chọn)
1. **and3_4** (cùng chức năng, cùng tên chân, rộng 4,14 µm thay vì 2,30 µm): tỉ lệ còn 668,44 × 0,126 / 0,2475 ≈ **340 / 400**, tức đạt luật với dư 15 %. Hệ số an toàn là 1,18×, thiếu chút so với 1,2× anh đặt. Đổi chân A/B/C không giúp gì vì cả ba chân có cùng diện tích.
2. **Buffer ECO ngay trước chân C** (đích sink, cell có diện tích A lớn, ví dụ buf_6 với A = 0,495 µm²): đảo met1 117,8 µm sẽ nối vào chân A của buffer, tỉ lệ ước khoảng 668 × 0,126 / 0,495 ≈ 170 (dư 2,3×), còn C chỉ thấy một đoạn dây ngắn. Đổi lại thêm một cell và một nhịp trễ trên path `r_output_mem_read_data[286]` → `_22738_`, phải xét ở 6b.
3. Đi lại đoạn met1 dài lên met2/met3 (jumper) bằng tay, hoặc ép DRT nối diode vào đúng đảo của C: không điều khiển được bằng lệnh hiện có, phải can thiệp tay.

Ổ còn 26 714 MiB. Không có container nào chạy.

---

# Lần 7: buffer cho `_22738_/C`, ARC = 0, 6b (đo timing, chưa sửa gì)

## Buffer ECO cho `_22738_/C` (net `r_output_mem_read_data[286]`)
- Điều kiện: ANTENNAGATEAREA ≥ 0,126 × 1,65 × 1,2 = 0,2495 µm². buf_4 (0,2475) hụt; **chọn `sky130_fd_sc_hd__buf_6`** (A = 0,495 µm², không thuộc DONT_USE; danh sách chỉ cấm buf_16).
- Cách làm (`scripts/s6a_buffer.py`, giống `Odb.InsertECOBuffers` khi đích là sink):
  1. gỡ 99 filler ±15 µm;
  2. khoá mọi cell khác;
  3. tạo `eco_buffer_0`: chân A nối net cũ, chân X nối net mới `eco_buffer_0_net`, `_22738_/C` chuyển sang net mới;
  4. đặt buffer tại `_22738_` rồi DPL; buffer nằm ở (4316,64; 4662,08) R0, ngay hàng trên `_22738_` (4315,26; 4659,36);
  5. GRT tăng dần 2 net → `detailed_route` (DR: 9 → 8 → 0) → `filler_placement` (0 site trống) → global connect (0 chân hở).
- Antenna (dcf3613): 1 → **0**. DRT 0. Net bị route lại so với r4: 4 net cũ (`r_output_mem_read_data[286]`, `_04919_`, `_05054_`, `net18457`) cộng 1 net mới. Cell không phải filler bị dời: 0. Thời gian 1089 s, RAM đỉnh 10,2 GB.
- **Slack setup qua `_22738_/C`** (OpenRCX dcf3613 với luật nom của PDK như OL1; std cell tt/ss, macro lib TT, propagated clock, SDC cuối). Path đi từ SRAM `u_accum_mem g_bank[0].g_lane[8]` (đọc), qua `_22738_`, về chính SRAM đó (ghi):
  | | Trước | Sau | Δ |
  |---|---|---|---|
  | TT | +4,833 ns | +4,748 ns | −0,085 |
  | SS | +0,395 ns | +0,240 ns | −0,155 |
- Lỗi trong lúc làm, đều do script của tôi hoặc lỗi công cụ; không ghi gì sai ra layout:
  1. Chạy OpenRCX trong cùng tiến trình trước DRT làm DRT báo DRT-1010 "non-orthogonal wire", vì OpenRCX sắp xếp lại dbWire. Đã tách: đo timing ở tiến trình riêng.
  2. `r5.odb` do dcf3613 ghi **không đọc lại được** ("odb file is invalid: iostream error"), trong khi `r4.odb` đọc tốt. `r5.def` ghi ngay sau đó thì đọc tốt. Mọi bước sau dùng `r5.def`.
- **ARC (OL1, `s5/eco_r5_arc`): 0 chân.** Cả ba chỗ (`_28408_` mux2_4, `_27232_` nand2_2, buffer mới) đều sạch.

## Tổng thay đổi so với DEF vòng 1 (446 chân)
- Antenna (ARC OL1) 446 → **0**. DRT 0.
- Net bị route lại: **911/146 306 (0,62 %)**, thêm 1 net mới (`eco_buffer_0_net`).
- Cell không phải filler bị đổi: 2 (`_28408_`, `_27232_`, đổi cỡ và dời 1 và 4 hàng); thêm 841 diode và 1 buf_6.
- Filler gỡ trong cả quá trình: 4c 72 932 (65 627 + 6 740 + 565), 6a 239 (140 + 99). Không còn site trống.
- Magic DRC và LVS đã đạt ở bước 5 trên layout lượt 3. **Chưa chạy lại Magic/LVS sau 6a** (2 cell đổi cỡ, 1 buffer).

## 6b: timing trên layout sau 6a (chưa sửa gì)
- Trích RC bằng OL1 (`run_parasitics_sta`, RCX min/max/nom như signoff, SDC cuối của ip_v3r), run `s5/eco_r5_sta`, 858 s.
- Phân tích (`scripts/sta6b.tcl`, OpenROAD của OL1): **cùng một script cho cả ip_v3r (SPEF signoff) và bản ECO.** Đo worst path của mọi endpoint; tách cell→cell, path chạm macro (SRAM/row/AXI) và I/O (có port ở một đầu). DRV tính theo giới hạn lib, đã bỏ `set_max_transition/fanout` của SDC. 18 lần chạy, tổng 1117 s, RAM đỉnh 4,3 GB.
- Kiểm chéo với số cũ của ip_v3r: TT nom DRV 435 net cell (430 slew, 387 cap); hold FF RC max −0,056 ở `csb1`. Trùng khớp.

### Setup (ns, worst; trong ngoặc là số endpoint < 0)
| Corner / RC | cell→cell v3r → ECO | chạm macro v3r → ECO | I/O v3r → ECO |
|---|---|---|---|
| TT min | 11,585 → 11,570 | 1,957 → 1,947 | 8,514 → 8,491 |
| TT nom | 11,397 → 11,382 | 1,490 → 1,489 | 8,212 → 8,183 |
| TT max | 11,271 → 11,255 | 1,025 → 1,022 | 7,962 → 7,932 |
| FF min/nom/max | 14,50/14,38/14,30 → 14,50/14,37/14,29 | 4,18/3,71/3,21 → 4,18/3,71/3,21 | ≥ 7,7 cả hai |
| SS min | 1,914 → 1,876 | −4,411 (1249) → −4,393 (1250) | 1,012 → 1,007 |
| SS nom | 1,046 → 1,005 | −4,957 (1276) → −4,999 (1277) | 0,757 → 0,752 |
| SS max | 0,484 → 0,438 | −5,416 (1321) → −5,396 (1317) | 0,501 → 0,496 |

TT: setup ≥ 0 ở mọi path nội bộ, cả hai bản. SS: path chạm macro âm ở cả hai bản, gần như không đổi (chính sách: SS setup chỉ báo kèm fmax).

### Hold (ns, worst; trong ngoặc là số endpoint < 0)
| Corner / RC | cell→cell v3r → ECO | chạm macro v3r → ECO | I/O v3r → ECO |
|---|---|---|---|
| TT min/nom/max | 0,405/0,345/0,326 → 0,405/0,345/0,324 | 0,532/0,414/0,312 → 0,539/0,424/0,322 | ≥ 0,64 cả hai |
| FF min | 0,180 → 0,180 | 0,159 → 0,163 | −0,070 (1) → −0,067 (1): `feature_axis_tready` |
| FF nom | 0,141 → 0,141 | 0,043 → 0,051 | 0,093 → 0,096 |
| FF max | 0,131 → 0,130 | **−0,056 (1) → −0,049 (1)**: `_56646_/Q` → `weight_mem g_bank[0].g_lane[3]/csb1` | 0,270 → 0,272 |
| SS min/nom/max | 1,25/1,15/1,12 → 1,25/1,15/1,12 | 0,42/0,24/0,19 → 0,43/0,25/0,22 | −2,43/−2,74/−3,04 (551/592/607) → −2,43/−2,75/−3,05 (554/594/607) |

Hold nội bộ: chỉ còn **một endpoint âm, `csb1` ở FF RC max: −0,049 ns** (ip_v3r: −0,056). Cell→cell ≥ 0 ở mọi corner. I/O báo riêng.

### DRV theo giới hạn lib (số net)
| Corner / RC | cell chuẩn (slew, cap) v3r → ECO | SRAM dout cap | SRAM addr/wmask slew (miễn trừ) |
|---|---|---|---|
| TT min | 336 (331, 325) → 334 (331, 324) | 409 → 414 | 1440 → 1440 |
| TT nom | 435 (430, 387) → **433 (428, 386)** | 539 → 542 | 1440 → 1440 |
| TT max | 535 (526, 440) → 527 (520, 438) | 626 → 630 | 1440 → 1440 |
| FF min/nom/max | 166/242/309 → 163/242/306 | 408/539/626 → 413/542/631 | 1239/1323/1389 → 1238/1322/1391 |
| SS min | 1153 → 1143 | 409 → 413 | 1440 → 1440 |
| SS nom | 1481 → 1463 | 541 → 545 | 1440 → 1440 |
| SS max | 1673 → 1665 | 627 → 631 | 1440 → 1440 |

- SRAM khác (ngoài dout cap và addr/wmask slew), chân row/AXI và I/O: 0 ở mọi corner.
- TT nom, so từng net: 5 net cell chỉ có ở ip_v3r, 3 net chỉ có ở bản ECO (`net20423`, `r_output_mem_write_data[429]`, `r_output_mem_write_data[979]`). Danh sách đầy đủ ở `sta6b/*_tt_nom.drv_cell_nets.txt`.
- Số SRAM dout cap tăng 3–5 net, do diode mới gắn vào net dout làm tăng tải.

## Thời gian, RAM, ổ đĩa (lần này)
- 6a đổi cỡ: 1027 s, RAM đỉnh 10,2 GB.
- 6a buffer: 1089 s, 10,2 GB; đo timing trước/sau: khoảng 140 s.
- ARC: 134 s. RCX + STA OL1: 858 s. 18 lần STA/DRV: 1117 s, 4,3 GB.
- Ổ còn **16 186 MiB**; `~/ip_eco_probe` 39 GB, chủ yếu là các run OL1 trong `s5`: eco_r3 9,4 GB, eco_r3_lvs 4,7 GB, eco_r3_arc 2,1 GB, cùng eco_r4_arc, eco_r5_arc, eco_r5_sta. Không có container nào chạy.

---

# Lần 8: bước 6 (ECO DRV, hold, antenna, kiểm cuối). DỪNG giữa mục 4: ổ còn 8 GB

## Bước 0: dọn ổ
- Xoá `eco_r3_arc`, `eco_r4_arc`, `eco_r5_arc` (được phép): 16 434 → 22 793 MiB.
- Chép log và báo cáo của run Magic/LVS lượt 3 (`eco_r3`, `eco_r3_lvs`) sang `keep/` (3,6 MB) rồi xoá hai run: 22 102 → 36 450 MiB.
- **Tôi tự xoá thêm, chưa hỏi trước** (đều là file trung gian của chính đêm nay và sinh lại được; log và báo cáo đã chép sang `keep/`):
  - các run OL1 `eco_r5_sta`, `c1_sta`, `c2_sta` (để không chạm ngưỡng 10 GB khi đang chạy lượt sau);
  - trước mục 4, các run `c3_sta`, `h1_sta`, file `s6a/r4.odb`, file `s6a/r5.odb` (vốn không đọc được), các DEF, guide và file so sánh của lượt c1, c2, c3, a1.
  - Nhờ vậy ổ lên 34 821 MiB (≥ 30 GB) trước mục 4.

## Mục 1: ECO DRV (3 lượt)
Cách làm:
- Lập kế hoạch (`scripts/drv_plan.tcl`, OpenROAD của OL1): xét ở SS RC max với SPEF thật, lib std ss, macro lib TT, SDC đã bỏ `set_max_transition`/`fanout`.
- Thử đổi cỡ ngay trong STA bằng `replace_cell`: đạt khi mọi chân của net có slew ≤ giới hạn/1,2 và tải ở driver ≤ giới hạn cap/1,2. Chọn cỡ nhỏ nhất đạt.
- Không đạt thì chèn buffer ở driver: cỡ chọn theo bảng lib SS (`scripts/drv_pick.py`), slew ở sink sau = √(slew buffer² + phần do dây²), phần do dây đo từ hiện trạng. Không có cỡ đạt thì đánh dấu NOBUF ("một buffer không đủ"), chỉ báo.
- Áp (`scripts/s6c_eco.py`, dcf3613):
  - đổi cỡ: `swapMaster`;
  - buffer ở driver: đặt tại toạ độ chân driver (với SRAM là chân dout), driver chuyển sang net mới chỉ lái buffer;
  - gỡ filler ±15 µm, chỉ cell mới hoặc đổi cỡ được dời, GRT tăng dần (`allow_congestion`), DRT, `filler_placement` (OL1), global connect (OL1).
- Guide của từng lượt dựng lại từ DEF. Đã thêm bước nối các mảnh chỉ liền nhau qua hình li1 của chân cell (2–13 chỗ mỗi lượt). Mỗi lượt kiểm: guide liền mạch, mọi chân nằm trong guide.

| | Lượt 1 | Lượt 2 | Lượt 3 |
|---|---|---|---|
| Net xét | 2296 | 193 | 97 |
| Đổi cỡ | 741 | 42 | 2 |
| Buffer ở driver (cell) | 830 (buf_2 277, buf_4 496, buf_6 57) | 32 | 3 |
| Buffer ở SRAM dout | 631 (buf_1 617, buf_2 14) | 28 | 1 |
| NOBUF (chỉ báo) | 88 | 85 | 85 |
| Net clock bỏ qua | 6 | 6 | 6 |
| Filler gỡ | 48 982 | 5 578 | 433 |
| Net bị route lại | 4776 (3,26 %) | 296 (0,20 %) | 15 (0,01 %) |
| DRT (lượt DR đầu → cuối) | 3267 → 0 | 1 → 0 | 6 → 0 |
| Thời gian / RAM đỉnh (ECO) | 1305 s / 10,2 GB | 1134 s / 10,2 GB | 1212 s / 10,2 GB |
| Ổ sau lượt (MiB) | 34 906 | 29 520 | 20 977 |

DRV (số net) và timing sau mỗi lượt; RCX và STA bằng OL1, cùng script `sta6b.tcl`:
| Corner / RC | Trước (r5) | Lượt 1 | Lượt 2 | Lượt 3 |
|---|---|---|---|---|
| Cell TT min/nom/max | 334/433/527 | 6/32/61 | 6/32/61 | 6/32/61 |
| Cell SS min/nom/max | 1143/1463/1665 | 15/72/164 | 13/53/96 | 13/53/91 |
| SRAM dout (max) | 631 | 29 | 2 | **0** |
| Setup TT nội bộ worst (RC max) | +1,022 (chạm macro) | +1,511 | +1,512 | +1,511 |
| Setup SS cell→cell (RC max) | +0,438 | +1,202 | +1,203 | +1,203 |
| Hold nội bộ âm | `csb1` −0,049 (FF max) | `csb1` −0,052 | `csb1` −0,052 | `csb1` −0,052 |

Không lượt nào chạm điều kiện dừng: route lại ≤ 5 %, DRT 0, setup TT nội bộ ≥ 0, không có hold nội bộ âm mới.

**DRV còn lại sau 3 lượt (SS RC max: 91 net)**:
- **85 net NOBUF**, dây dài với tải khoảng 0,5 pF:
  - 59 net driver đã là buf_12 (cỡ lớn nhất được phép; buf_16 thuộc DONT_USE);
  - 9 net do clkbuf lái (không phải net clock);
  - 17 net do row macro lái, phần lớn là `u_output_deskew.i_partial_sum_vector[*]`.
  - Danh sách: `s6c/nobuf.nets`. Các net này cần chia net (nhiều buffer dọc dây), **chưa làm** theo lệnh.
- **6 net clock** (`clknet_9_256/257/258/265/266/81_0_S_AXI_ACLK`): không đụng theo luật.
- Ở TT: min/nom/max = 6/32/61 net; trừ 2–5 net clock, còn lại đều thuộc NOBUF.

## Mục 2: ECO hold
- Sau mục 1, endpoint hold nội bộ âm duy nhất ở FF/SS vẫn là `_56646_/Q` → `weight_mem g_bank[0].g_lane[3]/csb1`.
- Chèn ở phía sink: `eco_drv_1525` (`dlygate4sd3_1`) rồi `eco_drv_1526` (`buf_4`) lái `csb1`; dlygate không lái thẳng chân SRAM.
  - Buffer đặt ở (970,6; 3438,08), cách chân `csb1` (959,4–960,5; 3439,4–3439,8) khoảng 10 µm, vì halo của macro là 5 µm. Dlygate nằm ngay hàng trên.
  - 1 net cũ cộng 2 net mới, DRT 0, 1087 s.

| `csb1` | Hold trước → sau | Setup trước → sau |
|---|---|---|
| FF RC min | +0,161 → +0,624 | 18,48 → 17,99 |
| FF RC max | **−0,052 → +0,432** | 18,60 → 18,10 |
| TT nom | +0,418 → +1,127 | 17,83 → 17,09 |
| SS nom | +1,535 → +2,838 | 15,90 → 14,33 |

- Toàn thiết kế: mọi endpoint hold nội bộ **≥ +0,05 ns** ở FF (min/nom/max) và SS. Worst nội bộ ở FF RC max là +0,078 (chạm macro); cell→cell +0,128.

## Mục 3: antenna
- Các net mới ở mục 1–2 sinh 111 net vi phạm antenna (ARC OL1: 127 chân). Chạy vòng 4c (`s4c_round.py`, ±15 µm):
  - Vòng 1: 133 net đích, 251 diode, gỡ 31 978 filler, route lại 233 net, 111 → 2 net, DRT 0, 1152 s. 6 net không sửa được bằng diode (`s6c/a1.nofix.tsv`); không net nào trong số đó còn vi phạm sau đó.
  - Vòng 2: 2 diode, route lại 3 net, 2 → **0**, DRT 0, 1103 s.
- **ARC (OL1, run cuối): 0.**

## Tổng thay đổi
- So với r5 (đầu bước 6): **5019 net bị route lại (3,43 %)**; thêm 1526 buffer (buf_1 646, buf_2 321, buf_4 502, buf_6 57), 1 dlygate, 253 diode; 780 cell đổi cỡ (ngoài filler, không cell nào khác bị dời).
- So với DEF vòng 1 của ip_v3r: 5805 net bị route lại (3,97 %).

## Mục 4: kiểm cuối. DỪNG vì ổ còn 8 GB
Run `s5/final_a2` (OL1; `a2.def`; nhập, ARC, RCX, STA, Magic, SPICE, LVS):
- **ARC: 0.** DRT (dcf3613, `s6c/a2.drt.drc`): **0**.
- RCX (min/nom/max) và STA multi-corner của OL1: **xong** (log ở `s5/final_a2/logs/signoff`).
- **Magic DRC (view đầy đủ cell chuẩn): COUNT 0.**
- **Watcher dừng run lúc đang xuất SPICE cho LVS (05:14), vì ổ còn 8 GB < 10 GB.**
- Nguyên nhân hết chỗ: run cuối chiếm 13 GB, cộng **hai file `~/.cache/vscode-cpptools/*/.browse.VC.db` (6,7 GB mỗi file) do VS Code ghi lúc 03:41 và 04:00**. Đây là cache chỉ mục C/C++ của ứng dụng trên máy, nằm ngoài phạm vi probe; tôi không đụng. Có thể nó đang đánh chỉ mục mã nguồn OpenROAD trong `~/ip_eco_probe/src`.
- **Chưa chạy:** `magic_macro_check.sh`, `spot_check.sh`, LVS, phân tích STA và DRV theo loại path bằng `sta6b`, ip-gls 3 kích thước, công suất 50 MHz.

## Việc cần anh quyết
1. Dọn chỗ để làm nốt mục 4 (cần khoảng 15 GB nữa cho SPICE, LVS, gls và công suất). Có thể chọn một hoặc nhiều cách:
   - cho tôi xoá `~/.cache/vscode-cpptools` (13 GB, VS Code sẽ dựng lại) hoặc loại `~/ip_eco_probe` khỏi workspace của VS Code;
   - xoá `~/ip_eco_probe/src` (mã nguồn OpenROAD và LibreLane, 185 MB, có thể là thứ VS Code đang đánh chỉ mục);
   - xoá `s5/final_a2/results/signoff` (3,1 GB, chỉ là bản sao của GDS và mag trong `results/final`).
2. 85 net NOBUF cần chia dây (nhiều buffer). Có làm ở bước sau không, và chọn cách nào.

# Lần 9: phân tích 85 net dài và clock (chỉ đọc)
- `estimate_parasitics -global_routing` crash trên route nạp từ guide, kể cả khi có `set_layer_rc` (con trỏ lớp rỗng trong `layerRC`). Nguồn parasitics `detailed_routing` của dcf36133 là TODO. Cách đi được: xoá dây các net cần sửa trong bộ nhớ rồi GRT mới.
- Tỉ số điện dung RCX (max) / GRT trên 85 net: 1,539–2,712, trung vị 2,050 (`s7/cap_rcx.tsv`, `s7/cap_grt.tsv`); margin 66,5 %.
- Slew chân clock SRAM trên a2: TT nom trung vị 0,348, max 3,825 ns, 43/160 chân > 0,75 ns (21 net); SS max trung vị 0,538, max 5,686 ns (`s7/sram_clk_{tt_nom,ss_max}.tsv`). Lib SRAM chỉ đặc tính slew 1,25–40 ps.

# Giai đoạn 7
Tự kiểm theo a–e (chưa có subagent gemm-signoff-reviewer). Mọi đường dẫn tương đối với `~/ip_eco_probe`.

## Bước A: 85 net dài. ĐẠT sau 2 lượt
**Sửa trong cách thử** (`scripts/s7_long_try.py`):
- Bỏ dont_touch cho driver và sink của các net trong danh sách; mọi net và instance khác vẫn dont_touch.
- Thêm `scripts/layer_rc.tcl` (`set_layer_rc` từ tech LEF). Không có nó, `repair_design` tính R dây trên route GRT bằng 0 (`r_wire=0 ... wire_res=0` trong `s7/dbg.log` khi bật debug RSZ repair_net) và chỉ chèn 3 buffer. Tỉ số điện dung RCX/GRT đo lại khi có layer RC không đổi (`s7/cap_grt.tsv` so với `s7/cap_grt.nolayerrc.tsv`).
- Cell hold (dlygate, clkdlybuf) bị khoá; nếu driver của net là cell hold thì chèn trước một buf_4 sát chân ra. Lý do: ở lượt 2, bản đầu đổi 3 `dlygate4sd3_1` thành `buf_4`, làm mất trễ sửa hold.
- Áp vào layout: `scripts/s7_apply.py` phát lại topology (`*.topo.tsv`: cell mới, danh sách chân đầy đủ của mỗi net được sửa), rồi chạy quy trình đặt cell như 6c.

**Lượt 1** (a2 → `s7A/l1.def`, margin 66,5 %):
- Trong bộ nhớ (`s7/A1try.log`): 78 net vượt mức có margin; `repair_design` chèn 132 buffer và đổi cỡ 23 cell. Trong 23 cell đó có 17 buffer hàng (buf_4 → buf_8) và 6 driver clkbuf_16 → buf_8. Sau đó 0 net vượt theo ước lượng. Sink không cell nào bị đổi (`s7/A1try.oldchg.tsv`).
- Vị trí buffer so với dây thật trong a2 (`s7A/A1.bufdist.tsv`): trung vị 10,6 µm, p90 99,6 µm, max 758 µm. Buffer xa là do GRT mới chọn đường khác với dây cũ; các net này đều được route lại.
- Áp: 149 cell mới (105 buf_12, 23 buf_8, 12 buf_6, 4 clkbuf_8, 3 buf_1, 2 buf_4), đổi cỡ 6 cell; ±15 µm; DRT 0 (`s7A/l1.drt.drc`).
- `scripts/netdiff.py`: PASS. 0 cell cũ bị dời, 78 net cũ được tách bằng buffer, tập sink sau cây buffer đúng bằng tập sink cũ, không chân nào nằm trên hai net (`s7A/l1.cells.tsv`, `s7A/l1.nets.tsv`).
- Route lại 230 net cũ cộng 149 net mới (0,26 %). Không còn chân nguồn nào hở. Antenna (dcf3613): 8 net.
- STA (`sta6b/l1_*`): DRV cell chuẩn ở SS max 91 → 22. Còn 6 net clock, 7/85 net dài, và 9 net sát giới hạn (slack −0,00 đến −0,03).

**Lượt 2** (l1 → `s7A/l2.def`, 16 net còn vượt):
- Hiệu chỉnh lại trên chính 16 net, dùng RCX của OL1 so với ước lượng GRT ở SS max (`s7A/r2.rcx_ss_max.tsv`, `s7A/r2dry.before.ratio.tsv`): slew lệch tới ×4,42, tải tới ×2,71.
  - slew_margin = 1 − 1/(4,42 × 1,1) = **79,4 %**; cap_margin 66,5 %. Cả hai đều chặt hơn lượt 1.
- Trong bộ nhớ: 21 buffer, 3 buf_4 sau cell hold, đổi cỡ 5 cell (2 xnor2_2 → xnor2_4, 2 clkbuf_2 → buf_6, 1 clkbuf_16 → buf_8); 0 net vượt theo ước lượng.
- Áp: ±15 µm lỗi DPL-0036 với `wire39`; ±30 µm chạy được. DRT 0.
- `netdiff.py` PASS: 24 cell mới, 5 cell đổi cỡ, 14 net tách, 0 cell cũ bị dời. Route lại 60 net (0,04 %).

**Kết quả trên l2** (RCX của OL1; `s7A/l2.check.log`, `sta6b/l2_*`):

| | TT min/nom/max | SS min/nom/max |
|---|---|---|
| DRV cell chuẩn (số net) | 2 / 2 / 5 | 2 / 2 / 6 |

- Các net còn vượt chỉ là **6 net clock** (`clknet_9_{256,257,258,265,266,81}`). 85 net dài: **0**.
- Setup TT nội bộ ≥ +1,508 ns. Hold nội bộ: FF ≥ +0,068 (RC max, chạm macro), SS ≥ +0,219 ns.
- I/O, chỉ báo: hold FF RC min −0,075 (1 endpoint).
- FF RC max còn 1 net SRAM dout vượt tải, có từ trước; FF không thuộc tiêu chí DRV.
- ARC (OL1): 15 chân, sẽ xử lý ở bước D.

## Bước B: clock. ĐANG LÀM (tạm dừng vì hết lượt dùng)
- Đã dump slew mọi chân trên 4258 net clock của l2, ở TT nom và SS max, bằng SPEF của OL1 (`scripts/clk_scope.tcl` → `s7B/l2_{tt_nom,ss_max}.clk.tsv`).
- Đếm thử phạm vi (chân SRAM vượt 0,75/1,0 ns, hoặc chân vượt giới hạn lib): TT 2 net, SS 6 net, hợp lại 6 net (`s7B/scope.nets`).
- **Con số này CHƯA tin được.** Trên a2 đếm được 21 net (TT) và 31 net (SS) có chân clock SRAM vượt 0,75 ns. Rất có thể với chân SRAM, cột slew từ `report_slew_limit_short` để trống nên các dòng đó bị bỏ qua. Phải đếm lại bằng `slew_max_rise/fall` như `s7/sram_clk.tcl` trước khi chốt phạm vi.
- Chưa sửa gì trên layout. Layout mới nhất: `s7A/l2.def`.

## Bước B: clock. 2 lượt; SRAM đạt; còn 2 net clock vượt 1,5 ns ở SS (chuyển sang bước E)
- **Đính chính mục trước:** số 6 net là sai, vì chân SRAM không có giới hạn slew nên cột slew bị trống. Đã thêm cột slew đo trực tiếp vào `scripts/clk_scope.tcl`. Phạm vi trên l2 (`scripts/clk_scope.py` → `s7B/scope.tsv`) là **21 net, đều ở tầng 9** (sát lá, driver clkbuf_16), dưới ngưỡng 40.
- **Mô hình** (`scripts/clk_plan.py calib`):
  - Elmore trên cây dây thật của 512 net `clknet_9_*`. R lấy từ tech LEF; C bằng LEF × KC.
  - Khớp với slew STA của SS RC max (SPEF của OL1): KC 1,50, A 3,138.
  - Trên 484 sink có slew > 0,5 ns: dự đoán/STA = 0,84–1,19, trung vị 1,00.
- **Lượt 1** (`s7B/b1`):
  - Kế hoạch: mỗi nhóm sink được cắt ra khi slew dự đoán vượt mục tiêu (SS: SRAM 0,8 ns, còn lại 1,2 ns, tải × 1,2). Clkbuf đặt ở điểm rẽ trên dây thật; cạnh dài được cắt mỗi 50 µm.
  - Kết quả: 18 clkbuf_16 trên 17 net; gỡ 188 diode trên 21 net.
  - Legalize dời buffer trung vị 0,9 µm, max 8,5 µm. DRT 0. `netdiff.py` PASS.
- **Lượt 2** (`s7B/b2`): 14 chân clock SRAM còn vượt, mỗi chân được chèn một clkbuf_4 sát chân (SINKBUF, `s6c_eco.py`). DRT 0, `netdiff.py` PASS.
- **Slew chân clock SRAM**, l2 → b2 (`s7B/{l2,b2}_{tt_nom,ss_max}.clk.tsv`):

| | trung vị | p95 | max | số chân vượt |
|---|---|---|---|---|
| TT nom | 0,338 → 0,247 | 1,667 → 0,634 | 2,908 → **0,727** | 37 → **0** (> 0,75) |
| SS max | 0,521 → 0,398 | 2,229 → 0,919 | 3,941 → **0,996** | 47 → **0** (> 1,0) |

- **Slew CLK của flop:** TT trung vị 0,050, p95 0,082, max 2,003 → 1,205. SS max 2,740 → 1,655; các flop vượt nằm trên `clknet_9_290`/`320`.
- **Độ trễ clock** (`scripts/clk_compare.py`):
  - TT nom: min 4,446 → 4,447, trung vị 5,518 → 5,520, max 6,676 → 6,330; chênh lệch toàn chip 2,230 → **1,883 ns**.
  - SS max: max 11,560 → 11,166; chênh lệch 3,633 → **3,236 ns**.
  - Latency chân SRAM dời từ −0,342 đến +0,165 ns ở TT (67 chân), và từ −0,497 đến +0,406 ns ở SS.
- **STA b2** (`sta6b/b2_*`):
  - Setup TT nội bộ ≥ +1,335 ns.
  - DRV cell chuẩn: TT 0/0/0; SS 0/0/3. Ba net ở SS max là `clknet_9_290`, `clknet_9_320` và `net3585`.
  - Chân `u_axi_shell/S_AXI_ACLK` có slew 2,25 ns ở SS.
  - Hold FF chạm macro: −0,078 / −0,162 / −0,321 ns (RC min/nom/max); xử lý ở bước C.
- ARC: 42 chân, xử lý ở bước D.

## Bước C: hold (1 lượt, `s7C/c1`)
- 5 endpoint nội bộ dưới +0,05 ns trên b2 (`sta6b/b2_ff_*.hold.tsv`):
  - `u_axi_shell/i_weight_ready`: −0,321 ns (FF RC max);
  - `u_axi_shell/i_feature_ready`: −0,022;
  - `weight_mem g_bank[1].g_lane[1]/addr0[8]`: −0,020;
  - `weight_mem g_bank[0].g_lane[2]/csb1`: +0,010;
  - `accum_mem g_bank[0].g_lane[6]/din0[2]`: +0,041.
- Setup trước khi sửa (TT RC max): 3,64 / 4,76 / 15,91 / 9,22 / 3,16 ns.
- Mỗi chân được chèn SINKBUF `dlygate4sd3_1 + buf_4` (dlygate không lái thẳng chân macro). DRT 0. `netdiff.py` PASS: thêm 5 dlygate và 5 buf_4.
- Slack sau khi sửa: đo ở bước E.

## Bước D: antenna (`s7D/a1`, `s7D/a2`)
- **Lỗi gặp phải:** lượt 1 segfault trong `repair_antennas` (`setDiodeLoc` → `dbInst::getBBox`).
  - Nguyên nhân, đọc từ `srcfiles/RepairAntennas.cpp` của dcf3613: diode mới được đặt tên `ANTENNA_<i>`, bắt đầu từ chỉ số trống đầu tiên rồi tăng dần mà không bỏ qua tên đã có. Bước B xoá 188 diode nên để lại các khoảng trống; khi tên mới trùng tên cũ, `dbInst::create` trả về null.
  - Cách sửa trong `s4c_round.py`: tạm đổi tên diode cũ trong lúc chạy `repair_antennas`, đánh số diode mới tiếp sau chỉ số lớn nhất, rồi trả tên cũ. Tên diode cũ được giữ nguyên.
- **Lượt 1:** 27 net (31 net đích, 3 net không sửa được bằng diode: `s7D/a1.nofix.tsv`); thêm 121 diode; DRT 0; còn 2 net.
- **Lượt 2:** thêm 2 diode; DRT 0; còn **0 net** (dcf3613). `netdiff.py` PASS cả hai lượt (chỉ thêm diode).

## Bước E: kiểm gộp. DỪNG: còn 1 net clock vượt DRV ở SS max sau lượt bù
**Lần kiểm 1** (`s7D/a2.def` → `s5/e1_sta`, `sta6b/e1_*`, `s7E/e1_*.clk.tsv`):
- ARC 0. Hold nội bộ đều ≥ +0,05 ns (bước C đạt). Setup TT nội bộ ≥ +1,429 ns.
- DRV cell chuẩn: TT 0/0/1, SS 0/0/3.
  - `clknet_9_320`: 8 sink ở 1,55–1,74 ns.
  - `net3585`, `net6617`: slack −0,00 đến −0,01.
- Một chân clock SRAM vượt (`eco_clk_3_net`: TT 0,765, SS 1,123 ns).

**Lượt ECO bù duy nhất** (`s7E/e2`):
- Clock (`clk_plan.py`, giữ diode, mục tiêu SS 0,65/1,0 ns): 2 clkbuf_16 (`eco_clk_18` trên 320, `eco_clk_19` trên `eco_clk_3_net`).
- Dữ liệu (`repair_design`, slew 79,4 % / cap 66,5 %): 1 buf_12, 1 buf_8, đổi cỡ 1 cell clkbuf_2 → buf_6.
- DRT 0. `netdiff.py` PASS.
- Vòng antenna (`s7E/a3`): thêm 2 diode, còn 0 net, DRT 0, PASS.

**Lần kiểm 2** (`s7E/a3.def` → `sta6b/e3_*`, `s7E/e3_*.clk.tsv`, `s7E/e3.check.log.runjob`):

| Tiêu chí | Kết quả |
|---|---|
| ARC (OL1) | **0** |
| DRT | 0 |
| Setup TT nội bộ (min/nom/max) | cell→cell ≥ +11,235; chạm macro ≥ +1,428 ns |
| Hold nội bộ FF (min/nom/max) | ≥ +0,126 cell→cell; ≥ +0,058 chạm macro |
| Hold nội bộ SS / TT | ≥ +0,231 / ≥ +0,319 ns |
| DRV cell chuẩn TT (min/nom/max) | 0 / 0 / 0 |
| DRV cell chuẩn SS (min/nom/max) | 0 / 0 / **1** (`eco_clk_18_net`) |
| Slew chân clock SRAM TT nom | trung vị 0,248, p95 0,637, max **0,739**; vượt 0,75: 0 |
| Slew chân clock SRAM SS max | trung vị 0,398, p95 0,926, max **0,998**; vượt 1,0: 0 |
| Slew CLK flop | TT max 1,054; SS max 1,463 ns |

- **Còn sót:** `eco_clk_18_net` (buffer mới trên nhánh của `clknet_9_320`, dây 2,3 mm), ở SS max:
  - `eco_drv_1528/A` 1,69 ns (clkbuf_4 sát chân SRAM, chèn ở bước B);
  - `clkbuf_leaf_462/A` 1,58 ns;
  - `clkbuf_leaf_463/A` 1,54 ns.
  - Chân `u_axi_shell/S_AXI_ACLK` 2,19 ns: lib của AXI shell không đặt giới hạn slew cho chân này, nên chỉ báo.
  - Nguyên nhân: cây dây đọc từ DEF của net 320 không nối được 2 chân, nên vùng của `eco_clk_18` vẫn ôm 4 sink ở xa nhau trên dây 2,3 mm.
- **I/O, chỉ báo:** hold TT RC max −0,094 ns (2 endpoint, trước đó dương); setup SS RC max −0,311 ns (1 endpoint).
- **Độ trễ clock**, l2 → e3 (`scripts/clk_compare.py s7B/l2_* s7E/e3_*`):
  - TT nom: max 6,676 → 6,471 ns; chênh lệch 2,230 → 2,025 ns.
  - SS max: max 11,560 → 11,390 ns; chênh lệch 3,633 → 3,462 ns.
  - Latency chân SRAM dời từ −0,337 đến +0,816 ns ở TT (85 chân), và từ −0,497 đến +1,496 ns ở SS. Phần tăng lớn nhất là do thêm một tầng buffer ở `eco_clk_19`.
- Đã dùng hết lượt ECO bù của bước E, nên theo luật dừng ở đây, chưa sang bước F.
- Ổ còn khoảng 23 GB; bước F cần ≥ 30 GB.

## Giai đoạn 8 — Bước E' (làm nốt E)

### 1. Sửa bộ đọc dây (`scripts/clk_plan.py`)
- Nguyên nhân 2 chân của `clknet_9_320` lạc khỏi đồ thị (`s7E/n320.graph.tsv`, trên `s7D/a2.def`):
  - router đặt 2 via mcon (`L1M1_PR_MR` tại (1011,310; 5921,950) và (1011,310; 5922,630) µm) lên cùng hình chân li1 của `ANTENNA_35941/DIODE`;
  - router dùng chính chân đó làm dây nối giữa hai via;
  - bộ đọc cũ không coi hình chân là vật dẫn, nên nhánh met1 tới `_37104_/CLK` bị tách khỏi phần còn lại.
- Cách sửa: trong `build()`, các node nằm trong hình chân trên lớp của chân được nối với nhau bằng R và C của lớp đó (`PINWIRE=0` để quay về cách đọc cũ).
- Lỗi thứ hai tìm thấy khi dựng lại mô hình:
  - `pin_cap` không đọc lib của macro, nên `u_axi_shell/S_AXI_ACLK` bị tính 0,002 pF thay vì 0,3103 pF (`lib/GemmAxiShell.lib`);
  - vì vậy dự đoán slew của `eco_clk_18_net` chỉ 1,05 ns, trong khi STA đo 2,19 ns;
  - đã thêm đọc điện dung chân từ lib của GemmAxiShell và ProcessingElementRow; dự đoán mới là 2,83 ns (cao hơn STA, nghiêng về phía an toàn).
- `S_AXI_ACLK` được xếp cùng nhóm với chân clock SRAM: mục tiêu 1,0 ns ở SS, mô hình dùng 0,8 ns. `clk_scope.py` cũng kiểm chân này (0,75 TT / 1,0 SS).

### 2. Kiểm đồ thị (trên `s7E/a3.def`, chân từ `s7E/pinsE.tsv`)
- Phạm vi:
  - mọi net clock (`clknet_*`, `eco_clk_*`, `eco_drv_*`);
  - các net đã sửa ở A–E (`*.nets.tsv`, các hàng NET trong topology, `s7/long85.nets`, quy về tên net trong DEF);
  - tổng 6651 net.
- Bộ đọc mới: 0 net lệch (`s7E/gNew.graph.tsv`; số chân trên đồ thị bằng số chân của net ở mọi dòng).
- Bộ đọc cũ (`PINWIRE=0`): 192 net lệch, trong đó 26 net clock (`s7E/gOld.graph.tsv`). Hầu hết là chân diode và chân CLK nối qua hình chân li1.
  - Ảnh hưởng: kế hoạch clock ở B và E đã dựng trên đồ thị thiếu nhánh của các net này. Mọi kết quả đã được STA trên SPEF của OL1 kiểm lại, nên số đo không bị ảnh hưởng.

### 3. `eco_drv_1528`
- `sky130_fd_sc_hd__clkbuf_4` (`s7E/a3.def`), chèn ở bước B lượt 2 kiểu SINKBUF (`s7B/b2.applied.tsv`).
- Nằm trên đường clock: lái `g_bank[0].g_lane[7].u_macro/clk1` của `u_weight_tile_mem`.
- Đã thuộc họ clkbuf, không phải thay.

### 4. ECO clock lượt 1/2 — f1
- Kế hoạch (`s7E/f1.plan.tsv`, `s7E/f1.topo.tsv`):
  - 1 `clkbuf_16` `eco_clk_20` đặt ở (551,0; 6044,7) µm, trên đoạn dây dài dẫn tới `u_axi_shell/S_AXI_ACLK`;
  - nhóm sink ở x ≈ 930–1000 µm vẫn do `eco_clk_18` lái (dự đoán xấu nhất 0,76 ns);
  - không cần thêm clkbuf sát sink.
- Vị trí cách SRAM gần nhất (`u_weight_tile_mem g_bank[0].g_lane[7]`) 16,8 µm; đưa vào danh sách spot_check ở F.
- Áp vào layout (`s7E/f1.log`):
  - gỡ 118 spacer; route lại 3 net (<5 %);
  - DRT 0; ô trống 0; chân nguồn chưa nối 0.
- `netdiff` (`s7E/f1`): PASS. Thêm 1 clkbuf_16, dời 0 cell, 2 net đổi tập chân.

### 5. Vòng antenna 2/3 (giới hạn 3)
- f1: ARC (OL1) = 1 chân, `clkbuf_leaf_463_S_AXI_ACLK/A`, tỉ số 1,88 trên met1 (`keep/f1_sta/reports/signoff/1-antenna_violators.rpt`).
- a4 (`s7E/a4.WIN15.log`): +1 diode, DRT 0, `netdiff` PASS. ARC = 1 chân, `_37096_/CLK`, tỉ số 1,03 trên met1 (`keep/a4_sta/reports/signoff/1-antenna_violators.rpt`).
- a5 (`s7E/a5.WIN15.log`): +1 diode, DRT 0, `netdiff` PASS (`s7E/a5`). **ARC = 0** (`s7E/a5.check.log.runjob`).

### 6. Kiểm gộp trên `s7E/a5.def` (RCX bằng OL1; nguồn `s7E/a5.check.log.runjob`, `sta6b/a5_*`, `s7E/a5_*.clk.tsv`)
- Setup TT nội bộ ≥ +1,428 ns (macro, RC max); cell→cell ≥ +11,235 ns.
- Hold nội bộ:

  | Corner | Hold nhỏ nhất (ns) | Path |
  |---|---|---|
  | FF | +0,126 | cell→cell, RC max |
  | FF | +0,148 | macro, RC max |
  | TT | ≥ +0,319 | |
  | SS | ≥ +0,231 | |

  Không cần ECO hold.
- DRV cell chuẩn: 0 ở cả 9 corner.
  - Còn 1 net dout SRAM vượt cap ở FF max. Lỗi này đã có từ e3 và không nằm trong tiêu chí (TT/SS, cell chuẩn).
- Clock:
  - `S_AXI_ACLK`: TT 0,469 ns, SS 0,673 ns (e3: 1,637 / 2,187);
  - chân clock SRAM: TT max 0,739, SS max 0,998 ns;
  - không net clock nào vượt.
- I/O (chỉ báo):
  - hold SS âm ở 607/905 endpoint, tệ nhất −4,041 ns (SS max). Mức này đã có từ e3 (−3,904);
  - setup SS max −0,431 ns (1 endpoint).
- Lần dùng: ECO clock 1/2, ECO hold 0/1, vòng antenna 2/3.
- Dọn ổ:
  - đã chép log và report sang `keep/{e3,f1,a4,a5}_sta`;
  - đã xoá `s5/*_sta`, `s7E/f1.def`, `s7E/a4.def`, `s7D/a2.def`, các file `*.ant.rpt`, `sta6b/{a4,f1}_*`;
  - ổ còn 32 GB.
- Tự kiểm: chưa có subagent gemm-signoff-reviewer.
- E' đạt. Sang bước F với `s7E/a5.def`.

## Giai đoạn 8 — Bước F (kiểm cuối, GDSII) — ĐẠT
Layout cuối: `s7E/a5.def`. Run OL1 `s5/final_a5` (chế độ `final`: nhập DEF, ARC, RCX, STA, Magic GDS và DRC, SPICE, LVS, KLayout). Wall 16 148 s (4,5 giờ); log ở `sF/final.log`. Ổ còn 33 GB trước khi chạy.

| Mục | Kết quả | Nguồn |
|---|---|---|
| GDS (Magic) | 743 143 076 B, sha256 `87286b9408d1a706d1f47a2925317ed5ed702c0700b780edbdda0a22e8b068fa` | `s5/final_a5/results/final/gds/GEMM_top.gds` |
| Cell trong GDS | top `GEMM_top`; 382 cell; 0 cell rỗng; SRAM 80 bản (23 028 hình), row 32 bản (887 928 hình), AXI shell 1 bản (375 820 hình) | `scripts/gds_cells.py` |
| Magic DRC (cell chuẩn view đầy đủ) | COUNT 0 | `s5/final_a5/reports/signoff/drc.rpt` |
| `magic_macro_check.sh` | PASS | `s5/final_a5/reports/signoff/magic_macro_check.rpt`, `sF/mmc.log` |
| `spot_check.sh` (33 cửa sổ) | 0 lỗi thật; chi tiết ở dưới | `sF/spot_check.rpt`, `sF/spot_classify.txt`, `sF/spot_big.rpt` |
| LVS (netgen) | Circuits match uniquely; 122 879 thiết bị và 151 960 net ở cả hai phía | `s5/final_a5/logs/signoff/14-lvs.lef.log` |
| KLayout XOR | 0 khác biệt trên 52/52 lớp (81/14 bỏ qua như flow) | `s5/final_a5/logs/signoff/16-xor.log`, `sF/xor2.log`, `sF/xor3.rpt` |
| ARC (OL1) | 0 | `sF/final.log` |
| DRT | 0 | `s7E/a5.WIN15.log` |
| STA 9 corner | đạt mọi tiêu chí; xem dưới | `sF/f7.log`, `sta6b/final_*` |
| ip-gls 3 kích thước | PASS; 258/274/34 sự kiện, trùng từng chu kỳ với RTL lean_cg và GLS ip_v3r | `sF/gls.out`, `sF/gls_*/cycles_gls.txt` |
| Công suất 50 MHz (vectorless) | 1377,62 mW | `s5/final_a5/reports/power/vectorless.groups.txt` |
| Mô hình timing | `GEMM_top.lib` (TT, SPEF nom, propagated clock) | `s5/final_a5/results/final/lib/GEMM_top.lib` |

### Spot check (`scripts/spot_check.sh`)
- Cửa sổ:
  - 30 mẫu ngẫu nhiên (seed 1) trong 1980/2968 cell mới (so với DEF vòng 1) cách macro dưới 20 µm, mở rộng ±5 µm (`sF/spot_windows.txt`);
  - `eco_clk_20`;
  - 2 chỗ đã ghi từ trước.
- Lỗi chạm dải 0,5 µm sát mép cắt được tính là hình bị cắt, như cách `magic_macro_check` dùng (`scripts/spot_classify.py`; báo cáo chỉ in 50 hộp mỗi cửa sổ, nên đã phân loại từ `magic.log`).
- Còn 153 hộp bên trong 3 cửa sổ (`ANTENNA_34844`, `ANTENNA_36000`, `eco_drv_311`):
  - 152 hộp LU.2/LU.3 (khoảng cách diff tới tap) và 1 hộp met4.4a;
  - chạy lại 3 cửa sổ này, mỗi cạnh nới thêm 30 µm: vùng gốc còn **0 lỗi** (`sF/spot_big.rpt`).
- Ở phần nới thêm có 4 hộp nwell.5a. Cả 4 nằm trong SRAM, chạy dọc mép cắt, là Deep N-well của bitcell OpenRAM bị cắt ngang.

### KLayout XOR
- Lượt 1 (trong flow, chế độ phẳng, `xor.drc` của OL1, 1 luồng):
  - 6 lớp đầu (122/16, 22/21, 22/22, 235/0, 235/4, 236/0) ra 0;
  - ở lớp 33/42 (65,1 triệu polygon phẳng mỗi bên) bị OOM killer giết (rc 137, RAM chạm 10 GiB; `sF/xor2.log`, `sF/xor2.mem`).
- Lượt 2 (`scripts/xor_tiled.drc`, chế độ tiling: ô 800 µm, viền 1 µm, RAM container 10g):
  - 46 lớp còn lại đều ra 0 (`sF/xor3.rpt`);
  - RAM đỉnh 7,97 GiB; khoảng 2,5 giờ.
- Phép đối chứng (`scripts/xor_tiled_control.drc`): XOR 68/20 với 69/20 ra 338 870, khác 0, nên chế độ tiling phát hiện được khác biệt (`sF/xorc.rpt`).
- Sửa lại một con số: trước đó tôi báo 11 lớp sạch trong lượt 1; đúng là 6 lớp.

### Timing và DRV (OpenROAD của OL1, SPEF của RCX OL1, propagated clock, SDC `in/GEMM_top.sdc`)
- Setup TT nội bộ:
  - tệ nhất +1,428 ns (macro, RC max);
  - cell→cell ≥ +11,235 ns.
- Hold nội bộ:

  | Corner | Path | Hold tệ nhất (ns) |
  |---|---|---|
  | TT | cell→cell | +0,319 |
  | TT | macro | +0,360 |
  | FF | cell→cell, RC max | +0,126 |
  | FF | macro, RC max | +0,148 |
  | SS | cell→cell | ≥ +1,110 |
  | SS | macro | ≥ +0,231 |

- Setup SS (chỉ báo): macro tệ nhất −4,944 ns (1308 endpoint, RC max).
- I/O (chỉ báo):
  - hold SS âm ở 607/905 endpoint, tệ nhất −4,041 ns;
  - setup SS max −0,431 ns (1 endpoint);
  - TT và FF: không âm.
- Endpoint không ràng buộc: 1124, giống nhau ở mọi corner và trùng hoàn toàn với ip_v3r (`sta6b/{final,v3r}_tt_nom.unconstrained.rpt`).
  - 1088 chân do `conb_1` (hằng số) lái: `i_partial_sum_vector` của row 0, `wmask`/`web`/`csb` của SRAM;
  - 36 cổng ra `result_axis_tstrb[31:0]`, `S_AXI_BRESP/RRESP` lái qua buffer đầu ra từ chân của AXI shell. Các chân này không có cung timing trong `GemmAxiShell.lib` (hằng số).
- `report_clock_skew`: `sta6b/final_*.skew.rpt`.
- 10 path tệ nhất mỗi loại: `sta6b/final_*.{setup,hold}.tsv` (đủ mọi endpoint, có cột loại).
- DRV:
  - cell chuẩn 0 ở 9/9 corner;
  - SRAM dout vượt cap 1 net ở FF max (chỉ báo);
  - slew addr/wmask SRAM 1440 net (miễn trừ đã duyệt).
- Clock (`sF/final_{tt_nom,ss_max}.clk.tsv`):
  - `S_AXI_ACLK`: 0,469 (TT nom) / 0,673 ns (SS max);
  - chân clock SRAM max: 0,739 / 0,998 ns.

### Chức năng
- ip-gls (`run_ip_gls.sh` trên `s5/final_a5`, `ip_shell5`, `row_v1`):

  | Kích thước | Kết quả | Sự kiện | Thời gian |
  |---|---|---|---|
  | 64×64×64 | PASS | 258 | 409 s |
  | 8×32×544 | PASS | 274 | 691 s |
  | 16×992×32 | PASS | 34 | 1510 s |

  RAM đỉnh 6,8 GB.
- Các sự kiện trùng từng chu kỳ với:
  - mô phỏng RTL đúng cấu hình IP (`sim/build_system_asic-sram_axileancg*`);
  - GLS ip_v3r.
- So với RTL FPGA gốc (`build_system_orig*`, AXI khác) thì lệch 1–4 chu kỳ; đó không phải mốc của IP.
- GLS có SDF: `run_ip_gls.sh` không có chế độ này, nên bỏ qua.

### Công suất 50 MHz
- Vectorless, TT: 1377,62 mW (ip_v3r: 1375,40 mW, +0,16 %).
- VCD: `tools/power.sh` chỉ hỗ trợ cho core, nên bỏ qua.

### Mô hình timing
- OL1 tự chạy `write_timing_model` trong bước signoff STA (`scripts/openroad/common/io.tcl`):
  - corner Typical (lib TT của cell chuẩn), SPEF RC nom của run cuối;
  - SDC cuối, có `set_propagated_clock`.
- Kết quả: `results/final/lib/GEMM_top.lib` (sha256 `2d9dc7a7…63932`), có 607 cặp setup/hold trên cổng vào và 298 cung clock→cổng ra.
- Không cần dùng OpenSTA của dcf36133.
- Hold I/O âm là do SDC coi clock bên ngoài là lý tưởng (độ trễ clock tới cổng bằng 0), trong khi bên trong IP có độ trễ clock 6–7 ns. Người tích hợp cần dùng `.lib` này để tính phần I/O.

### So với ip_v3r
| Mục | ip_v3r | Cuối |
|---|---|---|
| ARC (chân) | 448 | 0 |
| Magic DRC COUNT | 7 | 0 |
| LVS | khớp, 120 318 thiết bị | khớp, 122 879 thiết bị |
| Setup TT nội bộ tệ nhất (RC max) | +1,025 | +1,428 |
| Hold FF nội bộ tệ nhất (RC max) | −0,056 (1 path macro) | +0,126 |
| DRV cell chuẩn TT nom / TT max / SS max | 435 / 535 / 1673 | 0 / 0 / 0 |
| SRAM dout cap (TT nom) | 539 | 0 |
| Setup SS macro tệ nhất (RC max) | −5,416 | −4,944 |
| Hold I/O SS max | −3,044 | −4,041 |
| ip-gls | PASS 258/274/34 | PASS 258/274/34 (trùng chu kỳ) |
| Công suất vectorless | 1375,40 mW | 1377,62 mW |
| GDS | 736 913 516 B | 743 143 076 B |

- Nguồn của ip_v3r: `sta6b/v3r_*`, `runs/ip_v3r/reports/signoff/{drc.rpt,56-antenna_violators.rpt}`, `61-lvs.lef.log`, `reports/power`.
- Hold I/O ở SS tệ hơn vì clock bên trong IP được kéo trễ thêm khi sửa slew clock ở B và E'. Phần này chỉ báo; người tích hợp dùng `.lib`.
- RAM đỉnh trong F:
  - KLayout XOR phẳng: 10 GiB (OOM);
  - XOR theo ô: 7,97 GiB;
  - GLS: 6,8 GB;
  - STA: 3,3 GB.
- Ổ còn 14 GB sau F.

## Giai đoạn 8 — Bước G (bản giao, tài liệu, git) — XONG
- `~/ip_eco_probe/final/` (3,0 GB), mỗi file có sha256 trong `SHA256SUMS` (99 file):
  - GDS; DEF (`s7E/a5.def`); netlist thường (`GEMM_top.nl.v`) và netlist có chân nguồn (`GEMM_top.pnl.v`);
  - SPEF min/nom/max; SDC; LEF; `GEMM_top.tt.lib`;
  - `reports/`: DRC, macro check, spot check, LVS, ARC, XOR, STA 9 corner kèm unconstrained và skew, dump clock, GLS, công suất.
- `TOOLS.txt`:
  - OL1 1.0.2, image `sha256:832662c8…779a`: OpenROAD 41a51eaf, Magic 8.3.413, Netgen 1.5.255, KLayout 0.28.2, Yosys 0.30+48, OpenSTA 2.4.0;
  - image LibreLane `sha256:4bc9042b…5051` (OpenROAD dcf36133);
  - Icarus 13.0; open_pdks 0fe599b2.
- Worktree `eco-signoff-wip`, commit `e0ade31`, đã push (không force):
  - `tools/eco`: thêm 16 script, sửa 5 script, tất cả đã tham số hoá qua `env.sh`;
  - `tools/eco/README.md`: ghi cách lách lỗi đặt tên diode của `repair_antennas`, việc bắt buộc gọi `set_layer_rc`, và cách chạy XOR theo ô;
  - `docs/TIEN_DO_SIGNOFF.md`: "signoff xong", điền số liệu cuối, giữ nguyên phần giới hạn;
  - README và HUONGDAN: 50 MHz là "TT theo lib"; 100 MHz cũ của core_v11 thì khoảng 53 MHz ở TT khi kiểm đủ.
- Kiểm git trước khi commit: không đường dẫn cá nhân, không nhắc Claude/Anthropic/AI, không emoji, không file nào trên 5 MB, không CLAUDE.md hay file trạng thái.
- Tổng so với DEF vòng 1 của ip_v3r:
  - 6066 net có dây thay đổi (4,15 %);
  - thêm 2968 cell (1220 diode, 1742 buffer, 6 dlygate), xoá 187 diode, đổi cỡ 794 cell; không cell nào bị dời.
  - Khi so gộp từ đầu tới cuối, `netdiff` báo 3 cell đổi cỡ có chân A đổi net (`_22734_`, `_24622_`, `_31087_`). Lý do: các cell này được đổi cỡ ở bước 6, rồi ở lượt khác chân A nhận buffer phía sink (`wire59`, `load_slew49`, `wire26`). Các lượt `netdiff` riêng từng bước đều PASS.
- Sửa lại một số: ARC của ip_v3r là 446 chân khác nhau (báo cáo có 448 dòng vì có dòng trùng). Bảng ở bước F ghi 448.
- Tự kiểm: chưa có subagent gemm-signoff-reviewer.

## Báo cáo cuối Giai đoạn 8
- Thời gian (wall):

  | Bước | Nội dung | Thời gian |
  |---|---|---|
  | E' | áp f1 | 17 phút |
  | E' | 2 vòng antenna | 15 phút mỗi vòng |
  | E' | 3 lần RCX/STA/clock | khoảng 30 phút mỗi lần |
  | F | run OL1 `final` | 4,5 giờ |
  | F | XOR theo ô | khoảng 2,5 giờ |
  | F | GLS | 43 phút |
  | F | STA 9 corner | khoảng 10 phút |
  | F | spot check | khoảng 20 phút |
  | F | công suất | khoảng 10 phút |

- RAM đỉnh:
  - OpenROAD ECO: 10,3 GB (có swap);
  - KLayout XOR phẳng: 10 GiB (OOM); XOR theo ô: 7,97 GiB;
  - GLS: 6,8 GB; STA: 3,3 GB.
- Ổ: 33 GB trước F, còn 14 GB sau G.
- Miễn trừ: chỉ có miễn trừ đã duyệt, slew addr/wmask của SRAM (1440 net), vì lib SRAM chỉ đặc tính hoá tới 40 ps. Không có miễn trừ mới.

## Sau signoff: tài liệu, MANIFEST, dọn ổ
- Commit `ef4609f` (đã push `eco-signoff-wip`):
  - các con số của core_v11 (100 MHz, 57 MHz, 204,8 GOPS, 134 GOPS/W, 1,53 W) được ghi là giả định 100 MHz, chưa kiểm path qua macro;
  - antenna: core_v11 chạy riêng còn 219 chân; IP gemm_ip đã về 0 nhờ `tools/eco`;
  - số của IP ở 50 MHz: 1377,6 mW vectorless, đỉnh 102,4 GOPS; GOPS/W sẽ điền khi có công suất theo VCD;
  - setup SS chạm macro của IP: −4,94 ns, chỉ báo.
- `final/MANIFEST`: sha256 của 101 file; `SHA256SUMS` kiểm lại vẫn khớp.
- Dọn ổ (từ 14 GB lên 26 GB trống):
  - `s5/final_a5`: xoá `tmp/signoff` và các bản trùng đã kiểm bằng `cmp` (GDS và mag trong `results/signoff`, SPICE trùng `results/final/spi`, DEF và pnl trong `results/routing`); giữ log, report, `results/final`, ODB, `mca`, GDS của KLayout;
  - xoá các route guide, file `pins*.tsv`, `s4c/r3.def`, `s7E/a3.def`, và `gls.vvp` cùng các netlist chép của GLS (log và cycles vẫn giữ).
  - Không đụng `final/`, `in/`, `s7E/a5.def`, `keep/`, và run ip_v3r.

## Gói bằng chứng cho bài báo (`paper/`, commit `91dcefd` ở `docs/paper/`)
- Toàn bộ số liệu, nguồn và giới hạn ở `paper/SUMMARY.md`.
- Các job đã chạy:
  - VCD 3 kích thước, leakage 3 corner;
  - harden PE (`gemm_pe/runs/paper_pe`, 88 s);
  - mô phỏng ngẫu nhiên PE và row;
  - Yosys trên PE: BMC 20 chu kỳ đạt, k-induction không khép;
  - IR drop (PSM, RAM đỉnh 9,9 GiB);
  - ảnh KLayout và OpenROAD.
- Lỗi script đã gặp và đã sửa:
  - `/usr/bin/time` không có trong image;
  - `gui::save_image` là hàm cấp thấp, phải dùng lệnh `save_image -resolution`;
  - heatmap IRDrop không có tuỳ chọn `Net`;
  - các tuỳ chọn `-width` / `RUDY` / `Pin` không có ở bản này.
- Cài matplotlib 3.9.2 vào `paper/.venv`, vì máy và cả hai image đều không có.
- Báo cáo theo từng instance được nén gzip (2,4 GB còn 113 MB). VCD đã xoá sau khi tính.

## Gói bằng chứng, phần bổ sung (2026-10-20)
- Commit `2906d63` (nhánh eco-signoff-wip, đã push).
- **Công suất:** VCD cả job 2 cho 3 kích thước (541 / 1252 / 2510 MB, xoá sau khi tính), chia theo pha.
  - Phát hiện và sửa lỗi alias khi đọc VCD (net ở biên row/AXI mất activity). Số cửa sổ cũ chuyển sang `paper/data/superseded_alias_bug/`.
  - 64x64x64: 745,1 mW, 24,5 µJ, 93,5 pJ/MAC, 21,4 GOPS/W.
- **Hiệu năng:** chia chu kỳ theo pha; RTL `asic-sram_axileancg` cho 12 hình dạng, chạy cả testbench gốc và full-rate; roofline.
  - Giới hạn bộ đệm thật là 511 / 1023 / 511 từ.
  - M = 1 cho kết quả sai.
- **PE:** 82 flop ở cả hai bên; `equiv_induct` khi ghép thanh ghi theo tên chứng minh được (Yosys 0.62 và 0.30).
- **IR:**
  - bên trong row: 17,9 / 41,8 mV;
  - IP mô hình A (bàn cờ): 137 / 154 mV;
  - IP mô hình B (mép die): 120 / 125 mV.
  - VDD−VSS ở chỗ tệ nhất trong row có thể tới khoảng 240 mV (tức 1,56 V).

## Gói bằng chứng, đợt 3 (2026-10-20)
- Commit `0af28a9` (nhánh eco-signoff-wip, đã push).
- **Bộ đọc VCD:** `tools/power/vcd2act.py` đã sửa lỗi alias. Đo lại core_v11: 1529,70 mW, không đổi (chỉ 63 chân clkbuf bị ảnh hưởng).
- **ERRATA:**
  - E1 (dung lượng): `In_buffer.v:70-71,106,116-117`; `Out_buffer.v:52,285`.
  - E2 (M = 1): `Buffer_feeder.v:109,130`; `Gemm_compute_core.v:147`; `In_buffer.v:232-237`.
  - `sim/run_errata.sh`: 11 ca, đều đúng như mô tả; kết quả 512 từ cho ra sai, không treo.
  - GLS giống RTL ở M = 1, M = 2 và F511.
- **FPGA:** E2 cùng nguồn gốc. E1 không xảy ra vì độ sâu là 2400. Driver gửi M = 1 sang FPGA, không đệm.
- **Công suất:** chỉ clock là 711,8 mW, theo dữ liệu 33,2 mW (64³).
- **IR:** cận bi quan 1,50 V (sửa từ 1,56). Ở ss_100C_1v40, top cell→cell −7,09 ns; row vẫn đạt 62,4 MHz.
