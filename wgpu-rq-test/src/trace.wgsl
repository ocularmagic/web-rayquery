enable wgpu_ray_query;

// One ray per grid cell, fired straight down -z from z = 2 m onto a triangle at z = 0.
struct Params {
    grid: u32,      // rays per side
    half_size: f32, // grid covers [-half_size, half_size] metres in x and y
}

struct Hit {
    kind: u32,
    t: f32,
    bary: vec2<f32>,
    custom_data: u32,
    primitive_index: u32,
    front_face: u32,
    _pad: u32,
}

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var acc_struct: acceleration_structure;
@group(0) @binding(2) var<storage, read_write> hits: array<Hit>;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    if id.x >= params.grid || id.y >= params.grid {
        return;
    }
    let cell = 2.0 * params.half_size / f32(params.grid);
    let x = -params.half_size + (f32(id.x) + 0.5) * cell;
    let y = params.half_size - (f32(id.y) + 0.5) * cell;

    var rq: ray_query;
    rayQueryInitialize(&rq, acc_struct, RayDesc(0u, 0xFFu, 0.001, 100.0, vec3<f32>(x, y, 2.0), vec3<f32>(0.0, 0.0, -1.0)));
    rayQueryProceed(&rq);
    let i = rayQueryGetCommittedIntersection(&rq);

    var h: Hit;
    h.kind = i.kind;
    if i.kind != RAY_QUERY_INTERSECTION_NONE {
        h.t = i.t;
        h.bary = i.barycentrics;
        h.custom_data = i.instance_custom_data;
        h.primitive_index = i.primitive_index;
        h.front_face = select(0u, 1u, i.front_face);
    }
    hits[id.y * params.grid + id.x] = h;
}
