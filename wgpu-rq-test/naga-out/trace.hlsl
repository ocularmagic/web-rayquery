struct Params {
    uint grid;
    float half_size;
};

struct Hit {
    uint kind;
    float t;
    float2 bary;
    uint custom_data;
    uint primitive_index;
    uint front_face;
    uint _pad;
};

struct RayDesc_ {
    uint flags;
    uint cull_mask;
    float tmin;
    float tmax;
    float3 origin;
    int _pad5_0;
    float3 dir;
    int _end_pad_0;
};

struct RayIntersection {
    uint kind;
    float t;
    uint instance_custom_data;
    uint instance_index;
    uint sbt_record_offset;
    uint geometry_index;
    uint primitive_index;
    float2 barycentrics;
    bool front_face;
    int _pad9_0;
    int _pad9_1;
    row_major float4x3 object_to_world;
    int _pad10_0;
    row_major float4x3 world_to_object;
    int _end_pad_0;
};

RayDesc RayDescFromRayDesc_(RayDesc_ arg0) {
    RayDesc ret = (RayDesc)0;
    ret.Origin = arg0.origin;
    ret.TMin = arg0.tmin;
    ret.Direction = arg0.dir;
    ret.TMax = arg0.tmax;
    return ret;
}

cbuffer params : register(b0) { Params params; }
RaytracingAccelerationStructure acc_struct : register(t1);
RWByteAddressBuffer hits : register(u2);

RayDesc_ ConstructRayDesc_(uint arg0, uint arg1, float arg2, float arg3, float3 arg4, float3 arg5) {
    RayDesc_ ret = (RayDesc_)0;
    ret.flags = arg0;
    ret.cull_mask = arg1;
    ret.tmin = arg2;
    ret.tmax = arg3;
    ret.origin = arg4;
    ret.dir = arg5;
    return ret;
}

RayIntersection GetCommittedIntersection(RayQuery<RAY_FLAG_NONE> rq, uint rq_tracker) {
    RayIntersection ret = (RayIntersection)0;
    if (((rq_tracker & 4) == 4)) {
        ret.kind = rq.CommittedStatus();
        if( rq.CommittedStatus() == COMMITTED_NOTHING) {} else {
            ret.t = rq.CommittedRayT();
            ret.instance_custom_data = rq.CommittedInstanceID();
            ret.instance_index = rq.CommittedInstanceIndex();
            ret.sbt_record_offset = rq.CommittedInstanceContributionToHitGroupIndex();
            ret.geometry_index = rq.CommittedGeometryIndex();
            ret.primitive_index = rq.CommittedPrimitiveIndex();
            if( rq.CommittedStatus() == COMMITTED_TRIANGLE_HIT ) {
                ret.barycentrics = rq.CommittedTriangleBarycentrics();
                ret.front_face = rq.CommittedTriangleFrontFace();
            }
            ret.object_to_world = rq.CommittedObjectToWorld4x3();
            ret.world_to_object = rq.CommittedWorldToObject4x3();
        }
    }
    return ret;
}

[numthreads(8, 8, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    bool local = (bool)0;
    RayQuery<RAY_FLAG_NONE> rq;
    uint naga_query_init_tracker_for_rq = 0;
    Hit h = (Hit)0;

    uint _e4 = params.grid;
    if (!((id.x >= _e4))) {
        uint _e12 = params.grid;
        local = (id.y >= _e12);
    } else {
        local = true;
    }
    bool _e15 = local;
    if (_e15) {
        return;
    }
    float _e18 = params.half_size;
    uint _e23 = params.grid;
    float cell = ((2.0 * _e18) / float(_e23));
    float _e28 = params.half_size;
    float x = (-(_e28) + ((float(id.x) + 0.5) * cell));
    float _e38 = params.half_size;
    float y = (_e38 - ((float(id.y) + 0.5) * cell));
    {
        RayDesc_ naga_desc = ConstructRayDesc_(0u, 255u, 0.001, 100.0, float3(x, y, 2.0), float3(0.0, 0.0, -1.0));
        float naga_tmin = naga_desc.tmin;
        float naga_tmax = naga_desc.tmax;
        float3 naga_origin = naga_desc.origin;
        float3 naga_dir = naga_desc.dir;
        uint naga_flags = naga_desc.flags;
        bool naga_tmin_valid = (naga_tmin >= 0.0) && (naga_tmin <= naga_tmax) && !(((asuint(naga_tmin) & 2139095040) == 2139095040) && ((asuint(naga_tmin) & 0x7fffff) != 0));
        bool naga_tmax_valid = !(((asuint(naga_tmax) & 2139095040) == 2139095040) && ((asuint(naga_tmax) & 0x7fffff) != 0));
        bool naga_origin_valid = !any((((asuint(naga_origin) & 2139095040) == 2139095040) && ((asuint(naga_origin) & 0x7fffff) != 0)));
        bool naga_dir_valid = !any((((asuint(naga_dir) & 2139095040) == 2139095040) && ((asuint(naga_dir) & 0x7fffff) != 0)));
        bool naga_contains_opaque = ((naga_flags & 1) == 1);
        bool naga_contains_no_opaque = ((naga_flags & 2) == 2);
        bool naga_contains_cull_opaque = ((naga_flags & 64) == 64);
        bool naga_contains_cull_no_opaque = ((naga_flags & 128) == 128);
        bool naga_contains_cull_front = ((naga_flags & 32) == 32);
        bool naga_contains_cull_back = ((naga_flags & 16) == 16);
        bool naga_contains_skip_triangles = ((naga_flags & 256) == 256);
        bool naga_contains_skip_aabbs = ((naga_flags & 512) == 512);
        bool naga_contains_skip_triangles_aabbs =  (naga_contains_skip_aabbs && naga_contains_skip_triangles) ;
        bool naga_contains_skip_triangles_cull =  (naga_contains_cull_front && naga_contains_skip_triangles) || (naga_contains_cull_front && naga_contains_cull_back) || (naga_contains_cull_back && naga_contains_skip_triangles) ;
        bool naga_contains_multiple_opaque =  (naga_contains_cull_no_opaque && naga_contains_opaque) || (naga_contains_cull_no_opaque && naga_contains_no_opaque) || (naga_contains_cull_no_opaque && naga_contains_cull_opaque) || (naga_contains_cull_opaque && naga_contains_opaque) || (naga_contains_cull_opaque && naga_contains_no_opaque) || (naga_contains_no_opaque && naga_contains_opaque) ;
        if (naga_tmin_valid && naga_tmax_valid && naga_origin_valid && naga_dir_valid && !(naga_contains_skip_triangles_aabbs || naga_contains_skip_triangles_cull || naga_contains_multiple_opaque)) {
            naga_query_init_tracker_for_rq = naga_query_init_tracker_for_rq | 1;
            rq.TraceRayInline(acc_struct, naga_desc.flags, naga_desc.cull_mask, RayDescFromRayDesc_(naga_desc));
        }
    }
    bool _e58 = false;
    {
        bool naga_has_initialized = ((naga_query_init_tracker_for_rq & 1) == 1);
        bool naga_has_finished = ((naga_query_init_tracker_for_rq & 4) == 4);
        if (naga_has_initialized && !naga_has_finished) {
            _e58 = rq.Proceed();
            naga_query_init_tracker_for_rq = naga_query_init_tracker_for_rq | 2;
            if (!_e58) { naga_query_init_tracker_for_rq = naga_query_init_tracker_for_rq | 4; }
    }}
    RayIntersection i = GetCommittedIntersection(rq, naga_query_init_tracker_for_rq);
    h.kind = i.kind;
    if ((i.kind != 0u)) {
        h.t = i.t;
        h.bary = i.barycentrics;
        h.custom_data = i.instance_custom_data;
        h.primitive_index = i.primitive_index;
        h.front_face = (i.front_face ? 1u : 0u);
    }
    uint _e83 = params.grid;
    Hit _e88 = h;
    {
        Hit _value2 = _e88;
        hits.Store(((id.y * _e83) + id.x)*32+0, asuint(_value2.kind));
        hits.Store(((id.y * _e83) + id.x)*32+4, asuint(_value2.t));
        hits.Store2(((id.y * _e83) + id.x)*32+8, asuint(_value2.bary));
        hits.Store(((id.y * _e83) + id.x)*32+16, asuint(_value2.custom_data));
        hits.Store(((id.y * _e83) + id.x)*32+20, asuint(_value2.primitive_index));
        hits.Store(((id.y * _e83) + id.x)*32+24, asuint(_value2.front_face));
        hits.Store(((id.y * _e83) + id.x)*32+28, asuint(_value2._pad));
    }
    return;
}
