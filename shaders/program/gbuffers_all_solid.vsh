/*
--------------------------------------------------------------------------------

  Tachyon Shader

  program/gbuffers_all_solid:
  Handle terrain, entities, the hand, beacon beams and spider eyes

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

#if defined GRASS_GEOMETRY && defined POM && !defined PROGRAM_GBUFFERS_TERRAIN_SOLID
// Shader Grass build: POM is turned off on the CUTOUT-terrain program so its
// geometry-shader varying block can stay small and simple. The SOLID-terrain
// program keeps POM (parallax on stone/brick/etc.) and routes the POM varyings
// through the geometry stage too - see the #ifdef POM members below.
#undef POM
#endif

#ifdef GRASS_GEOMETRY
// Shader Grass: vertex -> geometry -> fragment varyings travel through an
// (unnamed) interface block so a geometry stage can sit in between. Because the
// block has no instance name its members stay in global scope, so main() does
// not change. Both terrain programs (cutout + solid) define GRASS_GEOMETRY; the
// POM members are present only where POM survives (the solid program).
out GrassVertex {
    vec2 uv;
    vec3 scene_pos;
    vec4 tint;
    flat uint material_mask;
    flat mat3 tbn;
    vec2 light_levels;
    float vanilla_ao;
#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
    // Shader Grass: scene-space center of the block this vertex belongs to,
    // computed from at_midBlock. Lets the solid GS/TCS grow grass from ANY
    // submitted face of a grass block (not just the top, which Sodium culls when
    // viewed from below) and plant the blades on the block top regardless.
    flat vec3 block_center;
#else
    // Shader Grass (cutout): the UN-WAVED scene position of this vertex. The GS keys
    // its grass-block lookup on this, so wind sway can't move the lookup into a
    // neighbouring cell and flash the vanilla tall-grass cross back into view.
    vec3 rest_scene_pos;
#endif
#ifdef POM
    vec2 atlas_tile_coord;
    vec3 tangent_pos;
    flat vec2 atlas_tile_offset;
    flat vec2 atlas_tile_scale;
#endif
};
#else
out vec2 uv;
out vec3 scene_pos;
out vec4 tint;

flat out uint material_mask;
flat out mat3 tbn;

#if defined COLORWHEEL
vec2 light_levels;
#else
out vec2 light_levels;
#endif

#if defined POM
out vec2 atlas_tile_coord;
out vec3 tangent_pos;
flat out vec2 atlas_tile_offset;
flat out vec2 atlas_tile_scale;
#endif

#if defined PROGRAM_GBUFFERS_TERRAIN
out float vanilla_ao;
#elif defined COLORWHEEL
float vanilla_ao;
#endif

#if defined PROGRAM_GBUFFERS_ENTITIES || defined PROGRAM_GBUFFERS_HAND
out vec2 uv_local;
#endif

#if defined PROGRAM_GBUFFERS_VOXELS
out vec3 block_normal;
#endif
#endif // GRASS_GEOMETRY

// --------------
//   Attributes
// --------------

attribute vec4 at_tangent;
attribute vec3 mc_Entity;
attribute vec2 mc_midTexCoord;

#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
// Shader Grass: vector from this vertex to its block center (1/64-block units,
// world-axis-aligned), used to find which block a face belongs to. Declared vec3
// to match the shadow pass (shadow.vsh) - .xyz is the offset we need.
attribute vec3 at_midBlock;
#endif

// ------------
//   Uniforms
// ------------

uniform sampler2D noisetex;

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;

uniform vec3 cameraPosition;

uniform float near;
uniform float far;

uniform ivec2 atlasSize;

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

#if defined PROGRAM_GBUFFERS_BLOCK
uniform int blockEntityId;
#endif

#if defined PROGRAM_GBUFFERS_ENTITIES
uniform int entityId;
#endif

#if (defined PROGRAM_GBUFFERS_ENTITIES || defined PROGRAM_GBUFFERS_HAND) \
    && defined IS_IRIS
uniform int currentRenderedItemId;
#endif

#include "/include/utility/space_conversion.glsl"
#include "/include/vertex/displacement.glsl"
#include "/include/vertex/utility.glsl"

void main() {
    uv = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    light_levels = clamp01(gl_MultiTexCoord1.xy * rcp(240.0));
    tint = gl_Color;
    material_mask = get_material_mask();
    tbn = get_tbn_matrix();

#if defined PROGRAM_GBUFFERS_VOXELS
    block_normal = gl_Normal;
#endif

#if defined PROGRAM_GBUFFERS_TERRAIN
    vanilla_ao = gl_Color.a < 0.1
        ? 1.0
        : gl_Color.a; // fixes models where vanilla ao breaks (eg lecterns)
    vanilla_ao
        = material_mask == 5 ? 1.0 : vanilla_ao; // no vanilla ao on leaves
    tint.a = 1.0;

#ifdef POM
    // from fayer3
    vec2 uv_minus_mid = uv - mc_midTexCoord;
    atlas_tile_offset = min(uv, mc_midTexCoord - uv_minus_mid);
    atlas_tile_scale = abs(uv_minus_mid) * 2.0;
    atlas_tile_coord = sign(uv_minus_mid) * 0.5 + 0.5;
#endif
#endif

#if defined PROGRAM_GBUFFERS_ENTITIES && !defined COLORWHEEL
    // Fix fire entity not glowing with Colored Lights
    if (light_levels.x > 0.99) {
        material_mask = 40;
    }
#endif

#if defined PROGRAM_GBUFFERS_PARTICLES
    // Make enderman/nether portal particles glow
    if (gl_Color.r > gl_Color.g && gl_Color.g < 0.6 && gl_Color.b > 0.4) {
        material_mask = 47;
    }
#endif

#if defined PROGRAM_GBUFFERS_BEACONBEAM
    // Make beacon beam glow
    material_mask = 32;
#endif

#if defined PROGRAM_GBUFFERS_ENTITIES || defined PROGRAM_GBUFFERS_HAND
    // Calculate local uv used to fix hardcoded emission on some
    // handheld/dropped items
    uv_local = sign(uv - mc_midTexCoord) * 0.5 + 0.5;
#endif

    bool is_top_vertex = uv.y < mc_midTexCoord.y;

    vec3 pos = transform(gl_ModelViewMatrix, gl_Vertex.xyz);
    pos = view_to_scene_space(pos);
#if defined GRASS_GEOMETRY && !defined PROGRAM_GBUFFERS_TERRAIN_SOLID
    // Cutout grass: keep the un-waved scene position for the GS's grass-block lookup,
    // so wind sway doesn't push that lookup into a neighbouring cell (see GrassVertex).
    rest_scene_pos = pos;
#endif
    pos = pos + cameraPosition;
    pos = animate_vertex(pos, is_top_vertex, light_levels.y, material_mask);
    pos = pos - cameraPosition;

    scene_pos = pos;

#if defined GRASS_GEOMETRY && defined PROGRAM_GBUFFERS_TERRAIN_SOLID
    // Block center (scene space). Grass blocks don't wave, so scene_pos is the
    // un-displaced vertex and this lands exactly on the block center. Guarded on
    // GRASS_GEOMETRY to match the block_center varying's declaration - dimensions
    // without shader grass (nether/end) don't declare it, so this must not run there.
    block_center = scene_pos + at_midBlock.xyz * rcp(64.0);
#endif

#if defined POM && defined PROGRAM_GBUFFERS_TERRAIN
    tangent_pos = (pos - gbufferModelViewInverse[3].xyz) * tbn;
#endif

    vec3 view_pos = scene_to_view_space(pos);
    vec4 clip_pos = project(gl_ProjectionMatrix, view_pos);

#if defined TAA && defined TAAU
    clip_pos.xy = clip_pos.xy * taau_render_scale
        + clip_pos.w * (taau_render_scale - 1.0);
    clip_pos.xy += taa_offset * clip_pos.w;
#elif defined TAA
    clip_pos.xy += taa_offset * clip_pos.w * 0.66;
#endif

    gl_Position = clip_pos;
}
