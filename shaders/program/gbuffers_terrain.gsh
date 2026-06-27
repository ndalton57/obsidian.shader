/*
--------------------------------------------------------------------------------

  Tachyon Shader

  program/gbuffers_terrain.gsh:
  Shader Grass. Geometry shader that turns grass into real
  3D blades. The blade construction, wind (calcMovePlants/calcWave) and the
  option set are tuned to keep the blades thin and natural-looking.

  Two terrain programs include this GS:
   - CUTOUT  (gbuffers_terrain): does NOT grow blades - it re-emits each small green
     plant (short grass) as a height-scaled quad that shrinks with distance to blend
     into the solid block-top blades; flowers pass through. POM is off (small block).
   - SOLID   (gbuffers_terrain_solid, PROGRAM_GBUFFERS_TERRAIN_SOLID): grows
     blades on every grass-BLOCK top (material_mask == MATERIAL_GRASS_BLOCK,
     face pointing up, within GRASS_RANGE) while PASSING THE GROUND THROUGH.
     POM is preserved here, so the POM varyings travel through the GS too.

  Non-grass triangles (and everything when SHADER_GRASS is off) pass straight
  through unchanged.

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"
#include "/include/misc/material_masks.glsl"
#if defined CHERRY_GROVE_PINK_GRASS
#include "/include/misc/cherry_grove.glsl"
#endif

// Keep POM only on the SOLID program; the cutout program drops it (see the
// matching guards in gbuffers_all_solid.vsh/.fsh) so the varying block stays
// small. This must agree across vsh/gsh/fsh or the interface block won't link.
#if defined GRASS_GEOMETRY && defined POM && !defined PROGRAM_GBUFFERS_TERRAIN_SOLID
#undef POM
#endif

// Vertex budget: (vertices) * (components per vertex) must stay under the GL geometry
// total-output-component limit (~1024). SOLID emits the ground triangle plus one blade
// (and carries the POM varyings, ~+9 comps). CUTOUT only re-emits a single (scaled) quad
// or passes the triangle through, so it needs just 3.
#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
layout(triangles) in;
layout(triangle_strip, max_vertices = 24) out;
#else
layout(triangles) in;
layout(triangle_strip, max_vertices = 3) out;
#endif

in GrassVertex {
    vec2 uv;
    vec3 scene_pos;
    vec4 tint;
    flat uint material_mask;
    flat mat3 tbn;
    vec2 light_levels;
    float vanilla_ao;
#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
    flat vec3 block_center; // solid-only: needed for the grower-face election
#else
    vec3 rest_scene_pos; // cutout-only: un-waved position for a sway-proof grass-block lookup
#endif
#ifdef POM
    vec2 atlas_tile_coord;
    vec3 tangent_pos;
    flat vec2 atlas_tile_offset;
    flat vec2 atlas_tile_scale;
#endif
} v_in[];

out GrassVertex {
    vec2 uv;
    vec3 scene_pos;
    vec4 tint;
    flat uint material_mask;
    flat mat3 tbn;
    vec2 light_levels;
    float vanilla_ao;
#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
    flat vec3 block_center; // solid-only: needed for the grower-face election
#endif
#ifdef POM
    vec2 atlas_tile_coord;
    vec3 tangent_pos;
    flat vec2 atlas_tile_offset;
    flat vec2 atlas_tile_scale;
#endif
} v_out;

// ------------
//   Uniforms
// ------------

uniform sampler2D noisetex;

uniform mat4 gbufferModelView;
uniform mat4 gbufferProjection;

uniform vec3 cameraPosition;
uniform vec3 cameraPositionFract; // Iris: precise fractional part of camera
uniform ivec3 cameraPositionInt;  // Iris: exact integer part of camera

uniform float frameTimeCounter;
uniform vec2 taa_offset;

// ------------
//   Voxel lookup (short_grass detection)
// ------------

// Read the world voxel buffer to find where vanilla short_grass sits, so we
// can grow taller/bushier grass there (SHORT_GRASS_HEIGHT bushiness boost).
// Only available with Colored Lights on (that's what builds the voxel volume);
// degrades gracefully to uniform grass otherwise.
#ifdef COLORED_LIGHTS
uniform mat4 gbufferModelViewInverse;
uniform usampler3D voxel_sampler;
#if PROCEDURAL_GEOMETRY_MODE == 3
uniform usampler3D grass_face_sampler; // Shader Grass: face mask (mode 3 shadow pass)
#elif PROCEDURAL_GEOMETRY_MODE >= 4
// Mode 4 (Race / FCFS): a SINGLE per-block claim buffer. The first drawn face to reach the TCS this
// frame CAS-claims its block; this GS only READS the winner, via a COHERENT imageLoad (which sees the
// in-pass atomic write that a sampler read would miss - this is what makes a single same-frame buffer
// correct). frameCounter drives the per-frame stamp; both terrain programs compile the
// election, but only the SOLID program touches the image (the cutout never grows blades, so its
// grass_claim is stubbed) - image atomics need GL_ARB_shader_image_load_store (#version 400), enabled
// in the solid GS + TCS stubs.
uniform int frameCounter;
#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
layout(r32ui) coherent uniform uimage3D grass_claim_img;
#endif
#endif
// Shader Grass: per-block grass-block TOP tint AND lightmap (4 corners each - a 2x2 XZ tile per block
// in a 3D world-keyed buffer) + the shared grass_top atlas tile, filled by the shadow pass (see
// update_grass_tint). BOTH top and side/bottom growers reproduce a blade's colour AND brightness from
// these corners (grass_top_reproduce), so both are identical whichever face grows the blade - which is
// what keeps them stable as the FCFS grower races between faces.
uniform sampler3D grass_tint_sampler;
uniform sampler3D grass_light_sampler;
uniform sampler2D grass_tile_sampler;
#include "/include/lighting/lpv/voxelization.glsl"
#include "/include/misc/grass_election.glsl"

// Voxelized block material at a scene-space position (0 = air / outside volume).
uint grass_read_voxel(vec3 scene_p) {
    vec3 vp = scene_to_voxel_space(scene_p);
    if (!is_inside_voxel_volume(vp)) {
        return 0u;
    }
    return texelFetch(voxel_sampler, ivec3(vp), 0).x & 127u;
}

#if PROCEDURAL_GEOMETRY_MODE >= 2 && defined PROGRAM_GBUFFERS_TERRAIN_SOLID
// Shader Grass: reproduce a grass-block top's per-position biome colour AND lightmap by bilinearly
// blending the 4 corner texels the shadow pass captured (grass_tint_sampler = biome tint,
// grass_light_sampler = lightmap with block in R, sky in G; a 2x2 tile per block - see
// update_grass_tint). f_pos is the [0, 1] world-XZ position within the block top. Returns false (leave
// the caller's fallback) when the block wasn't captured this frame. Side/bottom growers need this
// (their own gl_Color is the dirt side and their lightmap is the side's); top growers use it too, so
// every grass face colours AND lights its blades the same way - which is what keeps colour and
// brightness stable as the FCFS grower races between faces. (Captured-detection keys off the tint
// only; the two buffers are written together, so a captured tint means a captured light.)
bool grass_top_reproduce(vec3 block_center, vec2 f_pos, out vec3 tint, out vec2 light) {
    tint = vec3(0.0);
    light = vec2(0.0);
    vec3 vp = scene_to_grass_tint_space(block_center);
    if (any(lessThan(vp, vec3(0.0)))
        || any(greaterThanEqual(vp, vec3(GRASS_TINT_SIZE)))) {
        return false;
    }
    ivec3 cell = ivec3(vp);
    ivec2 base = ivec2(cell.x * 2, cell.z * 2);
    int layer = cell.y;
    vec3 t00 = texelFetch(grass_tint_sampler, ivec3(base.x,     base.y,     layer), 0).rgb; // -X -Z
    vec3 t10 = texelFetch(grass_tint_sampler, ivec3(base.x + 1, base.y,     layer), 0).rgb; // +X -Z
    vec3 t01 = texelFetch(grass_tint_sampler, ivec3(base.x,     base.y + 1, layer), 0).rgb; // -X +Z
    vec3 t11 = texelFetch(grass_tint_sampler, ivec3(base.x + 1, base.y + 1, layer), 0).rgb; // +X +Z
    if (dot(t00 + t10 + t01 + t11, vec3(1.0)) < 1e-3) {
        return false; // not captured this frame
    }
    tint = mix(mix(t00, t10, f_pos.x), mix(t01, t11, f_pos.x), f_pos.y);
    vec2 l00 = texelFetch(grass_light_sampler, ivec3(base.x,     base.y,     layer), 0).rg;
    vec2 l10 = texelFetch(grass_light_sampler, ivec3(base.x + 1, base.y,     layer), 0).rg;
    vec2 l01 = texelFetch(grass_light_sampler, ivec3(base.x,     base.y + 1, layer), 0).rg;
    vec2 l11 = texelFetch(grass_light_sampler, ivec3(base.x + 1, base.y + 1, layer), 0).rg;
    light = mix(mix(l00, l10, f_pos.x), mix(l01, l11, f_pos.x), f_pos.y);
    return true;
}
#endif

#ifdef SHADER_GRASS
// Shader Grass: the baked decal-proximity field (filled by program/grass_bushiness.csh).
// Per voxel cell: R = nearness to short_grass, G = nearness to tall_grass/large_fern. The
// blade path reads it with one lookup instead of scanning the voxels per blade.
uniform sampler3D grass_bushiness_sampler;

// Baked decal influence at a cell (x = short_grass, y = tall_grass; 0 outside the volume).
vec2 grass_bushiness_at(ivec3 cell) {
    if (any(lessThan(cell, ivec3(0)))
        || any(greaterThanEqual(cell, voxel_volume_size))) {
        return vec2(0.0);
    }
    return texelFetch(grass_bushiness_sampler, cell, 0).xy;
}
#endif
#endif

// ------------
//   Quality / density
// ------------

#if GRASS_QUALITY == 2
#define GRASS_SEGMENTS 5
#elif GRASS_QUALITY == 1
#define GRASS_SEGMENTS 4
#else
#define GRASS_SEGMENTS 3
#endif

#if GRASS_DENSITY >= 2
#define GRASS_BLADES 3
#elif GRASS_DENSITY == 1
#define GRASS_BLADES 2
#else
#define GRASS_BLADES 1
#endif

// One (full-detail) blade per sub-triangle; tessellation supplies the field density.
// Blades are grown by the SOLID program only (the cutout re-emits scaled short-grass
// quads instead), but both programs compile emit_blade, so define these for both.
#define BLADE_COUNT 1
#define BLADE_SEGMENTS GRASS_SEGMENTS

// Blade base half-width. Blades are thin (full width ~0.045 block at the
// default thickness); a wide blade reads as a leaf, not grass.
#define GRASS_HALF_WIDTH (0.075 * GRASS_BASE_THICKNESS)

// ------------
//   Helpers
// ------------

float grass_hash(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

// Wind (calcWave / calcMovePlants style, WAVY_SPEED = 1).
vec3 grass_wave(vec3 pos) {
    float pi2wt = 150.796447372 * frameTimeCounter;
    float magnitude
        = abs(sin(dot(vec4(frameTimeCounter, pos), vec4(1.0, 0.005, 0.005, 0.005)))
              * 0.5 + 0.72)
        * 0.013;
    vec2 wave
        = (sin(pi2wt * vec2(0.0063, 0.0015) * 4.0 - pos.xz + pos.y * 0.05) + 0.1)
        * magnitude;
    return vec3(wave.x, -length(wave), wave.y) * 5.0 * GRASS_WAVY_STRENGTH;
}

vec4 grass_project(vec3 scene_p) {
    vec3 view_p = (gbufferModelView * vec4(scene_p, 1.0)).xyz;
    vec4 clip = gbufferProjection * vec4(view_p, 1.0);
#if defined TAA && defined TAAU
    clip.xy = clip.xy * taau_render_scale + clip.w * (taau_render_scale - 1.0);
    clip.xy += taa_offset * clip.w;
#elif defined TAA
    clip.xy += taa_offset * clip.w * 0.66;
#endif
    return clip;
}

void set_pom_defaults() {
#ifdef POM
    // Blades carry no parallax data; the fragment shader skips POM for small
    // plants (see has_pom in gbuffers_all_solid.fsh) so any value is fine.
    v_out.atlas_tile_coord = vec2(0.0);
    v_out.tangent_pos = vec3(0.0);
    v_out.atlas_tile_offset = vec2(0.0);
    v_out.atlas_tile_scale = vec2(0.0);
#endif
}

void emit_blade_vertex(vec3 scene_p, vec2 vuv, vec4 vtint, vec2 vll, mat3 vtbn) {
    v_out.uv = vuv;
    v_out.scene_pos = scene_p;
    v_out.tint = vtint;
    v_out.material_mask = uint(MATERIAL_SMALL_PLANTS);
    v_out.tbn = vtbn;
    v_out.light_levels = vll;
    v_out.vanilla_ao = 1.0;
#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
    v_out.block_center = vec3(0.0); // flat, unused by the fragment shader for blades
#endif
    set_pom_defaults();
    gl_Position = grass_project(scene_p);
    EmitVertex();
}

void emit_passthrough(bool grower) {
    for (int i = 0; i < 3; ++i) {
        v_out.uv = v_in[i].uv;
        v_out.scene_pos = v_in[i].scene_pos;
        v_out.tint = v_in[i].tint;
        v_out.material_mask = v_in[i].material_mask;
#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
        // The grass_block tag exists only so we can find the block in this GS; shade the
        // block's own cube as GROUND (mask 6) so it gets GROUND_SSS through the edge-wrap rim,
        // glowing at sunlit edges like the dirt around it (was 0 = no SSS).
        if (v_out.material_mask == uint(MATERIAL_GRASS_BLOCK)) {
            v_out.material_mask = 6u;
        }
#endif
        v_out.tbn = v_in[i].tbn;
        v_out.light_levels = v_in[i].light_levels;
        v_out.vanilla_ao = v_in[i].vanilla_ao;
#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
        v_out.block_center = v_in[i].block_center;
#endif
#ifdef POM
        v_out.atlas_tile_coord = v_in[i].atlas_tile_coord;
        v_out.tangent_pos = v_in[i].tangent_pos;
        v_out.atlas_tile_offset = v_in[i].atlas_tile_offset;
        v_out.atlas_tile_scale = v_in[i].atlas_tile_scale;
#endif
        // Use the pipeline's clip position directly. Tachyon's vertex shader already
        // outputs clip space, and grass-block faces are planar, so this is correct
        // even for the tessellated sub-triangles and stays on the same depth path as
        // the rest of the terrain (re-projecting via grass_project() rounded depth
        // differently and showed up as flickering acne as the sun moved).
        gl_Position = gl_in[i].gl_Position;

#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
        // GRASS-OVERLAY Z-FIGHT FIX. A grass-block SIDE is two coincident quads: this
        // tessellated brown dirt base and the FLAT green grass overlay (cutout program).
        // Tessellation jitters this quad's depth so it z-fights the overlay and eats the
        // green; push the brown base toward the far plane so the overlay wins. Applied over
        // the whole side - resource packs may run the grass overlay the full height of the
        // block, not just a top fringe - and the green overlay quad is left at its true depth
        // (so the depth buffer the deferred AO reads is the unbiased overlay). Only the
        // tessellated grower face needs this; keep the bias TINY - a larger value over-pushes
        // the base at distance and itself flickers. See CLAUDE.md gotcha #12.
        vec3 ft = v_in[i].tint.rgb;
        bool greenish = ft.g > ft.r + 0.04 && ft.g > ft.b + 0.04;
        if (grower && abs(v_in[i].tbn[2].y) < 0.5 && !greenish) {
            gl_Position.z += GRASS_OVERLAY_DEPTH_BIAS * gl_Position.w;
        }
#endif
        EmitVertex();
    }
    EndPrimitive();
}

#ifndef PROGRAM_GBUFFERS_TERRAIN_SOLID
// Cutout short_grass re-emit: re-emit the vanilla short_grass billboard at a FIXED height,
// scaled only by the distance factor `h` (1 = full, 0 = flat) so it SHRINKS into the ground
// with distance as the block-top blades take over. The SHORT_GRASS_HEIGHT slider drives ONLY
// the shader-grass blades (their bushiness boost), NOT this decal - the decal's height never
// changes with the slider. Re-projects from scene space - fine for this billboard (the
// re-projection acne worry is only the tessellated SOLID ground); the base vert stays put, so
// no z-fight at the root.
void emit_short_grass_scaled(float decal_height, float h) {
    float base_y = min(v_in[0].scene_pos.y, min(v_in[1].scene_pos.y, v_in[2].scene_pos.y));
    float scale = decal_height * h; // decal height x distance shrink
    for (int i = 0; i < 3; ++i) {
        v_out.uv = v_in[i].uv;
        vec3 sp = v_in[i].scene_pos;
        sp.y = base_y + (sp.y - base_y) * scale; // pull the top toward the ground
        v_out.scene_pos = sp;
        v_out.tint = v_in[i].tint;
        // Re-emit dedicated short_grass (85) as MATERIAL_SMALL_PLANTS (2) so the fragment shader's
        // shading and cherry-grove recolor treat it exactly as before the material split.
        uint mm = v_in[i].material_mask;
        v_out.material_mask = (mm == uint(MATERIAL_SHORT_GRASS)) ? uint(MATERIAL_SMALL_PLANTS) : mm;
        v_out.tbn = v_in[i].tbn;
        v_out.light_levels = v_in[i].light_levels;
        v_out.vanilla_ao = v_in[i].vanilla_ao;
        gl_Position = grass_project(sp);
        EmitVertex();
    }
    EndPrimitive();
}
#endif

// Build one tapered, curved, waving blade. `root` is the scene-space base (used
// to build/project the vertices); `world_root` is the PRECISE world-space base
// (used only to drive the wind, so it stays stable as the camera moves).
void emit_blade(vec3 root, vec3 world_root, float bh, vec3 right, vec3 lean,
                vec4 src_tint, vec2 guv, vec2 gll) {
    for (int s = 0; s <= BLADE_SEGMENTS; ++s) {
        float tt = float(s) / float(BLADE_SEGMENTS);
        float curve = tt * tt; // bend more toward the tip

        // Wind phase from the precise world position. Feeding camera-relative
        // coords here makes the blades shimmer/flicker when the camera moves.
        vec3 wind = grass_wave(world_root + vec3(0.0, bh * tt, 0.0)) * curve;
        vec3 center = root + vec3(0.0, bh * tt, 0.0) + lean * curve + wind;

        // Width tapers from base to tip (GRASS_THICKNESS_FALLOFF controls it)
        float w = GRASS_HALF_WIDTH * (1.0 - tt * GRASS_THICKNESS_FALLOFF);

        // Blade normal: mostly up, leaning along the width axis
        vec3 nrm = normalize(vec3(right.z, 2.0, -right.x));
        mat3 btbn = mat3(right, normalize(cross(nrm, right)), nrm);

        // Roots darker (height fade). src_tint is the vanilla per-vertex grass
        // tint (gl_Color) = the biome grass colour, which also tracks grass-fade
        // mods automatically - so block-top growers match the block they sit on.
        float heightfade = smoothstep(-0.35, 1.0, tt);
        vec4 col = src_tint;
        col.rgb *= heightfade;

        if (s == BLADE_SEGMENTS) {
            emit_blade_vertex(center, guv, col, gll, btbn); // taper to a tip
        } else {
            emit_blade_vertex(center - right * w, guv, col, gll, btbn);
            emit_blade_vertex(center + right * w, guv, col, gll, btbn);
        }
    }
    EndPrimitive();
}

void main() {
    vec3 p0 = v_in[0].scene_pos;
    vec3 p1 = v_in[1].scene_pos;
    vec3 p2 = v_in[2].scene_pos;

    bool make_grass = false;

#ifdef SHADER_GRASS
#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
    // Grow grass on grass blocks in range. Range + grower election are keyed on
    // the BLOCK center so every face agrees (must match the TCS gate exactly).
    if (v_in[0].material_mask == uint(MATERIAL_GRASS_BLOCK)) {
        vec3 bc = v_in[0].block_center;
        bool in_range = dot(bc, bc) < (GRASS_RANGE * GRASS_RANGE);
#if defined COLORED_LIGHTS && PROCEDURAL_GEOMETRY_MODE >= 2
        // Modes 2+: this face grows iff it's the chosen grower of an exposed grass
        // block (lets grass survive Sodium culling the top face). In mode 4 (Race) this
        // reads the FCFS claim the TCS already made - the first drawn face to reach the
        // TCS won the block, and every other face of it backs off here.
        make_grass = in_range && grass_air_above(bc)
            && grass_is_grower(bc, v_in[0].tbn[2]);
#else
        // Mode 1 (Top Only): grass-block tops only (world normal up).
        make_grass = in_range && v_in[0].tbn[2].y > 0.9;
#endif
    }
#else
    // Cutout grass. Material 85 is dedicated short_grass/fern -> ALWAYS grass (no colour test, so
    // savanna's yellow grass is caught too). Material 2 (flowers + mod grasses) still needs the green
    // + ~vertical test to tell mod grass from flowers. Either way it re-emits at SHORT_GRASS_HEIGHT
    // and SHRINKS to 0 with distance on a grass block (cross-fade into the block-top blades).
    if (v_in[0].material_mask == uint(MATERIAL_SHORT_GRASS)) {
        make_grass = true;
    } else if (v_in[0].material_mask == uint(MATERIAL_SMALL_PLANTS)) {
        vec3 t = v_in[0].tint.rgb;
        bool greenish = (t.g > t.r + 0.04) && (t.g > t.b + 0.04);
        vec3 face_n = cross(p1 - p0, p2 - p0);
        bool vertical = abs(normalize(face_n + vec3(0.0, 1e-6, 0.0)).y) < 0.5;
        make_grass = greenish && vertical;
    }
#endif
#endif

#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
    // Solid terrain: ALWAYS keep the ground; grass is added on top. Pass make_grass
    // so the tessellated grower face keeps its tag for the deferred shadow-bias fix.
    emit_passthrough(make_grass);
    if (!make_grass) {
        return;
    }
#else
#ifdef SHADER_GRASS
    // Cutout: tall_grass/large_fern (82/83) are REPLACED by the lifted grass-block-top blades on
    // grass blocks - hide the flat cross there, cross-fading it out with distance the way
    // short_grass does. On dirt/podzol (no blades to take over) it stays the vanilla cross.
    if (v_in[0].material_mask == uint(MATERIAL_TALL_GRASS_LOWER)
        || v_in[0].material_mask == uint(MATERIAL_TALL_GRASS_UPPER)) {
        float h = 1.0;
#ifdef COLORED_LIGHTS
        // Look up the grass block on the UN-WAVED position (rest_scene_pos), not the
        // wind-blown vertices - otherwise a gust pushes the lookup into a neighbouring
        // cell, the grass-block check fails, and the flat cross flashes back in.
        vec3 q0 = v_in[0].rest_scene_pos;
        vec3 q1 = v_in[1].rest_scene_pos;
        vec3 q2 = v_in[2].rest_scene_pos;
        vec3 base = vec3(
            (q0.x + q1.x + q2.x) * (1.0 / 3.0),
            min(q0.y, min(q1.y, q2.y)),
            (q0.z + q1.z + q2.z) * (1.0 / 3.0)
        );
        // Grass block below the plant: lower half ~0.4 below its base, upper half ~1.4.
        float below = v_in[0].material_mask == uint(MATERIAL_TALL_GRASS_UPPER) ? 1.4 : 0.4;
        if (grass_read_voxel(base - vec3(0.0, below, 0.0)) == uint(MATERIAL_GRASS_BLOCK)) {
            h = smoothstep(GRASS_RANGE * 0.6, GRASS_RANGE * 0.8, length(base));
            if (h < 0.02) {
                return; // fully replaced by the tall blades
            }
        }
#endif
        emit_short_grass_scaled(1.0, h); // natural tall-grass height, cross-fade with distance
        return;
    }
#endif
    // Cutout: short_grass (greenish, ~vertical) is re-emitted at the short-grass decal height; when
    // it sits on a GRASS BLOCK it also SHRINKS to 0 with distance to cross-fade into the block-top
    // shader grass. On dirt/podzol it just keeps the height (no shrink). Non-grass (flowers,
    // ...) passes straight through.
    if (make_grass) {
        float h = 1.0; // distance shrink (1 = full); only short_grass ON a grass block shrinks
#ifdef COLORED_LIGHTS
        // Un-waved lookup (see the tall-grass block above): keeps the grass-block test
        // stable while the plant sways, so short grass doesn't flicker back in either.
        vec3 q0 = v_in[0].rest_scene_pos;
        vec3 q1 = v_in[1].rest_scene_pos;
        vec3 q2 = v_in[2].rest_scene_pos;
        vec3 base = vec3(
            (q0.x + q1.x + q2.x) * (1.0 / 3.0),
            min(q0.y, min(q1.y, q2.y)),
            (q0.z + q1.z + q2.z) * (1.0 / 3.0)
        );
        if (grass_read_voxel(base - vec3(0.0, 0.4, 0.0))
            == uint(MATERIAL_GRASS_BLOCK)) {
            // Shrink over [0.6R, 0.8R]: full beyond 0.8R (fills space past the shader-grass range),
            // gone by 0.6R where the full-height blades have taken over. See CLAUDE.md.
            h = smoothstep(GRASS_RANGE * 0.6, GRASS_RANGE * 0.8, length(base));
            if (h < 0.02) {
                return; // fully shrunk -> hidden (full-height shader grass covers it)
            }
        }
#endif
        emit_short_grass_scaled(1.25, h); // short-grass decal height x distance shrink
        return;
    }
    emit_passthrough(false); // non-grass (flowers, ...) -> vanilla
    return;
#endif

#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
    // ---- Generate grass blades (solid grass-block tops only) ----

    vec3 tri_center = (p0 + p1 + p2) * (1.0 / 3.0);
    float min_y = min(p0.y, min(p1.y, p2.y));
    vec3 clump = vec3(tri_center.x, min_y, tri_center.z); // planted on the ground

#ifdef COLORED_LIGHTS
    // Block center (scene), for the raw blade placement below and to look up the baked
    // bushiness field. block_center is exact (from at_midBlock).
    vec3 bc = v_in[0].block_center;

#if PROCEDURAL_GEOMETRY_MODE >= 2
    // RAW TESSELLATION placement: one blade per sub-triangle at its own position (no
    // grid), so the tessellator does distance LOD for free. The grower can be a SIDE, so
    // relabel the sub-triangle's two in-plane coords onto the block TOP so EVERY face lands
    // its blades in the same top positions and a grower swap does NOT move them. Grass
    // always grows from the top plane.
    {
        vec3 bmin = bc - 0.5;
        vec3 an = abs(v_in[0].tbn[2]);
        // Sub-triangle centroid within the block, per axis, in [0, 1].
        float xl = tri_center.x - bmin.x;
        float yl = tri_center.y - bmin.y;
        float zl = tri_center.z - bmin.z;
        // Map the grower face's two in-plane coords onto the top's (X, Z) with ONE rule shared
        // by all four sides, so their sub-triangle patterns land on the IDENTICAL top positions
        // and a side<->side (or top<->side) grower swap can't shift a blade. Block-local HEIGHT
        // goes to the top's X on EVERY side; the face's ALONG-EDGE position goes to the top's Z,
        // measured in one consistent around-the-block sense (cross(outward_normal, up):
        // +X->+z, -X->-z, +Z->-x, -Z->+x). Sending height to the SAME top axis for all four
        // sides is the fix: the old relabel sent height to X on the X-faces but to Z on the
        // Z-faces, and that axis transposition is an orientation flip, so two adjacent sides
        // tessellated mirror-imaged and their blades shifted on a swap.
        float fx, fz;
        if (an.y > 0.5) {
            if (v_in[0].tbn[2].y > 0.0) {
                // Top: swap X and Z so the top quad's tessellation diagonal lines up with the
                // four sides' (which share one orientation). The face is already the X-Z plane,
                // but Minecraft splits the top quad on the opposite diagonal from a side quad,
                // so without the swap a top<->side grower swap shifts blades.
                fx = zl;
                fz = xl;
            } else {
                // Bottom: the bottom quad is the top wound the other way (CCW from below = CW
                // from above), so it needs the top's swap PLUS a flip - a 90 deg rotation - to
                // land its blades on the same top positions as every other face.
                fx = zl;
                fz = 1.0 - xl;
            }
        } else {
            fx = yl; // height -> top X (same rule for every side)
            if (an.x > 0.5) {
                fz = (v_in[0].tbn[2].x > 0.0) ? zl : (1.0 - zl); // +X / -X
            } else {
                fz = (v_in[0].tbn[2].z > 0.0) ? (1.0 - xl) : xl; // +Z / -Z
            }
        }
        vec2 f = clamp(vec2(fx, fz), 0.0, 1.0);

        // Plant the blade at the sub-triangle's own mapped position on the top plane
        // (block top = bc.y + 0.5). No lattice cell, no jitter: the tessellation
        // pattern alone decides where blades land - that IS the raw-tessellation look.
        clump = vec3(bmin.x + f.x, bc.y + 0.5, bmin.z + f.y);
    }
#endif // PROCEDURAL_GEOMETRY_MODE >= 2
#endif // COLORED_LIGHTS

    vec4 src_tint = v_in[0].tint;
    vec2 gll = v_in[0].light_levels;
    vec2 guv = (v_in[0].uv + v_in[1].uv + v_in[2].uv) * (1.0 / 3.0);

    // Precise, large-coordinate-stable world position (Iris split camera).
    vec3 stable_world;
    if (distance(vec3(cameraPositionInt) + cameraPositionFract, cameraPosition)
        < 1.0) {
        stable_world = clump + cameraPositionFract + vec3(cameraPositionInt);
    } else {
        stable_world = clump + cameraPosition;
    }

#if defined COLORED_LIGHTS && PROCEDURAL_GEOMETRY_MODE >= 2
    // f_pos: the blade's position within the block top, in [0, 1] world-XZ (the lossy camera
    // cancels in clump.xz - bc.xz, so it's frame-stable far from spawn). Drives both the grass_top
    // texture UV and the corner-tint colour blend below.
    vec2 f_pos = clamp(clump.xz - bc.xz + 0.5, 0.0, 1.0);

    // grass_top TEXTURE, sampled the SAME way for top AND side growers. A grower's own uv is its
    // OWN face (a side grower's is the grass-block DIRT side), and those don't line up across faces,
    // so the texel popped at a top<->side switch. Instead sample the shared grass_top tile at the
    // blade's POSITION on the block top (f_pos) for BOTH, so they land on the IDENTICAL texel. It is
    // a SMOOTH position map (NO hash), so clump's tiny per-frame LOD wobble can't flicker the texel.
    vec4 grass_tile = texelFetch(grass_tile_sampler, ivec2(0), 0);
    if (grass_tile.z > 1e-4 && grass_tile.w > 1e-4) {
        guv = grass_tile.xy + grass_tile.zw * f_pos;
    }

    // COLOUR: reproduce the grass-block top's per-position biome colour by bilinearly blending the
    // 4 corner tints the shadow pass captured (grass_top_reproduce). BOTH top and side growers
    // use it, so a blade's colour is identical whichever face grew it - and stays consistent even if
    // a mod alters Minecraft's own per-vertex interpolation (both faces share this one method). Falls
    // back to the live per-vertex tint when the block wasn't captured this frame: correct for a top
    // grower (its own tint IS the real top colour); a side grower then shows its dirt-side tint, but
    // an uncaptured block is rare (outside the shadow range).
    vec3 repro;
    vec2 repro_light;
    if (grass_top_reproduce(bc, f_pos, repro, repro_light)) {
        src_tint.rgb = repro;
        // Light the blade by the TOP's lightmap (block + sky), not the racing grower face's, so blade
        // brightness is identical whichever face wins the FCFS claim - no flicker. Worst without this
        // in the dark (block light near a torch) and in shade (skylight), where the lightmap IS the
        // lighting and the sun term isn't there to mask the face-to-face difference.
        gll = repro_light;
    }
#endif

#ifdef CHERRY_GROVE_PINK_GRASS
    // Cherry grove: dither THIS blade fully pink or fully its biome green, per blade.
    // The dither key MUST be the split-camera world position (exact integer index
    // cameraPositionInt + precise fraction), NOT the collapsed stable_world.xz: that
    // single float wobbles ~1 ULP as the camera moves and cherry_grove_dither (a hash)
    // amplifies the wobble, flipping the pink/green pick at the biome border while moving
    // (worse far from spawn). See CLAUDE.md (split-camera dither/hash key). Per-blade (not
    // per-block) makes a transition block sprout a MIX of pink and green blades. src_tint is the
    // grass-block top's colour - reproduced from the 4-corner buffer for BOTH top and side growers
    // (grass_top_reproduce above) - the one place a blade's colour is set.
    // Quantise to a 1/64-block grid (NOT finer): raw-tessellation blades drift as the camera
    // moves, and on a finer grid a drifting blade crosses cell boundaries more often, re-rolling
    // its hash and occasionally flipping pink<->green for a frame (a lone-blade flicker, only under
    // motion - a still camera never shows it). 64 cells/block per axis is still far more than the
    // blades on a block, so the per-blade speckle is unchanged, but boundary crossings - and the
    // flicker - are ~4x rarer.
    ivec2 cg_key = cameraPositionInt.xz * 64
        + ivec2(floor((clump.xz + cameraPositionFract.xz) * 64.0));
    src_tint.rgb = cherry_grove_pink_grass(
        src_tint.rgb, v_in[0].material_mask, cherry_grove_dither(vec2(cg_key))
    );
#endif

    // Vibrancy: saturate the blade colour (the blades only, not the grass block). 1.0 =
    // unchanged. Applied after any cherry recolor, so it lifts the final blade hue.
    float grass_vib_luma = dot(src_tint.rgb, vec3(0.2126, 0.7152, 0.0722));
    src_tint.rgb = max(mix(vec3(grass_vib_luma), src_tint.rgb, GRASS_VIBRANCY), 0.0);

    // Randomness from noisetex at the world position
    vec2 wxz = stable_world.xz;
    vec2 random_dir
        = 2.0 * (texture(noisetex, 0.75 * wxz).xy + texture(noisetex, 0.35 * wxz.yx).xy)
        - 1.0;

    // Grass-block tops: tall, thin blades (density comes from tessellation).
    float height = 0.65 * BASE_GRASS_HEIGHT;
#if defined COLORED_LIGHTS && defined SHADER_GRASS
    // Bushiness / tall grass: lift the blade where short_grass or tall_grass sits nearby.
    // The whole spread is BAKED per voxel cell by program/grass_bushiness.csh (R = short_grass
    // nearness, G = tall_grass nearness; a fixed-radius falloff, computed once per cell), so
    // here it is a single field lookup - NOT a per-blade neighbour scan (that ran hundreds of
    // times per block in the GS and tanked FPS). Read it BILINEAR in XZ at the decal cell layer
    // above this block -> a smooth per-blade falloff with no block-to-block step. (Nearest in Y:
    // the boost is a horizontal spread; y-interpolation would dilute it against empty layers.)
    {
        vec3 vp = scene_to_voxel_space(vec3(clump.x, bc.y + 1.0, clump.z));
        int vy = int(vp.y);              // decal cell layer (one above the block)
        vec2 fxz = vp.xz - 0.5;          // cell-CENTRE alignment for the interpolation
        ivec2 i0 = ivec2(floor(fxz));
        vec2 f = fract(fxz);
        vec2 infl = mix(
            mix(grass_bushiness_at(ivec3(i0.x,     vy, i0.y)),
                grass_bushiness_at(ivec3(i0.x + 1, vy, i0.y)), f.x),
            mix(grass_bushiness_at(ivec3(i0.x,     vy, i0.y + 1)),
                grass_bushiness_at(ivec3(i0.x + 1, vy, i0.y + 1)), f.x),
            f.y);
        // The taller boost wins: a tall_grass spot grows ~2-block blades (TALL_GRASS_HEIGHT), a
        // short_grass spot a modest tuft (SHORT_GRASS_HEIGHT). The reach is fixed (bake side).
        float lift = max((SHORT_GRASS_HEIGHT - 1.0) * infl.x,
                         (TALL_GRASS_HEIGHT - 1.0) * infl.y);
        height *= 1.0 + lift;
    }
#endif
    // Smooth LOD fade near GRASS_RANGE: blades shrink to nothing instead of
    // POPPING at the hard distance cutoff. This is the whole-patch pop-in - the
    // range test is 3D, so moving toward/away from a grassy ledge (even flying
    // straight up toward one) snaps a whole patch across the boundary. Height
    // reaches 0 by GRASS_RANGE, where detection culls anyway, so no visible step.
    height *= 1.0 - smoothstep(GRASS_RANGE * 0.8, GRASS_RANGE, length(clump));

    // Player-proximity outward bend: grass within ~1 block of the camera xz
    // splays away from you - it parts as you walk through, and (because the
    // tips lean outward) it hides the edge-on billboards when you look straight
    // down. clump is camera-relative. Applied curve-weighted in emit_blade.
    float player_h = length(clump.xz);
    float player_prox
        = smoothstep(1.0, 0.15, player_h) * smoothstep(3.0, 0.5, abs(clump.y));
    vec2 player_dir = player_h > 1e-3 ? clump.xz / player_h : vec2(0.0);
    vec3 player_push
        = vec3(player_dir.x, 0.0, player_dir.y) * player_prox * 0.35;

    for (int b = 0; b < BLADE_COUNT; ++b) {
        // Tessellation supplies density (one blade per sub-triangle); ALL the
        // per-blade variation comes from CONTINUOUS noise sampled at the precise
        // world position, so it varies naturally yet never flickers when moving
        // (no floor()/hash boundaries). random_dir is the same noise pair.
        vec2 rnd = random_dir; // NOTE: ranges ~[-1, 3] (biased +), NOT [-1, 1]
        float hgt = texture(noisetex, stable_world.xz * 0.29 + 0.53).y;
        // Root each blade EXACTLY on its tessellated position - no jitter. (This
        // used to be `rnd * 0.05`, but rnd is biased toward +x/+z, which shoved
        // blade BASES off the +x/+z block edge into the air. Tessellation already
        // spreads the blades across the top, so no jitter is needed.)
        vec3 blade_offset = vec3(0.0);

        // Billboard: width axis perpendicular to the view direction, so each
        // blade faces the camera and is visible from every angle. clump is
        // camera-relative, so normalize(clump) is the view dir.
        // Order is cross(view_dir, up) (not up x view_dir) so the strip winds
        // front-facing toward the camera and survives backface culling.
        vec3 view_dir = normalize_safe(clump + blade_offset);
        vec3 raxis = cross(view_dir, vec3(0.0, 1.0, 0.0));
        vec3 right
            = length(raxis) > 1e-3 ? normalize(raxis) : vec3(1.0, 0.0, 0.0);

        vec3 lean = vec3(rnd.x, 0.0, rnd.y) * GRASS_RANDOMNESS * 0.35;
        float bh = height * (0.8 + 0.5 * hgt);
        lean += player_push; // bend tips away from the player (curve-weighted)

        vec3 root = clump + blade_offset;               // scene space (project)
        vec3 world_root = stable_world + blade_offset;  // precise world (wind)

        emit_blade(root, world_root, bh, right, lean, src_tint, guv, gll);
    }
#endif // PROGRAM_GBUFFERS_TERRAIN_SOLID
}
