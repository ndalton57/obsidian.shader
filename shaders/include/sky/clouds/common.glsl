#if !defined INCLUDE_SKY_CLOUDS_COMMON
#define INCLUDE_SKY_CLOUDS_COMMON

#include "/include/sky/atmosphere.glsl"
#include "/include/utility/color.glsl"
#include "/include/utility/fast_math.glsl"
#include "/include/utility/geometry.glsl"
#include "/include/utility/phase_functions.glsl"
#include "/include/utility/random.glsl"
#include "/include/utility/sampling.glsl"

// ----

struct CloudsResult {
    vec4 scattering; // w = ambient scattering, for lightning flashes
    float transmittance;
    float apparent_distance;
};

const CloudsResult clouds_not_hit = CloudsResult(vec4(0.0), 1.0, 1e5);

#endif
