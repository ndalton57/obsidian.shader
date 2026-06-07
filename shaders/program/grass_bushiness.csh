/*
--------------------------------------------------------------------------------

  Tachyon Shader (a fork of SixthSurge's Photon Shaders)

  program/grass_bushiness.csh:
  Shader Grass bushiness bake. Once per voxel cell, spread the vanilla short_grass
  markers (material 2 in voxel_sampler) into a smooth [0,1] grass-height influence
  field, so the terrain geometry shader can read the height boost with ONE field
  lookup per blade instead of an N*N neighbour scan per blade (which was GS-bound and
  tanked FPS). Runs as a world0 shadowcomp, after the shadow pass has voxelized the
  scene. See CLAUDE.md (Short-grass bushiness).

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

layout(local_size_x = 32) in;

#if VOXEL_VOLUME_SIZE == 64
const ivec3 workGroups = ivec3(2, 64, 64);
#elif VOXEL_VOLUME_SIZE == 96
const ivec3 workGroups = ivec3(3, 96, 96);
#elif VOXEL_VOLUME_SIZE == 128
const ivec3 workGroups = ivec3(4, 128, 128);
#elif VOXEL_VOLUME_SIZE == 256
const ivec3 workGroups = ivec3(8, 256, 256);
#elif VOXEL_VOLUME_SIZE == 512
const ivec3 workGroups = ivec3(16, 512, 512);
#endif

#if defined COLORED_LIGHTS && defined SHADER_GRASS
uniform usampler3D voxel_sampler;
writeonly uniform image3D grass_bushiness_img;

void main() {
    ivec3 cell = ivec3(gl_GlobalInvocationID);

    // One thread per cell -> the strongest short_grass (material 2) falloff from any cell
    // within GRASS_BUSHINESS_REACH in the SAME y-layer (the boost spreads horizontally, the
    // way grass tufts out across neighbouring block tops). The reach is FIXED here:
    // SHORT_GRASS_HEIGHT scales the HEIGHT in the GS, NOT this radius, so dense short_grass
    // doesn't turn the whole field tall. 1 - t^2 from full at the short_grass cell to 0 at reach.
    float reach = GRASS_BUSHINESS_REACH; // blocks (fixed; raise for a wider spread)
#ifdef GRASS_BUSHINESS_DYNAMIC_SCAN
    int n = min(int(ceil(reach)), GRASS_BUSHINESS_MAX_CELLS);
#else
    const int n = GRASS_BUSHINESS_MAX_CELLS; // compile-time -> the loop unrolls
#endif
    float influence = 0.0;
    for (int dx = -n; dx <= n; ++dx) {
        for (int dz = -n; dz <= n; ++dz) {
            ivec3 nc = cell + ivec3(dx, 0, dz);
            if (any(lessThan(nc, ivec3(0)))
                || any(greaterThanEqual(nc, ivec3(VOXEL_VOLUME_SIZE)))
                || (texelFetch(voxel_sampler, nc, 0).x & 127u) != 2u) {
                continue; // outside the volume, or not short_grass
            }
            float d = length(vec2(float(dx), float(dz))); // cell distance (blocks)
            float t = clamp((d - 0.5) / max(reach - 0.5, 1e-3), 0.0, 1.0);
            influence = max(influence, 1.0 - t * t);
        }
    }
    imageStore(grass_bushiness_img, cell, vec4(influence));
}
#else
void main() {}
#endif
