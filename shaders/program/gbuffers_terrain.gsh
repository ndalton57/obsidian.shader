/*
--------------------------------------------------------------------------------

  Tachyon Shader (a fork of SixthSurge's Photon Shaders)

  program/gbuffers_terrain.gsh:
  Shader Grass. Geometry shader that turns grass into real
  3D blades. The blade construction, wind (calcMovePlants/calcWave) and the
  option set are tuned to keep the blades thin and natural-looking.

  Two terrain programs include this GS:
   - CUTOUT  (gbuffers_terrain): grows blades on Tachyon's small green plants and
     REPLACES the original plant quad. POM is off here (small varying block).
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

// Keep POM only on the SOLID program; the cutout program drops it (see the
// matching guards in gbuffers_all_solid.vsh/.fsh) so the varying block stays
// small. This must agree across vsh/gsh/fsh or the interface block won't link.
#if defined GRASS_GEOMETRY && defined POM && !defined PROGRAM_GBUFFERS_TERRAIN_SOLID
#undef POM
#endif

// Blade vertex budget: (vertices) * (components per vertex) must stay under the
// GL geometry total-output-component limit (~1024). The SOLID block also carries
// the POM varyings (~+9 comps) AND must emit the ground triangle, so it gets a
// smaller cap; the CUTOUT block is leaner and only emits blades.
#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
layout(triangles) in;
layout(triangle_strip, max_vertices = 24) out;
#else
layout(triangles) in;
layout(triangle_strip, max_vertices = 35) out; // bushy tuft: 5 blades x 7 verts
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
//   Voxel lookup (Eclipse-style short_grass detection)
// ------------

// Read Photon's world voxel buffer to find where vanilla short_grass sits, so we
// can grow taller/bushier grass there (REPLACE_SHORT_GRASS / DETECT_FALLOFF).
// Only available with Colored Lights on (that's what builds the voxel volume);
// degrades gracefully to uniform grass otherwise.
#ifdef COLORED_LIGHTS
uniform mat4 gbufferModelViewInverse;
uniform usampler3D voxel_sampler;
// Shader Grass: per-block grass-block top tint + shared grass_top atlas tile,
// filled by the shadow pass (see update_grass_tint). Lets side-grown blades take
// the real top colour, identical to top-grown blades (no colour pop while moving).
uniform sampler2D grass_tint_sampler;
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

// 1.0 if a small plant (short_grass etc., material 2) occupies the block.
float read_short_grass(vec3 scene_p) {
    return grass_read_voxel(scene_p) == 2u ? 1.0 : 0.0;
}
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

// Solid program: tessellation supplies density, so one (full-detail) blade per
// sub-triangle. Cutout program: replace each placed plant with a BUSHY TUFT -
// several blades so it reads as a thicker clump that breaks up the uniform field
// (REPLACE_SHORT_GRASS feel). Fewer segments per blade there to fit the budget.
#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
#define BLADE_COUNT 1
#define BLADE_SEGMENTS GRASS_SEGMENTS
#else
#define BLADE_COUNT 5
#define BLADE_SEGMENTS 3
#endif

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
        // The grass_block tag exists only so we can find the block in this GS; shade
        // the block's own geometry as default terrain (matches stock Tachyon).
        if (v_out.material_mask == uint(MATERIAL_GRASS_BLOCK)) {
            v_out.material_mask = 0u;
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
        // tessellated brown dirt base and the FLAT green fringe overlay (cutout program).
        // Tessellation jitters this quad's depth so it z-fights the overlay and eats the
        // green; push this face's depth toward the far plane so the overlay wins - but
        // only over the top fringe where the overlay is, fading to 0 by 0.5 below the top
        // so the deferred AO sees no depth STEP on the dirt. See CLAUDE.md gotcha #12.
        vec3 ft = v_in[i].tint.rgb;
        bool greenish = ft.g > ft.r + 0.04 && ft.g > ft.b + 0.04;
        float below_top = (v_in[i].block_center.y + 0.5) - v_in[i].scene_pos.y;
        float bias_fade = 1.0 - smoothstep(0.3, 0.5, below_top);
        if (grower && abs(v_in[i].tbn[2].y) < 0.5 && !greenish) {
            gl_Position.z += GRASS_OVERLAY_DEPTH_BIAS * gl_Position.w * bias_fade;
        }
#endif
        EmitVertex();
    }
    EndPrimitive();
}

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
#if defined COLORED_LIGHTS && defined GRASS_FIX_FACE_CULL
        // Omnidirectional: this face grows iff it's the elected grower of an
        // exposed grass block (lets grass survive Sodium culling the top face).
        make_grass = in_range && grass_air_above(bc)
            && grass_is_grower(bc, v_in[0].tbn[2]);
#else
        // Legacy: grass-block tops only (world normal up).
        make_grass = in_range && v_in[0].tbn[2].y > 0.9;
#endif
    }
#else
    // Cutout small plants (Stage 1 behavior): greenish, ~vertical quad, in range.
    if (v_in[0].material_mask == uint(MATERIAL_SMALL_PLANTS)) {
        vec3 t = v_in[0].tint.rgb;
        bool greenish = (t.g > t.r + 0.04) && (t.g > t.b + 0.04);
        vec3 face_n = cross(p1 - p0, p2 - p0);
        bool vertical = abs(normalize(face_n + vec3(0.0, 1e-6, 0.0)).y) < 0.5;
        vec3 c = (p0 + p1 + p2) * (1.0 / 3.0);
        bool in_range = dot(c, c) < (GRASS_RANGE * GRASS_RANGE);
        make_grass = greenish && vertical && in_range;
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
    // Cutout: HIDE placed short_grass ONLY where it sits on a GRASS BLOCK (which
    // grows replacement block-top grass, Eclipse REPLACE_SHORT_GRASS). On dirt,
    // podzol, etc. there's no replacement, so keep the vanilla plant - otherwise
    // it just vanishes. Non-grass (flowers, ...) always passes through.
    if (make_grass) {
#ifdef COLORED_LIGHTS
        // Read the block beneath the plant from the voxel buffer.
        vec3 base = vec3(
            (p0.x + p1.x + p2.x) * (1.0 / 3.0),
            min(p0.y, min(p1.y, p2.y)),
            (p0.z + p1.z + p2.z) * (1.0 / 3.0)
        );
        if (grass_read_voxel(base - vec3(0.0, 0.4, 0.0))
            == uint(MATERIAL_GRASS_BLOCK)) {
            return; // hidden - block-top grass replaces it
        }
#endif
    }
    emit_passthrough(false); // keep (non-grass, or grass not on a grass block)
    return;
#endif

    // ---- Generate grass blades ----

    vec3 tri_center = (p0 + p1 + p2) * (1.0 / 3.0);
    float min_y = min(p0.y, min(p1.y, p2.y));
    float max_y = max(p0.y, max(p1.y, p2.y));
    vec3 clump = vec3(tri_center.x, min_y, tri_center.z); // planted on the ground

#if defined PROGRAM_GBUFFERS_TERRAIN_SOLID && defined COLORED_LIGHTS
    // Block center (scene) + precise world-space position + integer block index, for the
    // raw blade placement below and the bushiness scan. block_center is exact (from
    // at_midBlock), so floor() of its world pos is wobble-free (CLAUDE.md gotcha #5).
    vec3 bc = v_in[0].block_center;
    vec3 bw;
    if (distance(vec3(cameraPositionInt) + cameraPositionFract, cameraPosition)
        < 1.0) {
        bw = bc + cameraPositionFract + vec3(cameraPositionInt);
    } else {
        bw = bc + cameraPosition;
    }
    ivec3 blk_idx = ivec3(floor(bw));

#ifdef GRASS_FIX_FACE_CULL
    // RAW TESSELLATION placement: one blade per sub-triangle at its own position (no
    // grid), so the tessellator does distance LOD for free. The grower can be a SIDE, so
    // relabel the sub-triangle's two in-plane coords onto the block TOP the same way for
    // every face - grass always grows from the top plane. (Side and top tessellate
    // differently, so blades JUMP when the grower swaps; see CLAUDE.md.)
    {
        vec3 bmin = bc - 0.5;
        vec3 an = abs(v_in[0].tbn[2]);
        // Sub-triangle centroid within the block, per axis, in [0, 1].
        float xl = tri_center.x - bmin.x;
        float yl = tri_center.y - bmin.y;
        float zl = tri_center.z - bmin.z;
        // Relabel the grower face's two in-plane axes onto the top's (X, Z) the
        // SAME way for every face (a per-face flip would MIRROR opposite faces).
        float fx, fz;
        if (an.y > 0.5) {        // top / bottom -> X, Z
            fx = xl; fz = zl;
        } else if (an.x > 0.5) { // +/-X: Y,Z -> X,Z
            fx = yl; fz = zl;
        } else {                 // +/-Z: X,Y -> X,Z
            fx = xl; fz = yl;
        }
        vec2 f = clamp(vec2(fx, fz), 0.0, 1.0);

        // Plant the blade at the sub-triangle's own mapped position on the top plane
        // (block top = bc.y + 0.5). No lattice cell, no jitter: the tessellation
        // pattern alone decides where blades land - that IS the raw-tessellation look.
        clump = vec3(bmin.x + f.x, bc.y + 0.5, bmin.z + f.y);
    }
#endif // GRASS_FIX_FACE_CULL
#endif // PROGRAM_GBUFFERS_TERRAIN_SOLID && COLORED_LIGHTS

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

#if defined PROGRAM_GBUFFERS_TERRAIN_SOLID && defined COLORED_LIGHTS \
    && defined GRASS_FIX_FACE_CULL
    // PERFECT, MOVEMENT-STABLE BLADE COLOUR.
    // The blade colour must NOT depend on which face Sodium submitted, or it would
    // change as the camera crosses the top<->side cull transition. So read the
    // grass-block TOP's own tint from the per-block buffer the shadow pass fills
    // every frame, and sample the shared grass_top atlas tile. These inputs are
    // identical for top- and side-grown blades -> the transition is a colour no-op,
    // and since the value is the literal top gl_Color it tracks biomes and
    // biome-blend mods exactly. The cell math MUST match update_grass_tint (same
    // 256 window, same floor(cameraPosition.xz), same +128 centre).
    {
        vec3 cw = bc + cameraPosition; // block-center world, matching the shadow pass
        ivec2 tcell = ivec2(floor(cw.xz) - floor(cameraPosition.xz)) + 128;
        if (all(greaterThanEqual(tcell, ivec2(0)))
            && all(lessThan(tcell, ivec2(256)))) {
            vec3 top_tint = texelFetch(grass_tint_sampler, tcell, 0).rgb;
            if (dot(top_tint, vec3(1.0)) > 1e-3) { // 0 => not captured; keep fallback
                src_tint.rgb = top_tint;
                vec4 tile = texelFetch(grass_tile_sampler, ivec2(0), 0);
                if (tile.z > 1e-4 && tile.w > 1e-4) {
                    // Sample the REAL grass_top texture (blades stay textured like
                    // the block, not flat) at a world-stable per-blade point in the
                    // tile -> keeps natural blade-to-blade variation, never flickers,
                    // and is the same function for every grower (no transition pop).
                    vec2 jt = fract(vec2(
                        grass_hash(dot(stable_world, vec3(0.137, 0.071, 0.713))),
                        grass_hash(dot(stable_world, vec3(0.713, 0.137, 0.071)))));
                    guv = tile.xy + tile.zw * jt;
                }
            }
        }
    }
#endif
#ifndef PROGRAM_GBUFFERS_TERRAIN_SOLID
    // Cutout plants only: per-cluster hash seed from the BLOCK the grass sits on.
    // Offsetting y by -0.5 before floor() keeps it stable for tops that sit on an
    // integer y (otherwise sub-block precision wobble flips floor() and flickers).
    // The solid path uses continuous noise instead (see the blade loop).
    vec3 seed_cell = vec3(stable_world.x, stable_world.y - 0.5, stable_world.z);
    float seed = grass_hash(dot(floor(seed_cell), vec3(12.9898, 78.233, 37.719)));
#endif

    // Randomness from noisetex at the world position
    vec2 wxz = stable_world.xz;
    vec2 random_dir
        = 2.0 * (texture(noisetex, 0.75 * wxz).xy + texture(noisetex, 0.35 * wxz.yx).xy)
        - 1.0;

#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
    // Grass-block tops: tall, thin blades (density comes from tessellation).
    float height = 0.65 * BASE_GRASS_HEIGHT;
#ifdef COLORED_LIGHTS
    // Bushiness (taller grass) radiates outward from blocks that have vanilla
    // short_grass, tapering smoothly across the neighbours (Eclipse's
    // GRASS_DETECT_FALLOFF). Scan the 3x3 block neighbourhood: each block that
    // holds short_grass (read 0.6 above its surface, where short_grass sits)
    // contributes a boost that falls off with distance from this blade, out to
    // ~1.8 blocks. The short_grass itself is hidden by the cutout program.
    // Choose the 3x3 neighbours by the STABLE integer block index (blk_idx), NOT
    // floor() of the blade's world xz: a blade landing on an integer xz made
    // floor() wobble under sub-pixel camera motion, so the short_grass scan (and
    // thus the height) flickered on some blocks near flowers/short_grass
    // (gotcha #5). Each voxel read lands at a neighbour's block-above CENTER (where
    // short_grass sits) - mid-cell, so the read itself is stable too.
    vec2 pw = stable_world.xz;       // blade world xz (continuous -> smooth falloff)
    float bushiness = 0.0;
    for (int dx = -1; dx <= 1; ++dx) {
        for (int dz = -1; dz <= 1; ++dz) {
            vec3 nb_scene = bc + vec3(float(dx), 1.0, float(dz));
            float sg = read_short_grass(nb_scene);
            vec2 nb_world = vec2(float(blk_idx.x) + 0.5 + float(dx),
                                 float(blk_idx.z) + 0.5 + float(dz));
            float falloff = 1.0 - smoothstep(0.5, 1.8, length(pw - nb_world));
            bushiness = max(bushiness, sg * falloff);
        }
    }
    height *= mix(1.0, 1.5, bushiness); // half again as tall at full bushiness
#endif
    // Smooth LOD fade near GRASS_RANGE: blades shrink to nothing instead of
    // POPPING at the hard distance cutoff. This is the whole-patch pop-in - the
    // range test is 3D, so moving toward/away from a grassy ledge (even flying
    // straight up toward one) snaps a whole patch across the boundary. Height
    // reaches 0 by GRASS_RANGE, where detection culls anyway, so no visible step.
    // (Eclipse has this same bug - identical hard cutoff with no fade.)
    height *= 1.0 - smoothstep(GRASS_RANGE * 0.8, GRASS_RANGE, length(clump));
#else
    // Cutout plants: taller tuft so it stands above the block-top grass and
    // reads as a thicker clump. Still capped to not wildly out-grow the quad.
    float height = 0.8 * BASE_GRASS_HEIGHT;
    height = min(height, (max_y - min_y) + 0.5 * SHORT_GRASS_HEIGHT);
#endif

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
#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
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
#else
        // Cutout plants: a few hashed blades per quad (seed is block-stable).
        float h1 = grass_hash(seed + float(b) * 19.19);
        float h2 = grass_hash(seed + float(b) * 7.37 + 4.0);
        float h3 = grass_hash(seed + float(b) * 3.71 + 9.0);

        vec3 blade_offset = vec3((h1 - 0.5) * 0.4, 0.0, (h2 - 0.5) * 0.4);
        vec3 right = vec3(cos(h3 * 6.2831853), 0.0, sin(h3 * 6.2831853));
        vec3 lean = vec3(random_dir.x, 0.0, random_dir.y) * GRASS_RANDOMNESS
            * 0.35 * (0.6 + 0.8 * h1);
        float bh = height * (0.75 + 0.5 * h1);
#endif
        lean += player_push; // bend tips away from the player (curve-weighted)

        vec3 root = clump + blade_offset;               // scene space (project)
        vec3 world_root = stable_world + blade_offset;  // precise world (wind)

        emit_blade(root, world_root, bh, right, lean, src_tint, guv, gll);
    }
}
