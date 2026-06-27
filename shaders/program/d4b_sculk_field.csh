/*
--------------------------------------------------------------------------------

  Tachyon Shader

  program/d4b_sculk_field.csh:
  Sculk glow field writer. Stamps every on-screen sculk fragment (material
  mask 46 — vanilla terrain and Voxy LoD alike, at any distance) into a
  persistent, world-anchored 3D field: 8-block cells, 2048-block period,
  toroidally addressed (world cell & 255). d4 samples the field for the
  teal ambiance sculk casts on its surroundings.

  Because the field is world-locked and persistent, the glow cannot move
  with the camera, and a patch keeps glowing once it has been on screen for
  a single frame. Half-res thread grid, offset over a 4-frame cycle for
  full screen coverage.

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

layout(local_size_x = 16, local_size_y = 16) in;
const vec2 workGroupsRender = vec2(0.5, 0.5);

#if defined COLORED_LIGHTS && defined SCULK_GLOW

layout(r8) writeonly uniform image3D sculk_field_img;

uniform sampler2D colortex1;
uniform sampler2D depthtex0;

uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;

uniform vec3 cameraPosition;
uniform vec2 view_res;
uniform int frameCounter;

uniform float near;
uniform float far;

#include "/include/misc/lod_mod_support.glsl"
#include "/include/utility/encoding.glsl"

void main() {
    // half-res grid, rotated over 4 frames for full coverage
    ivec2 texel = ivec2(gl_GlobalInvocationID.xy) * 2
        + ivec2(frameCounter & 1, (frameCounter >> 1) & 1);

    ivec2 render_size = ivec2(view_res * taau_render_scale);
    if (any(greaterThanEqual(texel, render_size))) return;

    // cheapest reject first: is this pixel sculk?
    float packed_by_mask = texelFetch(colortex1, texel, 0).y;
    uint material_mask = uint(255.0 * unpack_unorm_2x8(packed_by_mask).y);
    if (material_mask != 46u) return;

    float depth = texelFetch(depthtex0, texel, 0).x;

    mat4 projection_matrix_inverse = gbufferProjectionInverse;
#ifdef LOD_MOD_ACTIVE
    if (depth == 1.0) {
        depth = texelFetch(lod_depth_tex, texel, 0).x;
        projection_matrix_inverse = lod_projection_matrix_inverse;
    }
#endif
    if (depth == 1.0) return; // sky

    vec2 uv = (vec2(texel) + 0.5) / vec2(render_size);
    vec3 ndc = vec3(uv, depth) * 2.0 - 1.0;
    vec4 view_pos = projection_matrix_inverse * vec4(ndc, 1.0);
    vec3 scene_pos
        = mat3(gbufferModelViewInverse) * (view_pos.xyz / view_pos.w)
        + gbufferModelViewInverse[3].xyz;
    vec3 world_pos = scene_pos + cameraPosition;

    // 8-block cells on a 256^3 torus (2048-block period); the bitwise AND
    // wraps negative coordinates correctly
    ivec3 cell = ivec3(floor(world_pos * rcp(8.0))) & ivec3(255);

    imageStore(sculk_field_img, cell, vec4(1.0));
}

#else
void main() {}
#endif
