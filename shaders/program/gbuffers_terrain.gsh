/*
--------------------------------------------------------------------------------

  Tachyon Shader (a fork of SixthSurge's Photon Shaders)

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
// can grow taller/bushier grass there (SHORT_GRASS_HEIGHT bushiness boost).
// Only available with Colored Lights on (that's what builds the voxel volume);
// degrades gracefully to uniform grass otherwise.
#ifdef COLORED_LIGHTS
uniform mat4 gbufferModelViewInverse;
uniform usampler3D voxel_sampler;
#if PROCEDURAL_GEOMETRY_MODE == 3
uniform usampler3D grass_face_sampler; // Shader Grass: face mask (mode 3 shadow pass)
#elif PROCEDURAL_GEOMETRY_MODE >= 4
// Mode 4 (Camera): the per-block face bitmask is DOUBLE-BUFFERED (A/B, ping-ponged by frameCounter
// parity) so the election READS the buffer the pass is NOT writing this frame. Reading a buffer the
// same pass also atomically WRITES returned unstable values (the old single buffer leaned on a
// "texture read sees last frame" trick that isn't guaranteed once the write is an atomic) -> grass
// above eye level flickered. Two buffers = a clean cross-frame hand-off. frameCounter drives both the
// stamp and the parity. BOTH terrain programs compile the election read, so both declare the
// samplers; only the SOLID program WRITES (its grass-block passthrough) via imageAtomicCompSwap -
// image atomics need GL_ARB_shader_image_load_store (#version 400), enabled in the solid GS stub.
uniform int frameCounter;
uniform usampler3D grass_face_sampler_a;
uniform usampler3D grass_face_sampler_b;
#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
layout(r32ui) coherent uniform uimage3D grass_face_img_a;
layout(r32ui) coherent uniform uimage3D grass_face_img_b;
#endif
#endif
// Shader Grass: per-block grass-block top tint + shared grass_top atlas tile,
// filled by the shadow pass (see update_grass_tint). Lets side-grown blades take
// the real top colour, identical to top-grown blades (no colour pop while moving).
uniform sampler2D grass_tint_sampler;
uniform sampler2D grass_tile_sampler;
#include "/include/lighting/lpv/voxelization.glsl"
#include "/include/misc/grass_election.glsl"

#if defined COLORED_LIGHTS && PROCEDURAL_GEOMETRY_MODE >= 4 && defined PROGRAM_GBUFFERS_TERRAIN_SOLID
// Accumulate one camera-drawn face into THIS block's OWN cell. The cell is an r32ui: high bits =
// frame stamp, low 6 = face bitmask. CAS loop: if the cell's stamp is stale (a new frame) RESET the
// mask to just this face; else OR this face in. Bounded for GPU safety; at most 6 faces ever share
// a cell (usually 1-3 drawn) so it converges in ~1-2 iterations.
void grass_stamp_face(ivec3 cell, uint face_bit) {
    uint stamp = grass_stamp_now();
    bool even = (frameCounter & 1) == 0; // even frame -> WRITE A (election reads B); odd -> WRITE B
    uint cur = even ? imageLoad(grass_face_img_a, cell).x
                    : imageLoad(grass_face_img_b, cell).x;
    for (int i = 0; i < 8; ++i) {
        uint desired = ((cur >> 6) == stamp) ? (cur | face_bit) : ((stamp << 6) | face_bit);
        if (desired == cur) {
            return; // this face already recorded this frame
        }
        uint prev;
        if (even) { // explicit branch: only ONE buffer is ever written this frame (not a ternary)
            prev = imageAtomicCompSwap(grass_face_img_a, cell, cur, desired);
        } else {
            prev = imageAtomicCompSwap(grass_face_img_b, cell, cur, desired);
        }
        if (prev == cur) {
            return; // won the swap
        }
        cur = prev; // retry against the value the winner left
    }
}
#endif

// Voxelized block material at a scene-space position (0 = air / outside volume).
uint grass_read_voxel(vec3 scene_p) {
    vec3 vp = scene_to_voxel_space(scene_p);
    if (!is_inside_voxel_volume(vp)) {
        return 0u;
    }
    return texelFetch(voxel_sampler, ivec3(vp), 0).x & 127u;
}

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
        v_out.material_mask = v_in[i].material_mask;
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
        // Modes 2+: this face grows iff it's the elected grower of an exposed grass
        // block (lets grass survive Sodium culling the top face).
        make_grass = in_range && grass_air_above(bc)
            && grass_is_grower(bc, v_in[0].tbn[2]);
#else
        // Mode 1 (Top Only): grass-block tops only (world normal up).
        make_grass = in_range && v_in[0].tbn[2].y > 0.9;
#endif
#if defined COLORED_LIGHTS && PROCEDURAL_GEOMETRY_MODE >= 4
        // CAMERA-PASS MASK (mode 4): every grass-block face that reaches this GS was drawn by the
        // CAMERA (Sodium already culled the rest). Record THIS face's bit into the block's OWN cell
        // (grass_mask_cell(bc), ABSOLUTE world index so it's frame-stable). Only this block ever
        // writes its own cell, so NEXT frame's election reads an UNAMBIGUOUS per-block face bitmask
        // - no 6-way air-cell sharing (which false-positived the top and sides). See CLAUDE.md.
        if (in_range) {
            grass_stamp_face(grass_mask_cell(bc), grass_face_bit(round(v_in[0].tbn[2])));
        }
#endif
    }
#else
    // Cutout small plants (Stage 1 behavior): greenish, ~vertical quad, in range.
    if (v_in[0].material_mask == uint(MATERIAL_SMALL_PLANTS)) {
        vec3 t = v_in[0].tint.rgb;
        bool greenish = (t.g > t.r + 0.04) && (t.g > t.b + 0.04);
        vec3 face_n = cross(p1 - p0, p2 - p0);
        bool vertical = abs(normalize(face_n + vec3(0.0, 1e-6, 0.0)).y) < 0.5;
        // Identify short_grass (greenish, ~vertical quad). It's re-emitted at SHORT_GRASS_HEIGHT
        // scale; on a grass block it also SHRINKS to 0 with distance to cross-fade into the
        // block-top shader grass. See CLAUDE.md.
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
        vec3 base = vec3(
            (p0.x + p1.x + p2.x) * (1.0 / 3.0),
            min(p0.y, min(p1.y, p2.y)),
            (p0.z + p1.z + p2.z) * (1.0 / 3.0)
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
        vec3 base = vec3(
            (p0.x + p1.x + p2.x) * (1.0 / 3.0),
            min(p0.y, min(p1.y, p2.y)),
            (p0.z + p1.z + p2.z) * (1.0 / 3.0)
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
    // Blade colour by grower face. A SIDE grower's own gl_Color/uv are the grass-block
    // dirt side (untinted), not the green top, so side-grown blades borrow the top's
    // tint + grass_top tile from the per-block buffer the shadow pass fills. TOP growers
    // already carry the correct top gl_Color and grass_top uv in v_in, so they use those
    // directly. The buffer stores the top's gl_Color, so both paths land on the same
    // colour where a block's grower switches top<->side under camera motion (no pop).
    // Top growers also sidestep the buffer's camera-relative cell, which is refreshed
    // only in the shadow pass and can return a stale neighbour cell while the player
    // translates -> a whole-blade colour flicker. The cell math MUST match
    // update_grass_tint (same 256 window, same floor(cameraPosition.xz), same +128).
    if (abs(v_in[0].tbn[2].y) < 0.5) { // side grower: borrow the top's colour
        vec3 cw = bc + cameraPosition; // block-center world, matching the shadow pass
        ivec2 tcell = ivec2(floor(cw.xz) - floor(cameraPosition.xz)) + 128;
        if (all(greaterThanEqual(tcell, ivec2(0)))
            && all(lessThan(tcell, ivec2(256)))) {
            vec3 top_tint = texelFetch(grass_tint_sampler, tcell, 0).rgb;
            if (dot(top_tint, vec3(1.0)) > 1e-3) { // 0 => not captured; keep fallback
                src_tint.rgb = top_tint;
                vec4 tile = texelFetch(grass_tile_sampler, ivec2(0), 0);
                if (tile.z > 1e-4 && tile.w > 1e-4) {
                    // Sample the REAL grass_top texture (blades stay textured like the
                    // block, not flat) at a per-blade point in the tile -> natural
                    // blade-to-blade variation, same for every grower (no transition
                    // pop). The hash input MUST come from the Iris SPLIT camera so it is
                    // frame-stable: the EXACT integer world block index is a constant
                    // term and only the precise sub-block fraction varies per blade.
                    // Hashing the collapsed world float (clump + cameraPositionInt +
                    // cameraPositionFract) let grass_hash amplify that float's ~1-ULP
                    // camera-motion wobble into a whole-blade colour flicker that
                    // worsened with distance from spawn.
                    vec2 rel_xz = clump.xz + cameraPositionFract.xz;
                    vec2 iworld = vec2(cameraPositionInt.xz) + floor(rel_xz);
                    vec2 fworld = fract(rel_xz); // sub-block [0,1), precise
                    float hseed = dot(iworld, vec2(0.137, 0.713))
                        + dot(fworld, vec2(0.071, 0.911));
                    vec2 jt = fract(vec2(grass_hash(hseed),
                                         grass_hash(hseed + 19.19)));
                    guv = tile.xy + tile.zw * jt;
                }
            }
        }
    }
#endif

#ifdef CHERRY_GROVE_PINK_GRASS
    // Cherry grove: dither THIS blade fully pink or fully its biome green, per blade.
    // The dither key MUST be the split-camera world position (exact integer index
    // cameraPositionInt + precise fraction), NOT the collapsed stable_world.xz: that
    // single float wobbles ~1 ULP as the camera moves and cherry_grove_dither (a hash)
    // amplifies the wobble, flipping the pink/green pick at the biome border while moving
    // (worse far from spawn). See CLAUDE.md (split-camera dither/hash key). Per-blade (not
    // per-block) makes a transition block sprout a MIX of pink and green blades. src_tint
    // is the grass-block top's colour (own gl_Color for a top grower, or the shadow-pass
    // buffer for a side grower) - the one place a blade's colour is set.
    ivec2 cg_key = cameraPositionInt.xz * 256
        + ivec2(floor((clump.xz + cameraPositionFract.xz) * 256.0));
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
    // (Eclipse has this same bug - identical hard cutoff with no fade.)
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
