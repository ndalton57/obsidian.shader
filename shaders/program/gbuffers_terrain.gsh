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
#include "/include/lighting/lpv/voxelization.glsl"

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
    set_pom_defaults();
    gl_Position = grass_project(scene_p);
    EmitVertex();
}

void emit_passthrough() {
    for (int i = 0; i < 3; ++i) {
        v_out.uv = v_in[i].uv;
        v_out.scene_pos = v_in[i].scene_pos;
        v_out.tint = v_in[i].tint;
        v_out.material_mask = v_in[i].material_mask;
#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
        // The grass_block tag exists only so we can find tops in this GS; shade
        // the block's own geometry as default terrain (matches stock Tachyon).
        if (v_out.material_mask == uint(MATERIAL_GRASS_BLOCK)) {
            v_out.material_mask = 0u;
        }
#endif
        v_out.tbn = v_in[i].tbn;
        v_out.light_levels = v_in[i].light_levels;
        v_out.vanilla_ao = v_in[i].vanilla_ao;
#ifdef POM
        v_out.atlas_tile_coord = v_in[i].atlas_tile_coord;
        v_out.tangent_pos = v_in[i].tangent_pos;
        v_out.atlas_tile_offset = v_in[i].atlas_tile_offset;
        v_out.atlas_tile_scale = v_in[i].atlas_tile_scale;
#endif
        // Use the pipeline's clip position directly. Tachyon's vertex shader
        // already outputs clip space (so there's no need to re-project from
        // world space), and grass-block tops are planar, so this is
        // correct even for the tessellated sub-triangles. Crucially it MATCHES
        // the (untessellated) shadow pass bit-for-bit - re-projecting via
        // grass_project() here recomputed depth with slightly different rounding,
        // which showed up as flickering shadow acne ("hash grid") as the sun
        // moved, even with SHADER_GRASS off.
        gl_Position = gl_in[i].gl_Position;
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

        // Roots darker (height fade)
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
    // Grow grass on grass-block tops (blockID 85, world normal up, in
    // range). tbn[2] is the world-space geometric normal from the vertex shader.
    if (v_in[0].material_mask == uint(MATERIAL_GRASS_BLOCK)
        && v_in[0].tbn[2].y > 0.9) {
        vec3 c = (p0 + p1 + p2) * (1.0 / 3.0);
        make_grass = dot(c, c) < (GRASS_RANGE * GRASS_RANGE);
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
    // Solid terrain: ALWAYS keep the ground; grass is added on top.
    emit_passthrough();
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
    emit_passthrough(); // keep (non-grass, or grass not on a grass block)
    return;
#endif

    // ---- Generate grass blades ----

    vec3 tri_center = (p0 + p1 + p2) * (1.0 / 3.0);
    float min_y = min(p0.y, min(p1.y, p2.y));
    float max_y = max(p0.y, max(p1.y, p2.y));
    vec3 clump = vec3(tri_center.x, min_y, tri_center.z); // planted on the ground

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
    vec2 pw = stable_world.xz;       // world xz of this blade
    vec2 blk = floor(pw);            // its block
    float bushiness = 0.0;
    for (int dx = -1; dx <= 1; ++dx) {
        for (int dz = -1; dz <= 1; ++dz) {
            vec2 nb = blk + 0.5 + vec2(float(dx), float(dz)); // neighbour center
            float sg = read_short_grass(
                clump + vec3(nb.x - pw.x, 0.6, nb.y - pw.y));
            float falloff = 1.0 - smoothstep(0.5, 1.8, length(pw - nb));
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
