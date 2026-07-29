/*
--------------------------------------------------------------------------------

  Obsidian Shader

  program/gbuffers_all_solid:
  Handle terrain, entities, the hand, beacon beams and spider eyes

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

#if (defined GRASS_GEOMETRY || defined GRASS_VERTEX) && defined POM \
    && !defined PROGRAM_GBUFFERS_TERRAIN_SOLID
// Shader Grass build: POM stays off on the CUTOUT-terrain program (matching
// the guard in the fragment shader). The SOLID-terrain program keeps POM
// (parallax on stone/brick/etc.) and routes the POM varyings through the
// geometry stage too - see the #ifdef POM members below.
#undef POM
#endif

#ifdef GRASS_GEOMETRY
// Shader Grass: vertex -> tessellation -> geometry -> fragment varyings
// travel through an (unnamed) interface block so those stages can sit in
// between. Because the block has no instance name its members stay in global
// scope, so main() does not change. Only the SOLID terrain program defines
// GRASS_GEOMETRY; the cutout program has no geometry stage (its grass work
// happens right here in the vertex shader, under GRASS_VERTEX below) and
// uses the plain varyings.
out GrassVertex {
    vec2 uv;
    vec3 scene_pos;
    vec4 tint;
    flat uint material_mask;
    flat mat3 tbn;
    vec2 light_levels;
    float vanilla_ao;
    // Shader Grass: scene-space center of the block this vertex belongs to,
    // computed from at_midBlock. Lets the solid GS/TCS grow grass from ANY
    // submitted face of a grass block (not just the top, which Sodium culls when
    // viewed from below) and plant the blades on the block top regardless.
    flat vec3 block_center;
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

#if defined PROGRAM_GBUFFERS_TERRAIN_SOLID || defined GRASS_VERTEX
// Shader Grass: vector from this vertex to its block center (1/64-block units,
// world-axis-aligned), used to find which block a face belongs to. Declared vec3
// to match the shadow pass (shadow.vsh) - .xyz is the offset we need. The
// cutout program (GRASS_VERTEX) uses it to key its plant rescale/hide on the
// block, so all vertices of a plant agree.
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

#if defined GRASS_VERTEX && defined SHADER_GRASS && defined COLORED_LIGHTS
// Shader Grass (cutout): the grass-block lookup for the plant rescale/hide
// below - the same voxel read the solid program's geometry stage uses.
uniform usampler3D voxel_sampler;
#include "/include/lighting/lpv/voxelization.glsl"

// Voxelized block material at a scene-space position (0 = air / outside volume).
uint grass_read_voxel(vec3 scene_p) {
    vec3 vp = scene_to_voxel_space(scene_p);
    if (!is_inside_voxel_volume(vp)) {
        return 0u;
    }
    return texelFetch(voxel_sampler, ivec3(vp), 0).x & 127u;
}
#endif

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
    pos = pos + cameraPosition;
#if defined GRASS_VERTEX && defined SHADER_GRASS
    // Shader Grass (cutout): world-space center of this vertex's block, taken
    // BEFORE displacement so wind sway can't move the grass-block lookup into
    // a neighbouring cell (the same reason the old geometry stage keyed on
    // un-waved positions).
    vec3 sg_center_w = pos + at_midBlock * rcp(64.0);
#endif
    pos = animate_vertex(pos, is_top_vertex, light_levels.y, material_mask);
#ifdef GRASS_VERTEX
    // ---- Shader Grass (cutout): plant rescale / hide, in the vertex stage ----
    // This replaces the cutout geometry stage: a GS here made EVERY cutout
    // triangle (leaves, crops, plants) pay the geometry-pipeline cost just to
    // pass through. Per-vertex is equivalent: everything below derives from
    // at_midBlock, the mesh normal (tbn[2]) or the plant tint. The tint-based
    // greenish test (mod grass only - vanilla short_grass is mask 85, colour-
    // independent) can in principle differ across a quad's vertices at a
    // biome border under smooth per-vertex blending; the old geometry stage
    // had the same class of split per triangle (it keyed on vertex 0 of each
    // triangle), so the granularity change is not a regression.
    {
        uint sg_mm = material_mask;
#ifdef SHADER_GRASS
        // The plants the solid program's blades REPLACE on grass blocks:
        // shrink them toward their block bottom with the blade cross-fade,
        // and collapse them fully (zero height -> zero area -> no fragments)
        // once the blades have taken over. Dedicated short_grass/fern (85) is
        // colour-independent; mod grass (2) needs the green + ~vertical test
        // to tell it from flowers. On dirt/podzol (no blades) only the
        // short-grass 1.25x decal height applies, with no shrink.
        bool sg_tall = sg_mm == uint(MATERIAL_TALL_GRASS_LOWER)
            || sg_mm == uint(MATERIAL_TALL_GRASS_UPPER);
        bool sg_short = sg_mm == uint(MATERIAL_SHORT_GRASS)
            || (sg_mm == uint(MATERIAL_SMALL_PLANTS)
                && tint.g > tint.r + 0.04 && tint.g > tint.b + 0.04
                && abs(tbn[2].y) < 0.5);
        bool sg_flower = false;
#if defined GRASS_FLOWERS && defined COLORED_LIGHTS \
    && PROCEDURAL_GEOMETRY_MODE >= 2
        // Small flowers + the multicolor ground mats are replaced by the
        // grown stalk + head near the camera - same cross-fade
        sg_flower = (sg_mm >= uint(MATERIAL_FLOWER_FIRST)
                     && sg_mm <= uint(MATERIAL_FLOWER_LAST))
            || (sg_mm >= uint(MATERIAL_FLOWER_MAT_FIRST)
                && sg_mm <= uint(MATERIAL_FLOWER_MAT_LAST));
#endif
        if (sg_short || sg_tall || sg_flower) {
            float sg_h = 1.0;
#ifdef COLORED_LIGHTS
            // Shrink only ON a grass block (where the blades replace the
            // plant): voxel-test the supporting block, exactly like the old
            // geometry stage. Upper tall-grass halves sit one block higher.
            vec3 sg_base = sg_center_w - cameraPosition - vec3(0.0, 0.5, 0.0);
            float sg_below
                = sg_mm == uint(MATERIAL_TALL_GRASS_UPPER) ? 1.4 : 0.4;
            if (grass_read_voxel(sg_base - vec3(0.0, sg_below, 0.0))
                == uint(MATERIAL_GRASS_BLOCK)) {
                // Shrink over [0.6R, 0.8R]: full beyond 0.8R (fills space
                // past the shader-grass range), gone by 0.6R where the
                // full-height blades have taken over.
                sg_h = smoothstep(GRASS_RANGE * 0.6, GRASS_RANGE * 0.8,
                                  length(sg_base));
            }
#endif
            if (sg_h < 0.02) {
                // Fully replaced by the blades / heads: collapse the whole
                // primitive to the block center - zero area, zero fragments,
                // same result as the old geometry stage dropping it. (A flat
                // ground mat cannot be hidden by a height scale, so collapse
                // all three axes.)
                pos = sg_center_w;
            } else if (abs(tbn[2].y) < 0.5) {
                // Vertical crosses scale toward their block bottom - the
                // same pivot the old geometry stage used (its min-vertex-y
                // IS the block bottom for a cross). Flat ground mats
                // (|normal.y| >= 0.5) are excluded: their min-vertex-y is
                // their own plane, so the old stage's scale was an exact
                // no-op for them - keep that, or the mat would sink into
                // the ground plane and z-fight across the fade band.
                float sg_scale = (sg_short ? 1.25 : 1.0) * sg_h;
                float sg_pivot = sg_center_w.y - 0.5; // own-block bottom
                pos.y = sg_pivot + (pos.y - sg_pivot) * sg_scale;
            }
        }
#endif // SHADER_GRASS
        // Re-emit the split-out detection masks the way the old geometry
        // stage did, so fragment shading / cherry recolor are unchanged:
        // short_grass + small flowers + the firefly bush -> small plants,
        // tall-flower lowers -> tall plant lower, ground mats -> their
        // strong-SSS thin material. Runs with SHADER_GRASS off too (the
        // detection masks must never reach the gbuffer raw).
        if (sg_mm == uint(MATERIAL_SHORT_GRASS)
            || (sg_mm >= uint(MATERIAL_FLOWER_FIRST)
                && sg_mm <= uint(MATERIAL_FLOWER_LAST))
            || sg_mm == uint(MATERIAL_FLOWER_FIREFLY_BUSH)) {
            material_mask = uint(MATERIAL_SMALL_PLANTS);
        } else if (sg_mm >= uint(MATERIAL_FLOWER_TALL_FIRST)
                   && sg_mm <= uint(MATERIAL_FLOWER_TALL_LAST)) {
            material_mask = uint(MATERIAL_TALL_PLANTS_LOWER);
        } else if (sg_mm >= uint(MATERIAL_FLOWER_MAT_FIRST)
                   && sg_mm <= uint(MATERIAL_FLOWER_MAT_LAST)) {
            material_mask = 14u; // their strong-SSS thin material
        }
    }
#endif // GRASS_VERTEX
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
