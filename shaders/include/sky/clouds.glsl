#if !defined INCLUDE_SKY_CLOUDS
#define INCLUDE_SKY_CLOUDS

// Volumetric clouds: the three-layer cloud field (see clouds/field.glsl)
// rendered through the deferred transport (d1 render, d2 upscale, d4
// composite). Host programs must define CLOUD_NOISETEX (the cloud_noises.png
// sampler) before including this file.

#include "clouds/field.glsl"

#endif // INCLUDE_SKY_CLOUDS
