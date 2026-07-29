/*
--------------------------------------------------------------------------------

  Obsidian Shader

  program/gbuffers_terrain.gsh:
  Shader Grass. Geometry shader that turns grass into real
  3D blades. The blade construction, wind (calcMovePlants/calcWave) and the
  option set are tuned to keep the blades thin and natural-looking.

  Included ONLY by the SOLID terrain program (gbuffers_terrain_solid,
  PROGRAM_GBUFFERS_TERRAIN_SOLID): grows blades on every grass-BLOCK top
  (material_mask == MATERIAL_GRASS_BLOCK, face pointing up, within
  GRASS_RANGE) while PASSING THE GROUND THROUGH. POM is preserved here, so
  the POM varyings travel through the GS too.

  The CUTOUT terrain program has NO geometry stage: its grass work (hiding /
  height-scaling the flat plant crosses that the blades replace) is done in
  the vertex shader instead (GRASS_VERTEX in gbuffers_all_solid.vsh) - a
  geometry stage there made EVERY cutout triangle (all leaves, crops, plants)
  pay the GS pipeline cost just to pass through.

  Non-grass triangles (and everything when SHADER_GRASS is off) pass straight
  through unchanged.

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"
#include "/include/misc/material_masks.glsl"
#if defined CHERRY_GROVE_PINK_GRASS
#include "/include/misc/cherry_grove.glsl"
#endif

layout(triangles) in;

// Vertex budget. The driver statically sizes the GS output buffer from
// max_vertices x output components, and that allocation limits how many GS
// invocations run in parallel - paid by EVERY solid triangle in the world,
// not just the grass. So declare the EXACT worst case per quality, not a
// rounded-up constant: ground triangle (3) + one blade (2*SEGMENTS + 1 tip
// vertex), or - with flowers active - stalk stem (2*(SEGMENTS + 1)) + head
// quad (4), whichever is larger (the stem+head). SEGMENTS is 5/4/3 for
// quality 2/1/0 (see GRASS_SEGMENTS below); update this table if the
// per-invocation emission ever changes. Spelled as literals: #version 400
// layout qualifier values must be integer literals (constant expressions
// need GL_ARB_enhanced_layouts, which is not required here).
#ifndef SHADER_GRASS
layout(triangle_strip, max_vertices = 3) out; // passthrough only
#elif defined GRASS_FLOWERS && defined COLORED_LIGHTS \
    && PROCEDURAL_GEOMETRY_MODE >= 2
#if GRASS_QUALITY == 2
layout(triangle_strip, max_vertices = 19) out; // 3 + stem 12 + head 4
#elif GRASS_QUALITY == 1
layout(triangle_strip, max_vertices = 17) out; // 3 + stem 10 + head 4
#else
layout(triangle_strip, max_vertices = 15) out; // 3 + stem 8 + head 4
#endif
#else
#if GRASS_QUALITY == 2
layout(triangle_strip, max_vertices = 14) out; // 3 + blade 11
#elif GRASS_QUALITY == 1
layout(triangle_strip, max_vertices = 12) out; // 3 + blade 9
#else
layout(triangle_strip, max_vertices = 10) out; // 3 + blade 7
#endif
#endif

in GrassVertex {
    vec2 uv;
    vec3 scene_pos;
    vec4 tint;
    flat uint material_mask;
    flat mat3 tbn;
    vec2 light_levels;
    float vanilla_ao;
    flat vec3 block_center; // needed for the grower-face election
#ifdef POM
    vec2 atlas_tile_coord;
    vec3 tangent_pos;
    flat vec2 atlas_tile_offset;
    flat vec2 atlas_tile_scale;
#endif
} v_in[];

#if defined SHADER_GRASS && defined PROGRAM_GBUFFERS_TERRAIN_SOLID \
    && defined IRIS_FEATURE_TESSELLATION_SHADERS
// Per-patch election result computed in the TCS (range + air-above + grower
// election/claim, keyed on the block center) and passed through the TES.
// Only exists when tessellation stages are attached; without the feature the
// GS runs the election itself below.
flat in float te_grass_elected[];
#endif

// NOTE: block_center is deliberately ABSENT here (it is a GS input, consumed
// by the election/blade placement above and never read by the fragment
// shader) - every component trimmed from this block shrinks the per-vertex
// GS output stride, which the whole solid pass pays for.
out GrassVertex {
    vec2 uv;
    vec3 scene_pos;
    vec4 tint;
    flat uint material_mask;
    flat mat3 tbn;
    vec2 light_levels;
    float vanilla_ao;
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
uniform vec3 relativeEyePosition; // Iris: player-head -> camera offset

uniform float frameTimeCounter;
uniform vec2 taa_offset;
uniform float rainStrength;
uniform float thunderStrength; // Iris: 0-1 during thunderstorms

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
// frame CAS-claims its block; the GS receives the result as the te_grass_elected patch flag and only
// runs the election itself in the no-tessellation fallback (where no TCS exists). frameCounter drives
// the per-frame stamp - image atomics need GL_ARB_shader_image_load_store
// (#version 400), enabled in the solid GS + TCS stubs.
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
// Per voxel cell: R = nearness to short_grass, G = nearness to tall_grass/large_fern,
// B = nearness to a firefly bush, A = nearness to amethyst (the glow dyes). The
// blade path reads it with one lookup instead of scanning the voxels per blade.
uniform sampler3D grass_bushiness_sampler;

#ifdef GRASS_FLOWERS
// Shader Grass: the baked flower dye field (same bake pass): rgb = the
// strongest nearby bloom's petal tone, a = its falloff. Drives the per-blade
// tip-dye probability.
uniform sampler3D grass_flower_field_sampler;

// Shader Grass: the baked stalk-spot lists (same bake pass): two rgba32ui
// texels per cell = up to 8 packed spots landing on that cell's block
// (valid 1 | x 8 | z 8 | k 6 | family 5 | flower offset 4). The bake derives
// them ONCE per cell from every nearby flower's spot set; a grower
// sub-triangle only tests its own block's few spots against its footprint -
// re-deriving every nearby spot per BLADE cratered FPS in dense flower
// fields.
uniform usampler3D grass_flower_spots_sampler;
#endif
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

// One (full-detail) blade per sub-triangle; tessellation supplies the field
// density. If BLADE_COUNT or the per-blade emission ever changes, update the
// max_vertices table at the top of this file to match.
#define BLADE_COUNT 1
#define BLADE_SEGMENTS GRASS_SEGMENTS

// Blade base half-width. Blades are thin (full width ~0.045 block at the
// default thickness); a wide blade reads as a leaf, not grass.
#define GRASS_HALF_WIDTH (0.075 * GRASS_BASE_THICKNESS)

// ------------
//   Helpers
// ------------

// Integer-lattice value noise for everything per-blade: a hashed white-noise
// lattice, smoothstep-interpolated. Structureless and aperiodic by
// construction at any world distance, and continuous everywhere (no hash
// boundaries to flicker across). noisetex lookups are NOT usable for these:
// the texture's content carries its own visible structure, and sampling it
// at blade scale tiles it every 1/scale blocks - the 0.75*worldpos lookup
// wallpapered a 1.33-block rosette lattice across every field.
vec2 grass_hash2(ivec2 c) {
    uvec2 u = uvec2(c);
    uint h = u.x * 0x8da6b343u ^ u.y * 0xd8163841u;
    h = (h ^ (h >> 13)) * 0x9E3779B1u;
    h ^= h >> 16;
    return vec2(h & 0xFFFFu, h >> 16) * (1.0 / 65535.0);
}

vec2 grass_vnoise2(vec2 p) {
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    ivec2 c = ivec2(floor(p));
    return mix(
        mix(grass_hash2(c), grass_hash2(c + ivec2(1, 0)), f.x),
        mix(grass_hash2(c + ivec2(0, 1)), grass_hash2(c + ivec2(1, 1)), f.x),
        f.y
    );
}

// Wind (calcWave / calcMovePlants style, WAVY_SPEED = 1). Weather raises the
// wave amplitude: clear 1.0x -> rain 1.6x -> thunderstorm 2.2x. Clear-day
// wind swells and lulls (the gust cycle); storm wind blows STEADY - the gust
// cycle flattens toward a sustained level as rain sets in. `sky` is the
// blade's skylight: sheltered/cave grass keeps only a tiny residual sway.
// phase_jitter/amp_jitter are PER-BLADE offsets: without them the field is
// purely positional and neighbouring blades sway in lockstep with it.
vec3 grass_wave(vec3 pos, float sky, vec2 phase_jitter, float amp_jitter) {
    float pi2wt = 150.796447372 * frameTimeCounter;
    float gust
        = abs(sin(dot(vec4(frameTimeCounter, pos), vec4(1.0, 0.005, 0.005, 0.005)))
              * 0.5 + 0.72);
    gust = mix(gust, 0.95, rainStrength);
    float magnitude = gust * 0.013;
    // Each displacement component sums two plane waves with DIFFERENT
    // diagonal wave vectors, so the phase varies along BOTH horizontal axes.
    // A plain -pos.x phase moves every blade at equal x in lockstep - one
    // full-field roll when sighted along z (and -pos.z likewise along x).
    // On top, each patch of grass takes a random phase offset from a SMOOTH
    // low-frequency noise field (one lattice cell = 4 blocks): any sum of a
    // few sinusoids still forms a readable traveling front, and the patch
    // offsets shatter it - crests only exist patch-locally (like gusts),
    // never as a field-wide band. The field is hash-lattice noise, so the
    // phase rolls smoothly from patch to patch with no tiling to see.
    vec2 patch_phase = tau * grass_vnoise2(pos.xz * 0.25);
    vec2 phase_a = vec2(
        dot(pos.xz, vec2(1.0, 0.62)),
        dot(pos.xz, vec2(-0.48, 1.0))
    ) - pos.y * 0.05 + patch_phase;
    vec2 phase_b = vec2(
        dot(pos.xz, vec2(0.31, -0.74)),
        dot(pos.xz, vec2(0.83, 0.27))
    ) * 2.3 + patch_phase.yx * 1.7;
    vec2 wave = (sin(pi2wt * vec2(0.0063, 0.0015) * 4.0 - phase_a - phase_jitter)
                 + 0.55
                     * sin(pi2wt * vec2(0.0171, 0.0043) * 4.0 - phase_b
                           - phase_jitter * 1.7))
        * (magnitude / 1.55);
    wave += 0.1 * magnitude;
    float storm = 1.0 + 0.6 * rainStrength + 0.6 * thunderStrength;
    float sky_gate = 0.08 + 0.92 * sky * sky;
    return vec3(wave.x, -length(wave), wave.y) * 5.0 * GRASS_WAVY_STRENGTH
        * storm * sky_gate * amp_jitter;
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

// Mask the blade emitters write. Small plants by default; the flower system
// switches it per blade for GLOWING dyed tips (the deferred pass chroma-keys
// emission off these masks) and resets it after each emit.
uint blade_emit_mask = uint(MATERIAL_SMALL_PLANTS);

void emit_blade_vertex(vec3 scene_p, vec2 vuv, vec4 vtint, vec2 vll, mat3 vtbn) {
    v_out.uv = vuv;
    v_out.scene_pos = scene_p;
    v_out.tint = vtint;
    v_out.material_mask = blade_emit_mask;
    v_out.tbn = vtbn;
    v_out.light_levels = vll;
    v_out.vanilla_ao = 1.0;
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
        // Flower masks exist for the voxel volume / flower-head growth; the
        // flat plant itself shades as a small plant (small flowers) or a
        // tall plant lower half (tall-flower lowers), unchanged (the cutout
        // vertex shader applies the same remap table).
        if (v_out.material_mask >= uint(MATERIAL_FLOWER_FIRST)
            && v_out.material_mask <= uint(MATERIAL_FLOWER_LAST)) {
            v_out.material_mask = uint(MATERIAL_SMALL_PLANTS);
        } else if (v_out.material_mask >= uint(MATERIAL_FLOWER_TALL_FIRST)
                   && v_out.material_mask <= uint(MATERIAL_FLOWER_TALL_LAST)) {
            v_out.material_mask = uint(MATERIAL_TALL_PLANTS_LOWER);
        } else if (v_out.material_mask >= uint(MATERIAL_FLOWER_MAT_FIRST)
                   && v_out.material_mask <= uint(MATERIAL_FLOWER_MAT_LAST)) {
            v_out.material_mask = 14u; // their strong-SSS thin material
        } else if (v_out.material_mask
                   == uint(MATERIAL_FLOWER_FIREFLY_BUSH)) {
            v_out.material_mask = uint(MATERIAL_SMALL_PLANTS);
        }
        v_out.tbn = v_in[i].tbn;
        v_out.light_levels = v_in[i].light_levels;
        v_out.vanilla_ao = v_in[i].vanilla_ao;
#ifdef POM
        v_out.atlas_tile_coord = v_in[i].atlas_tile_coord;
        v_out.tangent_pos = v_in[i].tangent_pos;
        v_out.atlas_tile_offset = v_in[i].atlas_tile_offset;
        v_out.atlas_tile_scale = v_in[i].atlas_tile_scale;
#endif
        // Use the pipeline's clip position directly. Obsidian's vertex shader already
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
        // the base at distance and itself flickers.
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

// Build one tapered, curved, waving blade. `root` is the scene-space base (used
// to build/project the vertices); `world_root` is the PRECISE world-space base
// (used only to drive the wind, so it stays stable as the camera moves).
// `tip_tint`/`tip_amt`: optional colour wash on the blade TIP - the flower
// colour bleed onto a bloom's neighbouring blades. Zero below the top
// GRASS_FLOWER_BLEED_TOP fraction of the blade, then a linear 0 -> full ramp
// to the tip, so roots and mid-blade stay untouched. amt 0 = off.
void emit_blade(vec3 root, vec3 world_root, float bh, vec3 right, vec3 lean,
                vec4 src_tint, vec2 guv, vec2 gll, vec3 wind_blade,
                vec3 tip_tint, float tip_amt) {
    // Blade normal: mostly up, leaning along the width axis. Constant along
    // the blade, so built once outside the segment loop.
    vec3 nrm = normalize(vec3(right.z, 2.0, -right.x));
    mat3 btbn = mat3(right, normalize(cross(nrm, right)), nrm);

    for (int s = 0; s <= BLADE_SEGMENTS; ++s) {
        float tt = float(s) / float(BLADE_SEGMENTS);
        float curve = tt * tt; // bend more toward the tip

        vec3 wind = wind_blade * curve;
        vec3 center = root + vec3(0.0, bh * tt, 0.0) + lean * curve + wind;

        // Width tapers from base to tip (GRASS_THICKNESS_FALLOFF controls it)
        float w = GRASS_HALF_WIDTH * (1.0 - tt * GRASS_THICKNESS_FALLOFF);

        // Roots darker (height fade). src_tint is the vanilla per-vertex grass
        // tint (gl_Color) = the biome grass colour, which also tracks grass-fade
        // mods automatically - so block-top growers match the block they sit on.
        float heightfade = smoothstep(-0.35, 1.0, tt);
        vec4 col = src_tint;
        col.rgb *= heightfade;
        col.rgb = mix(
            col.rgb,
            tip_tint,
            tip_amt * linear_step(1.0 - GRASS_FLOWER_BLEED_TOP, 1.0, tt)
        );

        if (s == BLADE_SEGMENTS) {
            emit_blade_vertex(center, guv, col, gll, btbn); // taper to a tip
        } else {
            emit_blade_vertex(center - right * w, guv, col, gll, btbn);
            emit_blade_vertex(center + right * w, guv, col, gll, btbn);
        }
    }
    EndPrimitive();
}

#if defined SHADER_GRASS && defined GRASS_FLOWERS && defined COLORED_LIGHTS \
    && PROCEDURAL_GEOMETRY_MODE >= 2
// Map a position onto the block-top's [0,1]^2 f-space - the SAME relabel
// rules the blade placement uses (see the centroid mapping in main), so a
// stalk point can be tested against a sub-triangle's real f-space footprint.
vec2 grass_flower_top_map(vec3 p, vec3 bmin, vec3 n) {
    float xl = p.x - bmin.x;
    float yl = p.y - bmin.y;
    float zl = p.z - bmin.z;
    vec3 an = abs(n);
    float fx, fz;
    if (an.y > 0.5) {
        if (n.y > 0.0) {
            fx = zl;
            fz = xl;
        } else {
            fx = zl;
            fz = 1.0 - xl;
        }
    } else {
        fx = yl;
        if (an.x > 0.5) {
            fz = (n.x > 0.0) ? zl : (1.0 - zl);
        } else {
            fz = (n.z > 0.0) ? (1.0 - xl) : xl;
        }
    }
    return clamp(vec2(fx, fz), 0.0, 1.0);
}

float grass_flower_cross2(vec2 a, vec2 b) { return a.x * b.y - a.y * b.x; }

// The stalk-spot POSITIONS are baked per cell by grass_bushiness.csh (see
// bake_spot_radius there for the distribution: the inverse CDF of the dye
// falloff as an area density); this shader only tests its block's baked
// spots and recomputes their hashes.

// True if f-space point sp lies inside the triangle (e0, e1, e2), either
// winding. Inclusive edges: a point on a shared tessellation edge may emit
// from both neighbours for a frame (two identical quads), which is invisible;
// an exclusive test would instead drop the head there (a visible blink).
bool grass_flower_contains(vec2 e0, vec2 e1, vec2 e2, vec2 sp) {
    float c0 = grass_flower_cross2(e1 - e0, sp - e0);
    float c1 = grass_flower_cross2(e2 - e1, sp - e1);
    float c2 = grass_flower_cross2(e0 - e2, sp - e2);
    return (c0 >= 0.0 && c1 >= 0.0 && c2 >= 0.0)
        || (c0 <= 0.0 && c1 <= 0.0 && c2 <= 0.0);
}

// Stalk stem variant of emit_blade: ends in a PAIR (flat top, hidden behind
// the head disc) instead of tapering to a needle tip - the tip poked past the
// head and read as a floating spike - and keeps a minimum width the whole way
// up, slightly wider than a blade. A flower stalk, not a grass blade.
void emit_stem(vec3 root, vec3 world_root, float bh, vec3 right, vec3 lean,
               vec4 stint, vec2 guv, vec2 gll, vec3 wind_blade) {
    // Constant along the stem - built once outside the segment loop.
    vec3 nrm = normalize(vec3(right.z, 2.0, -right.x));
    mat3 btbn = mat3(right, normalize(cross(nrm, right)), nrm);

    for (int s = 0; s <= BLADE_SEGMENTS; ++s) {
        float tt = float(s) / float(BLADE_SEGMENTS);
        float curve = tt * tt;

        vec3 wind = wind_blade * curve;
        vec3 center = root + vec3(0.0, bh * tt, 0.0) + lean * curve + wind;

        float w = GRASS_HALF_WIDTH * 1.15
            * max(1.0 - tt * GRASS_THICKNESS_FALLOFF, 0.45);

        float heightfade = smoothstep(-0.35, 1.0, tt);
        vec4 col = stint;
        col.rgb *= heightfade;

        emit_blade_vertex(center - right * w, guv, col, gll, btbn);
        emit_blade_vertex(center + right * w, guv, col, gll, btbn);
    }
    EndPrimitive();
}

// FALLBACK bloom colour per flower family (sRGB) - used only when the flower's
// real sprite colours were not captured this frame (outside the shadow range);
// see update_flower_palette in voxelization.glsl for the capture.
vec3 flower_palette(uint family) {
    if (family == uint(MATERIAL_FLOWER_RED)) {
        return vec3(0.80, 0.10, 0.06);
    }
    if (family == uint(MATERIAL_FLOWER_YELLOW)) {
        return vec3(0.96, 0.80, 0.14);
    }
    if (family == uint(MATERIAL_FLOWER_BLUE)) {
        return vec3(0.28, 0.42, 0.92);
    }
    if (family == uint(MATERIAL_FLOWER_PURPLE)) {
        return vec3(0.78, 0.48, 0.90);
    }
    return vec3(0.96, 0.95, 0.90); // white
}

// Bloom tones for the flower at `flower_cell` (scene-space centre of the
// flower's block): the REAL sprite colours captured by the shadow pass
// (update_flower_palette). Brightest probe = petal tone; darkest VALID probe
// = ring tone - near-black sprite outline texels, near-flat captures and
// OFF-HUE candidates (a white flower's yellow eye) synthesize a shade of the
// petal colour instead. Family palette when uncaptured.
void grass_flower_tones(vec3 flower_cell, uint family, out vec3 light,
                        out vec3 dark) {
    light = flower_palette(family);
    dark = light * 0.62;
    vec3 fvp = scene_to_grass_tint_space(flower_cell);
    if (any(lessThan(fvp, vec3(0.0)))
        || any(greaterThanEqual(fvp, vec3(float(GRASS_TINT_SIZE))))) {
        return;
    }
    ivec3 fc = ivec3(fvp);
    ivec2 fb = ivec2(fc.x * 2, fc.z * 2);
    vec3 c00 = texelFetch(grass_tint_sampler, ivec3(fb.x, fb.y, fc.y), 0).rgb;
    vec3 c10
        = texelFetch(grass_tint_sampler, ivec3(fb.x + 1, fb.y, fc.y), 0).rgb;
    vec3 c01
        = texelFetch(grass_tint_sampler, ivec3(fb.x, fb.y + 1, fc.y), 0).rgb;
    vec3 c11 = texelFetch(grass_tint_sampler, ivec3(fb.x + 1, fb.y + 1, fc.y),
                          0).rgb;
    if (dot(c00 + c10 + c01 + c11, vec3(1.0)) <= 1e-3) {
        return;
    }

    const vec3 lw = vec3(0.2126, 0.7152, 0.0722);
    float l00 = dot(c00, lw);
    float l10 = dot(c10, lw);
    float l01 = dot(c01, lw);
    float l11 = dot(c11, lw);

    vec3 cmax = c00;
    float lmax = l00;
    if (l10 > lmax) { lmax = l10; cmax = c10; }
    if (l01 > lmax) { lmax = l01; cmax = c01; }
    if (l11 > lmax) { lmax = l11; cmax = c11; }

    vec3 cmin = c00;
    float lmin = l00;
    if (l10 < lmin) { lmin = l10; cmin = c10; }
    if (l01 < lmin) { lmin = l01; cmin = c01; }
    if (l11 < lmin) { lmin = l11; cmin = c11; }

    light = cmax;
    bool off_hue
        = dot(normalize(cmin + 1e-4), normalize(cmax + 1e-4)) < 0.80;
    dark = (max_of(cmin) < 0.15 || lmax - lmin < 0.06 || off_hue)
        ? light * 0.62
        : cmin;
}

// Multicolor ground mats (wildflowers, pink_petals): a MIX of bloom colours
// in one block, so each head takes ONE colour of a CURATED sprite-matched
// palette - a patch then shows the mat's full colour array head by head.
// Curated instead of captured: the multi-segment flowerbed models write the
// capture slots from every segment's quads, and those racing writes made the
// palette - and the heads - flicker each frame.
bool flower_is_multicolor(uint raw_id) {
    return raw_id >= uint(MATERIAL_FLOWER_MAT_FIRST)
        && raw_id <= uint(MATERIAL_FLOWER_MAT_LAST);
}

void grass_flower_tone_pick(uint raw_id, float pick,
                            out vec3 light, out vec3 dark) {
    int i = clamp(int(pick * 4.0), 0, 3);
    if (raw_id >= uint(MATERIAL_FLOWER_MAT_PETALS_FIRST)) {
        // pink_petals: shades of its pinks
        light = i == 0 ? vec3(0.97, 0.60, 0.76)
            : i == 1   ? vec3(0.99, 0.80, 0.88)
            : i == 2   ? vec3(0.93, 0.45, 0.66)
                       : vec3(0.99, 0.92, 0.95);
    } else {
        // wildflowers: golden through cream
        light = i == 0 ? vec3(0.98, 0.83, 0.18)
            : i == 1   ? vec3(0.99, 0.93, 0.45)
            : i == 2   ? vec3(0.95, 0.65, 0.12)
                       : vec3(0.99, 0.88, 0.62);
    }
    dark = light * 0.62;
}

// One camera-facing head quad at a stalk tip. Full screen-aligned billboard
// (vertical axis from the view direction, not world up) so the disc stays
// round from any pitch - the petal shape is radially symmetric, so billboard
// roll is invisible. Local quad coords ride v_out.uv ([-1,1]^2, pre-rotated
// per head by `rot` so every head's petal pattern sits at its own angle);
// tint.rgb is the petal tone and tint.a the ring tone packed 5:5:5 (see
// gbuffers_all_solid.fsh).
void emit_flower_head(vec3 center, vec3 right, uint family_mask,
                      vec4 head_tint, vec2 gll, float half_size, float rot) {
    // CAMERA-PLANE basis (the camera's own right/up rows), NOT a per-head
    // view-direction basis: a per-head basis re-orients as the camera
    // translates, visibly spinning the petal pattern while walking toward a
    // head. The camera rows are constant across a frame, so translation
    // cannot rotate the pattern; the disc is round, so its silhouette never
    // reveals the basis either way.
    mat3 vm = mat3(gbufferModelView);
    vec3 cam_right = vec3(vm[0].x, vm[1].x, vm[2].x);
    vec3 cam_up = vec3(vm[0].y, vm[1].y, vm[2].y);

    // Same lighting normal recipe as the blades (mostly-up), so heads shade
    // consistently with the canopy around them.
    vec3 nrm = normalize(vec3(right.z, 2.0, -right.x));
    mat3 htbn = mat3(right, normalize(cross(nrm, right)), nrm);

    float rc = cos(rot);
    float rs = sin(rot);
    mat2 rmat = mat2(rc, -rs, rs, rc);

    for (int i = 0; i < 4; ++i) {
        vec2 corner = vec2(
            (i & 1) == 0 ? -1.0 : 1.0,
            (i & 2) == 0 ? -1.0 : 1.0
        );
        vec3 p = center
            + (cam_right * corner.x + cam_up * corner.y) * half_size;

        v_out.uv = rmat * corner;
        v_out.scene_pos = p;
        v_out.tint = head_tint;
        v_out.material_mask = family_mask;
        v_out.tbn = htbn;
        v_out.light_levels = gll;
        v_out.vanilla_ao = 1.0;
        set_pom_defaults();
        gl_Position = grass_project(p);
        EmitVertex();
    }
    EndPrimitive();
}
#endif

void main() {
    vec3 p0 = v_in[0].scene_pos;
    vec3 p1 = v_in[1].scene_pos;
    vec3 p2 = v_in[2].scene_pos;

    bool make_grass = false;

#ifdef SHADER_GRASS
#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
#ifdef IRIS_FEATURE_TESSELLATION_SHADERS
    // The TCS already ran the full election for this patch (range + air-above
    // + grower election / FCFS claim, keyed on the block center) - its result
    // arrives per patch through the TES. Reading it here instead of
    // re-running the election removes ~tess-level^2 image/voxel reads per
    // face, and the two stages agree by construction: this is the literal
    // value that set this patch's tessellation levels. The mode-4 claim CAS
    // runs only in the TCS.
    make_grass = te_grass_elected[0] > 0.5;
#else
    // No tessellation support: no TCS ran, so elect here. Range + grower
    // election are keyed on the BLOCK center so every face of a block agrees.
    // The face arrives as plain triangles (one blade each - sparse grass).
    if (v_in[0].material_mask == uint(MATERIAL_GRASS_BLOCK)) {
        vec3 bc = v_in[0].block_center;
        bool in_range = dot(bc, bc) < (GRASS_RANGE * GRASS_RANGE);
#if defined COLORED_LIGHTS && PROCEDURAL_GEOMETRY_MODE >= 2
        // Modes 2+: this face grows iff it's the chosen grower of an exposed grass
        // block (lets grass survive Sodium culling the top face). In mode 4 (Race)
        // the claim CAS runs here since there is no TCS to run it.
        make_grass = in_range && grass_air_above(bc)
            && grass_is_grower(bc, v_in[0].tbn[2]);
#else
        // Mode 1 (Top Only): grass-block tops only (world normal up).
        make_grass = in_range && v_in[0].tbn[2].y > 0.9;
#endif
    }
#endif // IRIS_FEATURE_TESSELLATION_SHADERS
#endif // PROGRAM_GBUFFERS_TERRAIN_SOLID
#endif // SHADER_GRASS

#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
    // Solid terrain: ALWAYS keep the ground; grass is added on top. Pass make_grass
    // so the tessellated grower face keeps its tag for the deferred shadow-bias fix.
    emit_passthrough(make_grass);
    if (!make_grass) {
        return;
    }
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

    // Conservative view-frustum cull, BEFORE the per-blade texture reads
    // below. Sub-triangles reach this shader for every drawn face of a
    // section, including ones far outside the view (behind the camera, past
    // the screen edge); without this their blades are fully fetched, built
    // and emitted, then thrown away by the clipper. Every vertex this
    // invocation can emit lies within cull_r blocks of clump (bound below),
    // so if that sphere sits entirely outside one frustum plane, nothing
    // emitted here can produce a pixel - the skip is exact, not a heuristic.
    // Margins: per world-space unit, clip.x moves by at most P[0][0] (the
    // projection is symmetric, modelview rows orthonormal), clip.y by
    // P[1][1], clip.w by 1. Tested on the unjittered clip position; the TAA
    // jitter is sub-pixel and inside the slack term.
    {
        // Emission bound: blade/stalk height incl. the bushiness lift and
        // the 1.3x per-blade height jitter (0.65 * 1.3 = 0.845), rest lean
        // (rnd spans [-1, 3] per axis -> sqrt(2) * 3 * 0.35 * randomness)
        // plus the player push, wind at full storm amplitude, and the stalk
        // spot offset + head size + slack folded into the constant.
        float cull_r = 0.845 * BASE_GRASS_HEIGHT
                * max(SHORT_GRASS_HEIGHT, TALL_GRASS_HEIGHT)
            + 1.5 * GRASS_RANDOMNESS + 0.5 * GRASS_WAVY_STRENGTH + 2.6;
        vec4 cc = gbufferProjection * (gbufferModelView * vec4(clump, 1.0));
        float mx = cull_r * (abs(gbufferProjection[0].x) + 1.0);
        float my = cull_r * (abs(gbufferProjection[1].y) + 1.0);
        if (cc.w < -cull_r
            || cc.x - cc.w > mx || -cc.x - cc.w > mx
            || cc.y - cc.w > my || -cc.y - cc.w > my) {
            return; // the ground triangle is already emitted above
        }
    }

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
    // (worse far from spawn). Per-blade (not
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

    // Randomness from noisetex at the world position. This drives the REST
    // pose (lean + height): the texture's multi-scale content gives the
    // tufty look - hash-lattice replacements read either combed (per-block
    // cells) or shaggy (per-texel cells). The hash noise is used only for
    // the wind phase field, which has no rest-pose footprint.
    vec2 wxz = stable_world.xz;
    vec2 random_dir
        = 2.0 * (texture(noisetex, 0.75 * wxz).xy + texture(noisetex, 0.35 * wxz.yx).xy)
        - 1.0;

    // Grass-block tops: tall, thin blades (density comes from tessellation).
    float height = 0.65 * BASE_GRASS_HEIGHT;
#if defined GRASS_FLOWERS
    // Baked flower dye field at this blade: falloff (bloom proximity, same
    // shape as the grass heights) + the bloom's petal tone. Drives the
    // per-blade dye roll and gates the stalk-spot lookup. The glow-source
    // proximities ride the bushiness field's spare channels.
    float flower_dye_falloff = 0.0;
    vec3 flower_dye_color = vec3(0.0);
    float firefly_prox = 0.0;
    float amethyst_prox = 0.0;
#endif
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
        // The 4 bilinear corner cells are SHARED by the bushiness and flower
        // field reads: bounds-test each cell once (out of volume reads 0, as
        // before), then fetch both textures raw. uint(x) < N covers both
        // x < 0 and x >= N in one compare.
        ivec3 c00 = ivec3(i0.x,     vy, i0.y);
        ivec3 c10 = ivec3(i0.x + 1, vy, i0.y);
        ivec3 c01 = ivec3(i0.x,     vy, i0.y + 1);
        ivec3 c11 = ivec3(i0.x + 1, vy, i0.y + 1);
        bool in_y = uint(vy) < uint(VOXEL_VOLUME_SIZE);
        bool in_x0 = uint(i0.x) < uint(VOXEL_VOLUME_SIZE);
        bool in_x1 = uint(i0.x + 1) < uint(VOXEL_VOLUME_SIZE);
        bool in_z0 = uint(i0.y) < uint(VOXEL_VOLUME_SIZE);
        bool in_z1 = uint(i0.y + 1) < uint(VOXEL_VOLUME_SIZE);
        bool in00 = in_y && in_x0 && in_z0;
        bool in10 = in_y && in_x1 && in_z0;
        bool in01 = in_y && in_x0 && in_z1;
        bool in11 = in_y && in_x1 && in_z1;
        vec4 infl = mix(
            mix(in00 ? texelFetch(grass_bushiness_sampler, c00, 0) : vec4(0.0),
                in10 ? texelFetch(grass_bushiness_sampler, c10, 0) : vec4(0.0),
                f.x),
            mix(in01 ? texelFetch(grass_bushiness_sampler, c01, 0) : vec4(0.0),
                in11 ? texelFetch(grass_bushiness_sampler, c11, 0) : vec4(0.0),
                f.x),
            f.y);
        // The taller boost wins: a tall_grass spot grows ~2-block blades (TALL_GRASS_HEIGHT), a
        // short_grass spot a modest tuft (SHORT_GRASS_HEIGHT). The reach is fixed (bake side).
        float lift = max((SHORT_GRASS_HEIGHT - 1.0) * infl.x,
                         (TALL_GRASS_HEIGHT - 1.0) * infl.y);
        height *= 1.0 + lift;

#ifdef GRASS_FLOWERS
        // Flower dye field, same 4-corner read on the same decal layer. The
        // FALLOFF (how many blades take dye) blends bilinearly - a smooth
        // density ramp. The COLOUR does NOT: each blade PICKS one corner
        // cell's tone, weighted by that corner's share of the old numeric
        // blend, so where clusters of different colours touch, neighbouring
        // blades interleave the PURE cluster colours (the cherry-grove
        // dither discipline) and the washes coexist seamlessly - averaging
        // the tones instead drifted every seam toward the same muddy brown.
        vec4 d00 = in00 ? texelFetch(grass_flower_field_sampler, c00, 0)
                        : vec4(0.0);
        vec4 d10 = in10 ? texelFetch(grass_flower_field_sampler, c10, 0)
                        : vec4(0.0);
        vec4 d01 = in01 ? texelFetch(grass_flower_field_sampler, c01, 0)
                        : vec4(0.0);
        vec4 d11 = in11 ? texelFetch(grass_flower_field_sampler, c11, 0)
                        : vec4(0.0);
        vec4 dye = mix(mix(d00, d10, f.x), mix(d01, d11, f.x), f.y);
        flower_dye_falloff = dye.a;
        if (dye.a > 1e-3) {
            // Corner weights: bilinear weight x that cell's own falloff -
            // exactly each corner's contribution to the bilinear tone, so
            // the aggregate of picked colours matches the old blend
            vec4 w = vec4(
                (1.0 - f.x) * (1.0 - f.y) * d00.a,
                f.x * (1.0 - f.y) * d10.a,
                (1.0 - f.x) * f.y * d01.a,
                f.x * f.y * d11.a
            );
            // Stable quantized-world key (cherry-dither discipline), its own
            // stream - decorrelated from the dye roll's key below
            ivec2 pick_key = cameraPositionInt.xz * 64
                + ivec2(floor((clump.xz + cameraPositionFract.xz) * 64.0))
                + ivec2(97, 31);
            float pick = grass_hash2(pick_key).x * (w.x + w.y + w.z + w.w);
            vec4 c = pick < w.x ? d00
                : pick < w.x + w.y       ? d10
                : pick < w.x + w.y + w.z ? d01
                                         : d11;
            // Renormalize the picked cell's premultiplied tone alone -
            // full-strength pure colour, never a mix of cells
            flower_dye_color = c.a > 1e-3 ? c.rgb / c.a : vec3(0.0);
        }
        firefly_prox = infl.z;
        amethyst_prox = infl.w;
#endif
    }
#endif
    // Smooth LOD fade near GRASS_RANGE: blades shrink to nothing instead of
    // POPPING at the hard distance cutoff. This is the whole-patch pop-in - the
    // range test is 3D, so moving toward/away from a grassy ledge (even flying
    // straight up toward one) snaps a whole patch across the boundary. Height
    // reaches 0 by GRASS_RANGE, where detection culls anyway, so no visible step.
    height *= 1.0 - smoothstep(GRASS_RANGE * 0.8, GRASS_RANGE, length(clump));

    // Player-proximity outward bend: grass within ~1 block of the PLAYER
    // splays away - it parts as the player walks through, and (because the
    // tips lean outward) it hides the edge-on billboards when looking straight
    // down. Anchored on the player model's head, NOT the camera: clump is
    // camera-relative, and in third person the camera sits blocks away from
    // the player. relativeEyePosition is the head->camera offset (the same
    // convention handheld_lighting uses), so clump + relativeEyePosition
    // measures from the head - identical to clump in first person, where the
    // camera IS the head. Applied curve-weighted in emit_blade.
    vec3 from_player = clump + relativeEyePosition;
    float player_h = length(from_player.xz);
    float player_prox = smoothstep(1.0, 0.15, player_h)
        * smoothstep(3.0, 0.5, abs(from_player.y));
    vec2 player_dir = player_h > 1e-3 ? from_player.xz / player_h : vec2(0.0);
    vec3 player_push
        = vec3(player_dir.x, 0.0, player_dir.y) * player_prox * 0.35;

#if defined SHADER_GRASS && defined GRASS_FLOWERS && defined COLORED_LIGHTS \
    && PROCEDURAL_GEOMETRY_MODE >= 2
    // Flower stalks scatter RADIALLY around each bloom (pow-shaped radius,
    // the same falloff spirit as the bushiness heights), so a flower reads
    // as a cluster fading outward. The spots themselves are BAKED once per
    // cell by grass_bushiness.csh - re-deriving every nearby flower's whole
    // spot list per BLADE cratered FPS in dense fields - so the claim here
    // is one texel-pair fetch plus a few footprint tests. The sub-triangle
    // whose f-space footprint contains a spot grows the stalk in place of
    // its blade; hashes are recomputed from the packed flower coordinate +
    // k, identical to the values the old in-place derivation produced.
    bool grow_head = false;
    vec3 stalk_root = vec3(0.0);
    vec2 stalk_hash = vec2(0.0);
    uint stalk_family = 0u;
    uint stalk_raw = 0u;
    float stalk_pick = 0.0;
    vec3 stalk_flower_cell = vec3(0.0);
    if (flower_dye_falloff > 1e-3) {
        vec3 fbmin = bc - 0.5;
        vec2 e0 = grass_flower_top_map(p0, fbmin, v_in[0].tbn[2]);
        vec2 e1 = grass_flower_top_map(p1, fbmin, v_in[0].tbn[2]);
        vec2 e2 = grass_flower_top_map(p2, fbmin, v_in[0].tbn[2]);
        vec3 sp_vp = scene_to_voxel_space(bc + vec3(0.0, 1.0, 0.0));
        if (is_inside_voxel_volume(sp_vp)) {
            ivec3 sp_cell = ivec3(sp_vp);
            for (int t = 0; t < 2 && !grow_head; ++t) {
                uvec4 slots = texelFetch(
                    grass_flower_spots_sampler,
                    ivec3(sp_cell.x * 2 + t, sp_cell.y, sp_cell.z), 0
                );
                for (int c = 0; c < 4; ++c) {
                    uint s = slots[c];
                    if ((s & 0x80000000u) == 0u) {
                        break; // slots fill in order; first empty ends it
                    }
                    vec2 sp_local = vec2(
                        float((s >> 23) & 255u),
                        float((s >> 15) & 255u)
                    ) * (1.0 / 255.0);
                    // The footprint verts live in the top-relabelled
                    // f-space (fx = local z, fz = local x) - transpose
                    if (!grass_flower_contains(e0, e1, e2, sp_local.yx)) {
                        continue;
                    }
                    int k = int((s >> 9) & 63u);
                    uint fam_raw = 104u + ((s >> 4) & 31u);
                    int ndx = int(s & 15u);
                    vec3 n_bc = bc
                        + vec3(float(ndx / 3 - 1), 0.0, float(ndx % 3 - 1));
                    ivec2 ffk = cameraPositionInt.xz
                        + ivec2(floor(n_bc.xz + cameraPositionFract.xz));

                    grow_head = true;
                    stalk_root = vec3(fbmin.x + sp_local.x, bc.y + 0.5,
                                      fbmin.z + sp_local.y);
                    stalk_hash = grass_hash2(
                        ffk * 13 + ivec2(k * 17 + 5, k * 29 + 3));
                    stalk_pick = grass_hash2(
                        ffk * 19 + ivec2(k * 23 + 11, k * 41 + 7)).x;
                    // Tall lowers / ground blooms grow heads in their base
                    // family; the multicolor mats use fixed petal SHAPES
                    // (wildflowers daisy-like, petals a 4-petal blossom)
                    // with per-head colours from their curated palette
                    stalk_family = flower_base_family(fam_raw);
                    if (flower_is_multicolor(fam_raw)) {
                        stalk_family
                            = fam_raw >= uint(MATERIAL_FLOWER_MAT_PETALS_FIRST)
                            ? uint(MATERIAL_FLOWER_RED)
                            : uint(MATERIAL_FLOWER_WHITE);
                    }
                    stalk_raw = fam_raw;
                    stalk_flower_cell = n_bc + vec3(0.0, 1.0, 0.0);
                    break;
                }
            }
        }
    }
#endif

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

        // Wind evaluated ONCE per blade at its root, from the precise world
        // position (camera-relative coords here shimmer when the camera
        // moves); emit_blade's per-segment curve weight shapes the whip.
        // Per-blade jitters keep neighbours out of lockstep with the shared
        // field: phase from the continuous blade noise (+-1.2 rad), and
        // amplitude riding the same noise as blade height - taller blades
        // sway harder. gll.y (skylight) gates the wind indoors/in caves.
        vec2 phase_jitter = (rnd - 1.0) * 0.6;
        float amp_jitter = 0.75 + 0.5 * hgt;
        vec3 wind_blade
            = grass_wave(world_root, gll.y, phase_jitter, amp_jitter);

#if defined SHADER_GRASS && defined GRASS_FLOWERS && defined COLORED_LIGHTS \
    && PROCEDURAL_GEOMETRY_MODE >= 2
        if (grow_head) {
            // The claimed stalk grows at ITS OWN world-anchored spot (in
            // place of this sub-triangle's blade), and every parameter -
            // rest lean, height noise, wind - derives from that spot, not
            // from the drifting sub-triangle position. `height` (bushiness +
            // range fade) is the block's own smooth field, so reusing the
            // invocation's value cannot pop.
            vec3 s_root = stalk_root;
            vec3 s_world = s_root + (stable_world - clump);

            vec2 s_rnd = 2.0
                    * (texture(noisetex, 0.75 * s_world.xz).xy
                       + texture(noisetex, 0.35 * s_world.xz.yx).xy)
                - 1.0;
            float s_hgt = texture(noisetex, s_world.xz * 0.29 + 0.53).y;

            vec3 s_view = normalize_safe(s_root);
            vec3 s_raxis = cross(s_view, vec3(0.0, 1.0, 0.0));
            vec3 s_right = length(s_raxis) > 1e-3 ? normalize(s_raxis)
                                                  : vec3(1.0, 0.0, 0.0);

            // Straighter than a blade, still parted by the player
            vec3 s_from_player = s_root + relativeEyePosition;
            float s_ph = length(s_from_player.xz);
            float s_prox = smoothstep(1.0, 0.15, s_ph)
                * smoothstep(3.0, 0.5, abs(s_from_player.y));
            vec2 s_pdir
                = s_ph > 1e-3 ? s_from_player.xz / s_ph : vec2(0.0);
            vec3 s_lean = vec3(s_rnd.x, 0.0, s_rnd.y) * GRASS_RANDOMNESS
                    * 0.35 * 0.4
                + vec3(s_pdir.x, 0.0, s_pdir.y) * s_prox * 0.35;

            vec3 s_wind = grass_wave(s_world, gll.y, (s_rnd - 1.0) * 0.6,
                                     0.75 + 0.5 * s_hgt);

            float stalk_bh = height * (0.8 + 0.5 * s_hgt)
                * GRASS_FLOWER_STALK;

            // Head size: per-stalk jitter, following blade height so heads
            // LOD-fade with the field near GRASS_RANGE.
            float hs = GRASS_FLOWER_SIZE * (0.75 + 0.45 * stalk_hash.x)
                * clamp01(stalk_bh * 2.0);

            // Stem stops half a head-radius short of the head centre, so its
            // flat top always hides behind the disc.
            emit_stem(s_root, s_world, stalk_bh - hs * 0.5, s_right, s_lean,
                      src_tint, guv, gll, s_wind);

            // Head tones for the CLAIMED flower (spots can come from a
            // neighbouring block's bloom). Multicolor mats give each head
            // ONE whole sprite texel; everything else uses the light/dark
            // selection. Both ride the tint varying: rgb = petal, a = ring
            // packed 5:5:5. The packed value is SMALL on purpose - a large
            // cell index in tint.a picked up per-fragment interpolation
            // rounding, and single texels decoded the wrong cell and
            // flickered whenever the camera moved.
            vec3 petal_light;
            vec3 petal_dark;
            if (flower_is_multicolor(stalk_raw)) {
                grass_flower_tone_pick(stalk_raw, stalk_pick, petal_light,
                                       petal_dark);
            } else {
                grass_flower_tones(stalk_flower_cell, stalk_family,
                                   petal_light, petal_dark);
            }
            float head_jit = 0.85 + 0.30 * stalk_hash.y;
            petal_light *= head_jit;
            petal_dark *= head_jit;
            vec4 head_tint = vec4(
                petal_light,
                float((int(clamp01(petal_dark.r) * 31.0 + 0.5) << 10)
                      | (int(clamp01(petal_dark.g) * 31.0 + 0.5) << 5)
                      | int(clamp01(petal_dark.b) * 31.0 + 0.5))
            );
            float head_rot
                = fract(stalk_hash.x * 7.31 + stalk_hash.y * 3.17) * tau;
            vec3 head_center = s_root + vec3(0.0, stalk_bh, 0.0) + s_lean
                + s_wind + vec3(0.0, hs * 0.3, 0.0);
            emit_flower_head(head_center, s_right, stalk_family, head_tint,
                             gll, hs, head_rot);
        } else
#endif
        {
            // Colour bleed: BINARY per blade - a blade either takes the full
            // tip dye (ramped inside emit_blade) or none at all, and the
            // FRACTION of dyed blades follows the baked falloff, so the wash
            // thins out block by block away from the bloom instead of fading
            // per blade. Stable quantized-world key (the cherry-dither
            // discipline), so the pick never re-rolls under camera motion.
            vec3 tip_tint = vec3(0.0);
            float tip_amt = 0.0;
#if defined SHADER_GRASS && defined GRASS_FLOWERS && defined COLORED_LIGHTS \
    && PROCEDURAL_GEOMETRY_MODE >= 2
            if (flower_dye_falloff > 1e-3) {
                ivec2 dye_key = cameraPositionInt.xz * 64
                    + ivec2(floor((clump.xz + cameraPositionFract.xz) * 64.0))
                    + ivec2(53, 171);
                vec2 dh = grass_hash2(dye_key);
                if (dh.x < flower_dye_falloff) {
                    tip_tint = flower_dye_color;
                    tip_amt = GRASS_FLOWER_BLEED;
                    // Glow dyes override the field colour and switch the
                    // blade's mask so the deferred pass adds emission.
                    // Amethyst wins where both reach (constant purple). The
                    // glow density is the glow's OWN proximity roll
                    // (dh.x < *_prox), NOT the flower-driven outer gate: a
                    // flower beside the crystal raises flower_dye_falloff to
                    // full, so gating the glow COLOUR on a hard *_prox > 0
                    // threshold floods the glow's coarse box-shaped voxel
                    // support (a lone crystal writes falloff only to its 3x3
                    // cells) out to that hard edge - the visible SQUARE. Its
                    // own smooth falloff as the density thins it radially like
                    // an isolated crystal; with no flower present
                    // flower_dye_falloff == *_prox, so that case is unchanged.
                    if (amethyst_prox >= firefly_prox
                        && dh.x < amethyst_prox) {
                        blade_emit_mask = uint(MATERIAL_AMETHYST_BLADE);
                        tip_tint = vec3(0.72, 0.55, 0.95);
                    } else if (dh.x < firefly_prox) {
                        // Firefly blink: every dyed blade rides its own
                        // hashed phase and period, like scattered bugs. The
                        // dye AMOUNT pulses (a brief flash), so an unlit tip
                        // is simply normal grass - never a darkened amber.
                        blade_emit_mask = uint(MATERIAL_FIREFLY_BLADE);
                        float f_per = 2.8 + 1.7 * fract(dh.y * 9.77);
                        float f_b
                            = fract(frameTimeCounter / f_per + dh.y * 13.3);
                        float f_glow = smoothstep(0.0, 0.08, f_b)
                            * (1.0 - smoothstep(0.14, 0.25, f_b));
                        tip_tint = vec3(1.00, 0.62, 0.16);
                        tip_amt = GRASS_FLOWER_BLEED * f_glow;
                    }
                }
            }
#endif
            emit_blade(root, world_root, bh, right, lean, src_tint, guv, gll,
                       wind_blade, tip_tint, tip_amt);
            blade_emit_mask = uint(MATERIAL_SMALL_PLANTS);
        }
    }
#endif // PROGRAM_GBUFFERS_TERRAIN_SOLID
}
