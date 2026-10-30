// language: metal2.4
#include <metal_stdlib>
#include <simd/simd.h>

using metal::uint;

struct _mslBufferSizes {
    uint size2;
};

struct Params {
    uint grid;
    float half_size;
};
struct Hit {
    uint kind;
    float t;
    metal::float2 bary;
    uint custom_data;
    uint primitive_index;
    uint front_face;
    uint _pad;
};
typedef Hit type_4[1];
struct RayDesc {
    uint flags;
    uint cull_mask;
    float tmin;
    float tmax;
    metal::float3 origin;
    metal::float3 dir;
};
struct RayIntersection {
    uint kind;
    float t;
    uint instance_custom_data;
    uint instance_index;
    uint sbt_record_offset;
    uint geometry_index;
    uint primitive_index;
    metal::float2 barycentrics;
    bool front_face;
    char _pad9[11];
    metal::float4x3 object_to_world;
    metal::float4x3 world_to_object;
};
RayIntersection ray_query_get_intersection_true(metal::raytracing::intersection_query<metal::raytracing::instancing, metal::raytracing::triangle_data> intersector
, uint intersector_tracker
) {
    RayIntersection intersection = RayIntersection {};
    if (((intersector_tracker & 4) == 4)) {
        metal::raytracing::intersection_type ty = intersector.get_committed_intersection_type();
        if (ty == metal::raytracing::intersection_type::triangle) {
            intersection.kind = 1;
            intersection.barycentrics = intersector.get_committed_triangle_barycentric_coord();
            intersection.front_face = intersector.is_committed_triangle_front_facing();
        } else if (ty == metal::raytracing::intersection_type::bounding_box) {
            intersection.kind = 2;
        }
        if (ty != metal::raytracing::intersection_type::none) {
            intersection.t = intersector.get_committed_distance();
            intersection.instance_custom_data = intersector.get_committed_user_instance_id();
            intersection.instance_index = intersector.get_committed_instance_id();
            intersection.geometry_index = intersector.get_committed_geometry_id();
            intersection.primitive_index = intersector.get_committed_primitive_id();
            intersection.object_to_world = intersector.get_committed_object_to_world_transform();
            intersection.world_to_object = intersector.get_committed_world_to_object_transform();
        }
    }
    return intersection;
}

struct main_Input {
};
[[max_total_threads_per_threadgroup(64)]] kernel void main_(
  metal::uint3 id [[thread_position_in_grid]]
, constant Params& params [[user(fake0)]]
, metal::raytracing::instance_acceleration_structure acc_struct [[user(fake0)]]
, device type_4& hits [[user(fake0)]]
, constant _mslBufferSizes& _buffer_sizes [[user(fake0)]]
) {
    bool local = {};
    metal::raytracing::intersection_query<metal::raytracing::instancing, metal::raytracing::triangle_data> rq = {};
    uint naga_query_init_tracker_for_rq = 0u;
    float naga_query_tmax_tracker_for_rq = 0.0;
    Hit h = {};
    uint _e4 = params.grid;
    if (!((id.x >= _e4))) {
        uint _e12 = params.grid;
        local = id.y >= _e12;
    } else {
        local = true;
    }
    bool _e15 = local;
    if (_e15) {
        return;
    }
    float _e18 = params.half_size;
    uint _e23 = params.grid;
    float cell = (2.0 * _e18) / static_cast<float>(_e23);
    float _e28 = params.half_size;
    float x = -(_e28) + ((static_cast<float>(id.x) + 0.5) * cell);
    float _e38 = params.half_size;
    float y = _e38 - ((static_cast<float>(id.y) + 0.5) * cell);
    RayDesc _e57 = RayDesc {0u, 255u, 0.001, 100.0, metal::float3(x, y, 2.0), metal::float3(0.0, 0.0, -1.0)};
    {
        RayDesc desc = _e57;
        metal::raytracing::intersection_params params;
        metal::raytracing::opacity_cull_mode cull_mode = 
            (desc.flags & 64) != 0 ? metal::raytracing::opacity_cull_mode::opaque : (
                (desc.flags & 128) != 0 ? metal::raytracing::opacity_cull_mode::non_opaque : metal::raytracing::opacity_cull_mode::none
            );
        params.set_opacity_cull_mode(cull_mode);
        bool force_opacity = cull_mode == metal::raytracing::opacity_cull_mode::none;
        if (force_opacity) {
            params.force_opacity(
                (desc.flags & 1) != 0 ? metal::raytracing::forced_opacity::opaque : (
                    (desc.flags & 2) != 0 ? metal::raytracing::forced_opacity::non_opaque : metal::raytracing::forced_opacity::none
                )
            );
        }
        params.accept_any_intersection((desc.flags & 4) != 0);
        metal::raytracing::ray ray = metal::raytracing::ray(desc.origin, desc.dir, desc.tmin, desc.tmax);
        bool invalid_nan_infs = ((as_type<uint>(desc.origin.x) & 2139095040) == 2139095040) || ((as_type<uint>(desc.origin.y) & 2139095040) == 2139095040) || ((as_type<uint>(desc.origin.z) & 2139095040) == 2139095040) || ((as_type<uint>(desc.dir.x) & 2139095040) == 2139095040) || ((as_type<uint>(desc.dir.y) & 2139095040) == 2139095040) || ((as_type<uint>(desc.dir.z) & 2139095040) == 2139095040) || ((as_type<uint>(desc.tmin) & 2139095040) == 2139095040) || (((as_type<uint>(desc.tmax) & 2139095040) == 2139095040) && ((as_type<uint>(desc.tmax) & 0x7fffff) != 0));
        bool invalid_t = (desc.tmin > desc.tmax) || (desc.tmin < 0.0);
        bool invalid_dir = metal::all(metal::abs(desc.dir) == 0.0);
        if (!(invalid_dir || invalid_t || invalid_nan_infs)) {
            rq.reset(ray,acc_struct, desc.cull_mask, params);
            naga_query_init_tracker_for_rq = 1;
            naga_query_tmax_tracker_for_rq = desc.tmax;
        }
    }
    bool _e58 = false;
    if (((naga_query_init_tracker_for_rq & 1) == 1) && !((naga_query_init_tracker_for_rq & 4) == 4)) {
        _e58 = rq.next();
        naga_query_init_tracker_for_rq = naga_query_init_tracker_for_rq | (_e58 ? 2: 6);
    }
    RayIntersection i = ray_query_get_intersection_true(rq, naga_query_init_tracker_for_rq);
    h.kind = i.kind;
    if (i.kind != 0u) {
        h.t = i.t;
        h.bary = i.barycentrics;
        h.custom_data = i.instance_custom_data;
        h.primitive_index = i.primitive_index;
        h.front_face = i.front_face ? 1u : 0u;
    }
    uint _e83 = params.grid;
    Hit _e88 = h;
    hits[(id.y * _e83) + id.x] = _e88;
    return;
}
