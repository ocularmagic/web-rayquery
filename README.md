# web-rayquery

A personal prototype for hardware ray tracing (RT cores) on web pages: expose [wgpu](https://github.com/gfx-rs/wgpu)'s experimental ray queries to WebGPU in a locally built Firefox, behind a pref. Firefox runs WebGPU on wgpu, and wgpu already implements ray queries on DX12, Vulkan and Metal, so the work is mostly letting web pages reach them. A page would feature-detect it and fall back to a compute-shader ray tracer in normal browsers.

Background: [gpuweb#535](https://github.com/gpuweb/gpuweb/issues/535) (ray tracing in WebGPU).

## Status

| Phase | What | State |
|---|---|---|
| 0 | Check wgpu/Firefox support; run wgpu ray queries natively | Done |
| 1 | Build Firefox unmodified | Not started |
| 2 | Pref-gated ray query API in Firefox (WebIDL, dom/webgpu, IPC, wgpu_bindings) | Not started |
| 3 | Test page (plain WebGPU) tracing rays vs a software result | Not started |
| 4 | Write-up | Maybe |

## Phase 0 findings (October 2026)

- wgpu 30.0.0 exposes `Features::EXPERIMENTAL_RAY_QUERY` on DX12 (raytracing tier 1.1 + SM 6.5), Vulkan (`VK_KHR_ray_query`) and Metal (macOS 15 / iOS 18). Full ray tracing pipelines are Vulkan only. Experimental features need `ExperimentalFeatures::enabled()` at device creation.
- naga translates `enable wgpu_ray_query;` to HLSL `RayQuery` (cs_6_5, DXC with `-HV 2018`), SPIR-V `SPV_KHR_ray_query`, and MSL `metal::raytracing::intersection_query` (MSL 2.4+). Examples: [`wgpu-rq-test/naga-out/`](wgpu-rq-test/naga-out/).
- Firefox main vendors wgpu 30.0.0 at commit `49325ca0`, uses DX12 on Windows by default (pref `dom.webgpu.wgpu-backend` can select `vulkan`), and ships its own `dxcompiler.dll`.
- What blocks web pages today (from reading the source; not yet patched):
  - Firefox creates its wgpu instance with `STRICT_WEBGPU_COMPLIANCE`, which hides native features and zeroes the acceleration-structure limits.
  - Device creation only passes WebGPU features and disables experimental features.
  - The content-to-GPU-process layer (`wgpu-core-remote`) has no create/build commands for acceleration structures, and its bind group layouts can't hold one.
  - No WebIDL for any of it.

## wgpu-rq-test

Rust program using wgpu at the same commit Firefox vendors. A compute shader with `enable wgpu_ray_query;` fires a 16x16 grid of rays at one triangle, reads the hits back and compares them with a CPU (Moller-Trumbore) trace.

```
cd wgpu-rq-test
cargo run -- all        # or dx12 / vulkan
```

DX12 loads `dxcompiler.dll` from `C:\VulkanSDK\1.4.357.0\Bin` if present (set `DXC_PATH` to use another).

Result on an RTX 5070 (driver 617.42, Windows 11): DX12 and Vulkan both pass, no differences from the CPU trace ([`phase0-run.txt`](wgpu-rq-test/phase0-run.txt)). Not measured: performance, or whether the driver runs these queries on the RT cores.

## License

MIT OR Apache-2.0, at your option (same as wgpu).
