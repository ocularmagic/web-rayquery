# web-rayquery

A personal prototype for hardware ray tracing (RT cores) on web pages: expose [wgpu](https://github.com/gfx-rs/wgpu)'s experimental ray queries to WebGPU in a locally built Firefox, behind a pref. Firefox runs WebGPU on wgpu, and wgpu already implements ray queries on DX12, Vulkan and Metal, so the work is mostly letting web pages reach them. A page would feature-detect it and fall back to a compute-shader ray tracer in normal browsers.

Background: [gpuweb#535](https://github.com/gpuweb/gpuweb/issues/535) (ray tracing in WebGPU).

## Status

| Phase | What | State |
|---|---|---|
| 0 | Check wgpu/Firefox support; run wgpu ray queries natively | Done |
| 1 | Build Firefox unmodified | Done |
| 2 | Pref-gated ray query API in Firefox (WebIDL, dom/webgpu, IPC, wgpu_bindings) | Done (Windows, DX12) |
| 3 | Test page (plain WebGPU) tracing rays vs a software result | Done |
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

## Phase 1 findings (October 2026)

- Full (non-artifact) build of Firefox `main` at `9fcf3a1690ec` (Firefox 161 Nightly) on Windows 11 with MozillaBuild 4.2.1, following the [Windows build docs](https://firefox-source-docs.mozilla.org/setup/windows_build.html). `./mach build` took 29 min on a 20-core desktop CPU, no errors.
- Bootstrap fetched Mozilla's own clang-cl, MSVC/SDK package and `dxcompiler.dll`; configure found DXC, so WebGPU is enabled.
- [`pages/webgpu-check.html`](pages/webgpu-check.html) (adapter, features, compute round trip) passes in the build. The GPU process loads `d3d12.dll` + `dxcompiler.dll` and no `vulkan-1.dll`: WebGPU runs on **DX12** by default. `adapter.info` fields are blank (Firefox hides them).
- `--setpref dom.webgpu.wgpu-backend=vulkan` does switch wgpu to Vulkan (wgpu logs `backend: Vulkan`), but the same check then fails ("Buffer unmapped") and the log shows GPU-process `AbnormalShutdown` messages. Not investigated; DX12 is the path for this prototype.
- Notes: mach limits its terminal output when it detects an AI agent (full log in `obj-*/.mozbuild/logs/build/`). Firefox prints page `console.log` to stdout with `--setpref devtools.console.stdout.content=true`, and honours `RUST_LOG` for wgpu logs.

## Phase 2: the Firefox patch (October 2026)

[`firefox-patch/webgpu-experimental-ray-query.patch`](firefox-patch/webgpu-experimental-ray-query.patch) applies to Firefox `main` at `9fcf3a1690ec`. It only touches Firefox's own code; the vendored wgpu crates are unchanged.

```
cd firefox
git apply /path/to/webgpu-experimental-ray-query.patch
./mach build
./mach run --setpref dom.webgpu.experimental-ray-query.enabled=true
```

With the pref off (the default) Firefox behaves as before: the API below is not exposed and the feature is never offered.

### JavaScript API (prototype)

```js
const adapter = await navigator.gpu.requestAdapter();
if (!adapter.features.has('experimental-ray-query')) { /* fall back to a compute-shader tracer */ }
const device = await adapter.requestDevice({ requiredFeatures: ['experimental-ray-query'] });

const vertexBuffer = device.createBuffer({ size, usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST | GPUBufferUsage.BLAS_INPUT });
const blas = device.createBlas({ geometries: [{ vertexFormat: 'float32x3', vertexCount: 3 }] }); // optional indexFormat, indexCount, opaque
const tlas = device.createTlas({ maxInstances: 1 });

const encoder = device.createCommandEncoder();
encoder.buildAccelerationStructures(
  [{ blas, geometries: [{ vertexBuffer, vertexStride: 12 }] }],     // optional firstVertex, indexBuffer, firstIndex
  [{ tlas, instances: [{ blas, customData: 7 }] }],                   // optional transform (12 numbers, row-major 3x4), mask
);
// Bind group layout entry: { binding, visibility, accelerationStructure: {} }; bind group entry: { binding, resource: tlas }
```

WGSL uses wgpu's extension: `enable wgpu_ray_query;`, `var acc: acceleration_structure;`, `ray_query`, `rayQueryInitialize`, `rayQueryProceed`, `rayQueryGetCommittedIntersection`. The names (`GPUBlas`, `GPUTlas`, `BLAS_INPUT`) follow wgpu, not any WebGPU proposal.

### How it works

- **Pref** `dom.webgpu.experimental-ray-query.enabled` (read once at startup).
- **GPU process** (`gfx/wgpu_bindings/src/server.rs`): with the pref on, wgpu's instance is created without `STRICT_WEBGPU_COMPLIANCE`, which otherwise hides the feature and zeroes the acceleration structure limits. A device that asks for the feature is created directly with wgpu-core (Firefox's wrapper always disables experimental features), with `ExperimentalFeatures::enabled()` and the adapter's acceleration structure limits. BLAS/TLAS objects live in tables next to wgpu's own, and bind groups and builds that use them are assembled from wgpu-core's public API.
- **IPC** (`lib.rs`, `client.rs`): new messages to create, build, bind and drop acceleration structures; adapters report whether ray queries are on offer.
- **DOM** (`dom/webidl/WebGPU.webidl`, `dom/webgpu/`): the API above. `GPUBufferUsage.BLAS_INPUT` (0x40000000, a bit WebGPU doesn't use) becomes wgpu's native `BufferUsages::BLAS_INPUT`, which BLAS build inputs need.

### Verified

On the RTX 5070 (Windows 11, DX12), with [`pages/rayquery-smoke.html`](pages/rayquery-smoke.html) (the Phase 0 scene, written against the JS API):

- Pref on: the adapter offers `experimental-ray-query`, and the page builds a BLAS and a TLAS, then traces 256 rays in a compute shader. 50 hits, identical to the CPU trace (0 mismatches, max hit-distance error 0) and to the native Phase 0 run. The GPU process loaded `d3d12.dll` and `dxcompiler.dll`, not Vulkan.
- Pref on: the plain [`webgpu-check.html`](pages/webgpu-check.html) still passes; the feature list gains only `experimental-ray-query`.
- Pref off: the check passes, the feature is absent, and `createBlas`/`buildAccelerationStructures` are undefined.
- Incremental rebuilds after the patch took about 7 minutes.

### Not done or not checked

- Triangle geometry only: no AABBs, transform buffers, BLAS/TLAS updates or compaction, vertex return, or `destroy()` (objects are freed when garbage-collected). Build flags are fixed (`PREFER_FAST_TRACE`, full rebuild).
- A build whose geometry count differs from the BLAS's throws a `TypeError` instead of a WebGPU validation error. An unknown BLAS/TLAS in a build is only logged in the GPU process.
- Turning the pref on drops strict WebGPU compliance for every page, not just ones using ray queries. Known effects: an adapter can create more than one device, and wgpu's extra `max_buffers_and_acceleration_structures_per_shader_stage` limit (28 by default) applies.
- Not hardened. wgpu marks ray queries as experimental, and this exposes them to web content. Keep the pref off for normal browsing.
- Not tested: the Vulkan backend (basic WebGPU already fails there, see Phase 1), Linux, macOS, workers, Firefox's own test suites or the WebGPU CTS, and performance. Rust changes were not run through rustfmt.

## Phase 3: boxes compared with software (October 2026)

[`pages/rayquery-boxes.html`](pages/rayquery-boxes.html) traces one scene three ways and compares them pixel by pixel:

1. **Hardware** ray queries through the Phase 2 API (skipped when the browser doesn't offer `experimental-ray-query`).
2. **Software on the GPU:** a plain WebGPU compute shader that tests every triangle (brute force, no acceleration structure). This is the kind of fallback a page would use in normal browsers.
3. **CPU reference** in 64-bit JavaScript.

The scene has a ground slab, 12 boxes (indexed `uint16` cube BLAS, instanced with rotations and non-uniform scales) and two "T" shapes (a second BLAS with two non-indexed geometries in one vertex buffer, the second at `firstVertex: 36`). That is 15 TLAS instances and 204 triangles. Each of the 320x200 pixels gets a primary ray and a shadow ray towards a directional light. For every pixel the page compares hit or miss, instance custom data and index, geometry index, primitive index, distance, barycentrics, front face and shadow. Rays that pass within 1e-4 (barycentric) of a triangle edge are counted separately, because rounding can legitimately change their answer.

![Hardware, software and CPU renders, and the difference map](images/rayquery-boxes.png)

*Top left: hardware ray queries. Top right: software compute shader. Bottom left: CPU reference. Bottom right: differences (all grey = every pixel agrees).*

Results in the patched Firefox on the RTX 5070 (DX12):

| | Hardware vs CPU | Software vs CPU |
|---|---|---|
| Rays (primary, plus a shadow ray per hit) | 64,000 (40,250 hits) | 64,000 (40,250 hits) |
| Mismatches | 0 | 0 |
| Edge-grazing rays that differ | 0 of 5,834 | 0 of 5,834 |
| Max hit distance error | 1.3e-5 m | 1.3e-5 m |
| Max barycentric error | 1.1e-5 | 1.3e-5 |
| Front-face disagreements | 0 | 0 |

With the pref off, the same page skips the hardware path and the software tracer still matches the CPU (0 mismatches).

### Timing (rough)

A second scene with 401 instances (4,812 triangles) at 640x400, primary plus shadow rays, measured with GPU timestamp queries (median of 5):

| | GPU time per frame |
|---|---|
| Software, brute force | 14.3 to 17.5 ms |
| Hardware ray queries | 0.030 to 0.041 ms |

Ranges cover four runs. That is roughly 350x to 580x, or 9 to 12 billion rays per second on this scene. The hardware result for this scene matched the software one except on 36 of 256,000 rays (edge cases). Caveats: brute force is a weak baseline (a software tracer with a BVH would be much faster), the scene is tiny and coherent, and timings varied run to run. Wall-clock time is no use here: in this Firefox build `onSubmittedWorkDone` resolved on a ~100 ms cycle.

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
