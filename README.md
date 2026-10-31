# FPGT · GEMM 32×32 INT8 ASIC (SKY130) — public website

Live site (GitHub Pages): https://nguyen-ky2910.github.io/WEB_GEMM_32x32_FPGT/

Static, self-contained research showcase for the FPGT INT8 GEMM accelerator:

- **Tham khảo sản phẩm / Applications** — real-world AI application references (official sources, credited).
- **Dự án / Project** — architecture, implementation flow, verification scope and limits.
- **Layout** — interactive WebGL 3D physical-design explorer using the real GDS/DEF geometry of `GEMM_top`
  (cells, M1–M5 routing, vias, pins, DEF nets). Includes a 3D presentation mode.
- **Thông số / Specifications** — 201 source-backed parameters, searchable.

Vietnamese is the default; add `?lang=en` for English, e.g. `…/?lang=en#simulation`.

## How it works

`GEMM-32x32-ASIC.html` contains the application, the full-chip overview and all page data.
Detailed geometry is loaded on demand from `physical-data/` (17,052 compressed, versioned chunks;
only the chunks of the selected PE/window are fetched). No backend, login or installation is needed.
`index.html` forwards to the main page and keeps `?lang=` and `#tab`.

The geometry is preprocessed from the final signed-off GDS/DEF; coordinates and connectivity are
unchanged. Layer separation in the 3D view is a display effect, not to physical scale.
Third-party images/videos are displayed from their official URLs with credits and are not redistributed here.

Generated from the project workspace with `node website/build.mjs` (website/share). Not a commercial product.
