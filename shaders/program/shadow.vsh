/*
--------------------------------------------------------------------------------

  Tachyon Shader (a fork of SixthSurge's Photon Shaders)

  program/shadow:
  Render shadow map

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

out vec2 uv;

flat out uint material_mask;
flat out vec3 tint;

#ifdef WATER_CAUSTICS
out vec3 scene_pos;
#endif

// --------------
//   Attributes
// --------------

attribute vec3 at_midBlock;
attribute vec4 at_tangent;
attribute vec3 mc_Entity;
attribute vec2 mc_midTexCoord;

// ------------
//   Uniforms
// ------------

uniform sampler2D tex;
uniform sampler2D noisetex;

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;

uniform mat4 shadowModelView;
uniform mat4 shadowModelViewInverse;

uniform vec3 cameraPosition;

uniform float near;
uniform float far;

uniform float frameTimeCounter;
uniform float rainStrength;
uniform float wetness;

uniform vec2 taa_offset;
uniform vec3 light_dir;

uniform float world_age;
uniform float time_sunrise;
uniform float time_noon;
uniform float time_sunset;
uniform float time_midnight;
uniform float biome_temperature;
uniform float biome_humidity;

#ifdef COLORED_LIGHTS
writeonly uniform uimage3D voxel_img;
#if defined SHADER_GRASS && PROCEDURAL_GEOMETRY_MODE == 3
// Shader Grass: each rendered grass-block face stamps the air cell it faces here, so
// the election can confirm a side is really meshed (update_grass_faces).
writeonly uniform uimage3D grass_face_img;
#endif

// Shader Grass: grass-block TOP corner tints (2x2 per block, 3D-keyed) + matching corner LIGHT
// (block in R, sky in G) + shared grass_top atlas tile (see update_grass_tint in voxelization.glsl).
writeonly uniform image3D grass_tint_img;
writeonly uniform image3D grass_light_img;
writeonly uniform image2D grass_tile_img;

uniform int renderStage;
#endif

// ------------
//   Includes
// ------------

#include "/include/lighting/shadows/distortion.glsl"
#include "/include/vertex/displacement.glsl"

#ifdef COLORED_LIGHTS
#include "/include/lighting/lpv/voxelization.glsl"
#endif

void main() {
    uv = gl_MultiTexCoord0.xy;
    material_mask = uint(mc_Entity.x - 10000.0);
    tint = gl_Color.rgb;

#if defined COLORED_LIGHTS && !defined PROGRAM_SHADOW_ENTITIES
    update_voxel_map(material_mask);
    update_grass_tint(material_mask);
#if defined SHADER_GRASS && PROCEDURAL_GEOMETRY_MODE == 3
    update_grass_faces(material_mask);
#endif
#endif

#if defined WORLD_NETHER
    // No shadows, discard vertices now
    gl_Position = vec4(-1.0);
    return;
#endif

    bool is_top_vertex = uv.y < mc_midTexCoord.y;

    vec3 pos = transform(gl_ModelViewMatrix, gl_Vertex.xyz);

#if !defined PROGRAM_SHADOW_ENTITIES
    // Animations
    pos = transform(shadowModelViewInverse, pos);
    pos = pos + cameraPosition;
    pos = animate_vertex(
        pos,
        is_top_vertex,
        clamp01(rcp(240.0) * gl_MultiTexCoord1.y),
        material_mask
    );
    pos = pos - cameraPosition;

#ifdef WATER_CAUSTICS
    scene_pos = pos;
#endif

#if defined SHADER_GRASS && defined COLORED_LIGHTS
    // Shadow-match the camera pass, which HIDES short_grass / tall_grass on grass blocks (replaced by
    // the 3D blades, shrinking to nothing as they near). Collapse the SAME plants toward their root
    // here, by the SAME distance factor, so the shadow shrinks with them - otherwise the hidden cross
    // still casts a full shadow, and the 2.75x tall grass shadows itself. `greenish` keeps flowers
    // (they aren't replaced). No grass-block-below test: the voxel buffer is cleared + refilled in
    // THIS pass so it can't be read reliably, so short grass on bare dirt also loses its near shadow
    // - a minor accepted trade. The collapse only moves the SHADOW geometry (voxelization above is
    // untouched, so blade growing still works). See CLAUDE.md (Shader Grass shadows).
    bool sg_short = material_mask == 85u // dedicated short_grass/fern (colour-independent)
        || (material_mask == 2u && tint.g > tint.r + 0.04 && tint.g > tint.b + 0.04); // mod grass (2)
    bool sg_tall = material_mask == 82u || material_mask == 83u;
    if (sg_short || sg_tall) {
        vec3 sg_center = pos + cameraPosition + at_midBlock * rcp(64.0); // block centre (world)
        float sg_root_drop = (material_mask == 83u) ? 1.5 : 0.5; // upper tall-grass half roots 1 lower
        vec3 sg_root = vec3(sg_center.x, sg_center.y - sg_root_drop, sg_center.z) - cameraPosition;
        float sg_h = smoothstep(GRASS_RANGE * 0.6, GRASS_RANGE * 0.8, length(sg_root));
        pos.y = sg_root.y + (pos.y - sg_root.y) * sg_h; // collapse toward the root as it nears
    }
#endif

    pos = transform(shadowModelView, pos);
    ;
#endif

    vec3 shadow_clip_pos = project_ortho(gl_ProjectionMatrix, pos);
    shadow_clip_pos = distort_shadow_space(shadow_clip_pos);

    gl_Position = vec4(shadow_clip_pos, 1.0);
}
