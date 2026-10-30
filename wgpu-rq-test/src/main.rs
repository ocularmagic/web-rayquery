//! Phase 0 hardware check: one triangle, a compute shader firing a grid of rays with
//! `enable wgpu_ray_query;`, read the hits back and compare with a CPU (software) result.
//!
//! Usage: wgpu-rq-test [dx12|vulkan|all]   (default: all)
//! DXC_PATH overrides the dxcompiler.dll used by the DX12 backend.

use std::mem::size_of;
use wgpu::util::DeviceExt;

const GRID: u32 = 16;
const HALF_SIZE: f32 = 1.5; // metres
const CUSTOM_DATA: u32 = 7;

// Triangle at z = 0, 2 m wide and 2 m tall.
const VERTICES: [[f32; 3]; 3] = [[-1.0, -1.0, 0.0], [1.0, -1.0, 0.0], [0.0, 1.0, 0.0]];

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct Params {
    grid: u32,
    half_size: f32,
    _pad: [u32; 2], // uniform structs are 16-byte aligned
}

#[repr(C)]
#[derive(Clone, Copy, Debug, bytemuck::Pod, bytemuck::Zeroable)]
struct Hit {
    kind: u32,
    t: f32,
    bary: [f32; 2],
    custom_data: u32,
    primitive_index: u32,
    front_face: u32,
    _pad: u32,
}

fn main() {
    env_logger::init();
    let which = std::env::args().nth(1).unwrap_or_else(|| "all".into());
    let backends: Vec<wgpu::Backends> = match which.as_str() {
        "dx12" => vec![wgpu::Backends::DX12],
        "vulkan" => vec![wgpu::Backends::VULKAN],
        "all" => vec![wgpu::Backends::DX12, wgpu::Backends::VULKAN],
        other => panic!("unknown backend {other:?}; use dx12, vulkan or all"),
    };

    let mut failed = false;
    for backend in backends {
        println!("\n===== {backend:?} =====");
        match run(backend) {
            Ok(()) => println!("RESULT {backend:?}: PASS"),
            Err(e) => {
                println!("RESULT {backend:?}: FAIL - {e}");
                failed = true;
            }
        }
    }
    if failed {
        std::process::exit(1);
    }
}

fn dxc_path() -> String {
    if let Ok(p) = std::env::var("DXC_PATH") {
        return p;
    }
    let sdk = r"C:\VulkanSDK\1.4.357.0\Bin\dxcompiler.dll";
    if std::path::Path::new(sdk).exists() {
        sdk.into()
    } else {
        "dxcompiler.dll".into()
    }
}

fn run(backend: wgpu::Backends) -> Result<(), String> {
    let mut desc = wgpu::InstanceDescriptor::new_without_display_handle();
    desc.backends = backend;
    desc.flags = wgpu::InstanceFlags::from_build_config().with_env();
    // Firefox also uses DynamicDxc (it ships its own dxcompiler.dll).
    let dxc = dxc_path();
    desc.backend_options.dx12.shader_compiler = wgpu::Dx12Compiler::DynamicDxc { dxc_path: dxc.clone() };
    if backend == wgpu::Backends::DX12 {
        println!("DXC: {dxc}");
    }
    let instance = wgpu::Instance::new(desc);

    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        ..Default::default()
    }))
    .map_err(|e| format!("no adapter: {e}"))?;
    let info = adapter.get_info();
    println!(
        "Adapter: {} | {:?} | {:?} | driver {} {}",
        info.name, info.backend, info.device_type, info.driver, info.driver_info
    );
    let features = adapter.features();
    println!(
        "EXPERIMENTAL_RAY_QUERY: {} | RAY_TRACING_PIPELINES: {} | RAY_HIT_VERTEX_RETURN: {}",
        features.contains(wgpu::Features::EXPERIMENTAL_RAY_QUERY),
        features.contains(wgpu::Features::EXPERIMENTAL_RAY_TRACING_PIPELINES),
        features.contains(wgpu::Features::EXPERIMENTAL_RAY_HIT_VERTEX_RETURN),
    );
    let l = adapter.limits();
    println!(
        "Limits: max_blas_primitive_count {} | max_blas_geometry_count {} | max_tlas_instance_count {} | max_acceleration_structures_per_shader_stage {}",
        l.max_blas_primitive_count, l.max_blas_geometry_count, l.max_tlas_instance_count, l.max_acceleration_structures_per_shader_stage
    );
    if !features.contains(wgpu::Features::EXPERIMENTAL_RAY_QUERY) {
        return Err("adapter does not expose EXPERIMENTAL_RAY_QUERY".into());
    }

    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: Some("rq-test"),
        required_features: wgpu::Features::EXPERIMENTAL_RAY_QUERY,
        required_limits: wgpu::Limits::default().using_minimum_supported_acceleration_structure_values(),
        default_queue: wgpu::QueueDescriptor { label: None },
        // SAFETY: test program; ray queries are behind wgpu's experimental-features token.
        experimental_features: unsafe { wgpu::ExperimentalFeatures::enabled() },
        memory_hints: wgpu::MemoryHints::MemoryUsage,
        trace: wgpu::Trace::Off,
    }))
    .map_err(|e| format!("request_device: {e}"))?;
    device.set_device_lost_callback(|reason, msg| eprintln!("DEVICE LOST: {reason:?} {msg}"));

    let scope = device.push_error_scope(wgpu::ErrorFilter::Validation);

    let vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("vertices"),
        contents: bytemuck::cast_slice(&VERTICES),
        usage: wgpu::BufferUsages::BLAS_INPUT,
    });
    let size_desc = wgpu::BlasTriangleGeometrySizeDescriptor {
        vertex_format: wgpu::VertexFormat::Float32x3,
        vertex_count: 3,
        index_format: None,
        index_count: None,
        flags: wgpu::AccelerationStructureGeometryFlags::OPAQUE,
    };
    let blas = device.create_blas(
        &wgpu::CreateBlasDescriptor {
            label: Some("blas"),
            flags: wgpu::AccelerationStructureFlags::PREFER_FAST_TRACE,
            update_mode: wgpu::AccelerationStructureUpdateMode::Build,
        },
        wgpu::BlasGeometrySizeDescriptors::Triangles { descriptors: vec![size_desc.clone()] },
    );
    let mut tlas = device.create_tlas(&wgpu::CreateTlasDescriptor {
        label: Some("tlas"),
        max_instances: 1,
        flags: wgpu::AccelerationStructureFlags::PREFER_FAST_TRACE,
        update_mode: wgpu::AccelerationStructureUpdateMode::Build,
    });
    // 3x4 row-major identity transform.
    let identity = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0];
    tlas[0] = Some(wgpu::TlasInstance::new(&blas, identity, CUSTOM_DATA, 0xff));

    let params = Params { grid: GRID, half_size: HALF_SIZE, _pad: [0; 2] };
    let params_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("params"),
        contents: bytemuck::bytes_of(&params),
        usage: wgpu::BufferUsages::UNIFORM,
    });
    let hits_size = (GRID * GRID) as u64 * size_of::<Hit>() as u64;
    let hits_buffer = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("hits"),
        size: hits_size,
        usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC,
        mapped_at_creation: false,
    });
    let readback = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("readback"),
        size: hits_size,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });

    let module = device.create_shader_module(wgpu::include_wgsl!("trace.wgsl"));
    let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("bgl"),
        entries: &[
            wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            },
            wgpu::BindGroupLayoutEntry {
                binding: 1,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::AccelerationStructure { vertex_return: false },
                count: None,
            },
            wgpu::BindGroupLayoutEntry {
                binding: 2,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Storage { read_only: false },
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            },
        ],
    });
    let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("bg"),
        layout: &bgl,
        entries: &[
            wgpu::BindGroupEntry { binding: 0, resource: params_buffer.as_entire_binding() },
            wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::AccelerationStructure(&tlas) },
            wgpu::BindGroupEntry { binding: 2, resource: hits_buffer.as_entire_binding() },
        ],
    });
    let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some("layout"),
        bind_group_layouts: &[Some(&bgl)],
        immediate_size: 0,
    });
    let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
        label: Some("trace"),
        layout: Some(&layout),
        module: &module,
        entry_point: Some("main"),
        compilation_options: Default::default(),
        cache: None,
    });

    let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });
    encoder.build_acceleration_structures(
        Some(&wgpu::BlasBuildEntry {
            blas: &blas,
            geometry: wgpu::BlasGeometries::TriangleGeometries(vec![wgpu::BlasTriangleGeometry {
                size: &size_desc,
                vertex_buffer: &vertex_buffer,
                first_vertex: 0,
                vertex_stride: size_of::<[f32; 3]>() as wgpu::BufferAddress,
                index_buffer: None,
                first_index: None,
                transform_buffer: None,
                transform_buffer_offset: None,
            }]),
        }),
        Some(&tlas),
    );
    {
        let mut pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor { label: None, timestamp_writes: None });
        pass.set_pipeline(&pipeline);
        pass.set_bind_group(0, &bind_group, &[]);
        pass.dispatch_workgroups(GRID.div_ceil(8), GRID.div_ceil(8), 1);
    }
    encoder.copy_buffer_to_buffer(&hits_buffer, 0, &readback, 0, hits_size);
    queue.submit([encoder.finish()]);

    if let Some(err) = pollster::block_on(scope.pop()) {
        return Err(format!("validation error: {err}"));
    }

    let slice = readback.slice(..);
    slice.map_async(wgpu::MapMode::Read, |r| r.expect("map failed"));
    device
        .poll(wgpu::PollType::wait_indefinitely())
        .map_err(|e| format!("poll: {e}"))?;
    let gpu: Vec<Hit> = bytemuck::pod_collect_to_vec(&slice.get_mapped_range().unwrap());

    compare(&gpu)
}

/// Software reference: Moller-Trumbore for the same rays. Returns (t, u, v) on a hit.
fn cpu_trace(x: f32, y: f32) -> Option<(f32, f32, f32)> {
    let sub = |a: [f32; 3], b: [f32; 3]| [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
    let dot = |a: [f32; 3], b: [f32; 3]| a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    let cross = |a: [f32; 3], b: [f32; 3]| {
        [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
    };
    let (o, d) = ([x, y, 2.0], [0.0, 0.0, -1.0]);
    let [v0, v1, v2] = VERTICES;
    let (e1, e2) = (sub(v1, v0), sub(v2, v0));
    let p = cross(d, e2);
    let det = dot(e1, p);
    if det.abs() < 1e-8 {
        return None;
    }
    let inv = 1.0 / det;
    let s = sub(o, v0);
    let u = dot(s, p) * inv;
    let q = cross(s, e1);
    let v = dot(d, q) * inv;
    let t = dot(e2, q) * inv;
    (u >= 0.0 && v >= 0.0 && u + v <= 1.0 && (0.001..=100.0).contains(&t)).then_some((t, u, v))
}

fn compare(gpu: &[Hit]) -> Result<(), String> {
    let cell = 2.0 * HALF_SIZE / GRID as f32;
    let (mut hits, mut mismatches, mut max_t_err, mut max_bary_err) = (0, 0, 0.0f32, 0.0f32);
    let mut bad_data = Vec::new();
    let mut front_faces = std::collections::BTreeSet::new();
    println!("GPU hits ('#' hit, '.' miss, 'X' differs from CPU), +y up, viewed from +z:");
    for j in 0..GRID {
        let mut row = String::new();
        for i in 0..GRID {
            let x = -HALF_SIZE + (i as f32 + 0.5) * cell;
            let y = HALF_SIZE - (j as f32 + 0.5) * cell;
            let g = gpu[(j * GRID + i) as usize];
            let gpu_hit = g.kind != 0;
            let cpu = cpu_trace(x, y);
            if gpu_hit != cpu.is_some() {
                mismatches += 1;
                row.push('X');
                continue;
            }
            row.push(if gpu_hit { '#' } else { '.' });
            if let Some((t, u, v)) = cpu {
                hits += 1;
                max_t_err = max_t_err.max((g.t - t).abs());
                max_bary_err = max_bary_err.max((g.bary[0] - u).abs()).max((g.bary[1] - v).abs());
                front_faces.insert(g.front_face);
                if g.custom_data != CUSTOM_DATA || g.primitive_index != 0 {
                    bad_data.push((i, j, g));
                }
            }
        }
        println!("  {row}");
    }
    println!(
        "hits {hits}/{} | hit/miss mismatches {mismatches} | max |t err| {max_t_err:.2e} m | max barycentric err {max_bary_err:.2e} | front_face values seen {front_faces:?}",
        GRID * GRID
    );
    if mismatches > 0 {
        return Err(format!("{mismatches} rays disagree with the CPU reference"));
    }
    if hits == 0 {
        return Err("no hits at all".into());
    }
    if max_t_err > 1e-4 || max_bary_err > 1e-4 {
        return Err("hit values differ from the CPU reference".into());
    }
    if let Some((i, j, g)) = bad_data.first() {
        return Err(format!("wrong instance data at ({i},{j}): {g:?}"));
    }
    Ok(())
}
