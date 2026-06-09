#if !defined INCLUDE_MISC_GRASS_ELECTION
#define INCLUDE_MISC_GRASS_ELECTION

/*
--------------------------------------------------------------------------------

  Tachyon Shader (a fork of SixthSurge's Photon Shaders)

  include/misc/grass_election.glsl:
  Elects the ONE grass-block face that grows blades, shared by the solid terrain
  TCS and GS so they agree. PROCEDURAL_GEOMETRY_MODE selects the method:
    1 Top Only  - tops only, no election (this file's helpers aren't even compiled).
    2 Deduced   - neighbour voxel read.
    3 Mask      - shadow-pass face mask.
    4 Camera    - camera-pass face mask (default).
  Modes 2+ need COLORED_LIGHTS (the voxel volume) + voxelization.glsl included, and
  the includer must declare the samplers each mode uses. See CLAUDE.md gotcha #9.

--------------------------------------------------------------------------------
*/

// Mode 1 (Top Only) elects nothing - skip the whole election apparatus.
#if defined COLORED_LIGHTS && PROCEDURAL_GEOMETRY_MODE >= 2

// Raw voxel id at a scene position. 0 = air, outside the volume, or a fully-enclosed
// block (the buffer can't tell those apart - see CLAUDE.md).
uint grass_voxel_at(vec3 scene_p) {
    vec3 vp = scene_to_voxel_space(scene_p);
    if (!is_inside_voxel_volume(vp)) {
        return 0u;
    }
    return texelFetch(voxel_sampler, ivec3(vp), 0).x;
}

// Opaque block = id in [1, 127]. 0 (air/enclosed) and >= 128 (transparent) see-through.
bool grass_voxel_is_solid(uint v) {
    return v != 0u && v < 128u;
}

// True if the block above is open (so the top is a real grass surface).
bool grass_air_above(vec3 block_center) {
    return !grass_voxel_is_solid(grass_voxel_at(block_center + vec3(0.0, 1.0, 0.0)));
}

#if PROCEDURAL_GEOMETRY_MODE >= 4
// ----- Mode 4 (Camera) -----
// ABSOLUTE world-index texel for the camera face mask - the addressing that makes the mask
// frame-stable. The mask is WRITTEN one frame and READ the next, so the cell for a block MUST
// be identical on both frames despite camera motion. A camera-relative cell (scene_to_voxel_space,
// or anything with fract(cameraPosition)) shifts by a texel every time floor(cameraPosition)
// ticks - every block you WALK across and every head-bob in Y - so the read missed the write and
// EVERY blade blinked off for that whole frame. The integer WORLD block index never moves.
// Computed via the Iris split camera (exact far from spawn), mod GRASS_MASK_SIZE - the mask's
// OWN size, DECOUPLED from the LPV voxel volume and big enough (256) that no two blocks within
// GRASS_RANGE ever collide (2 * max range 100 < 256), so NO aliasing at any range, no fallback.
ivec3 grass_mask_cell(vec3 scene_p) {
    ivec3 idx = cameraPositionInt + ivec3(floor(scene_p + cameraPositionFract));
    return ((idx % GRASS_MASK_SIZE) + GRASS_MASK_SIZE) % GRASS_MASK_SIZE;
}

// Per-frame stamp value in [1, 65520]. r16ui (cycles every 65520 frames, ~18 min) with 0 RESERVED
// for "never written" so an uninitialised texel can't read as drawn. 65520 = 720720/11 divides
// Iris's frameCounter wrap period (720720) EXACTLY, so the stamp cycle stays aligned with the wrap
// - 65535/65536 would instead mis-age every block for one frame at each wrap (~3.3h). The GS write
// and this read MUST use this same value.
uint grass_stamp_now() {
    return 1u + uint(frameCounter % 65520);
}

// PER-BLOCK 6-bit FACE BITMASK, DOUBLE-BUFFERED (grass_face_img_a/b, ping-ponged by frame parity):
// an r32ui per cell, high bits = frame stamp, low 6 = which of THIS block's faces the camera drew.
// The GS writes a block's OWN cell (grass_mask_cell(bc)) via grass_stamp_face - and NOBODY else
// writes that cell - so the read is UNAMBIGUOUS, unlike the air cell a face points into (which SIX
// blocks' faces share). The election reads the buffer NOT written this frame (a clean cross-frame
// hand-off; reading the buffer being atomically written THIS pass returned unstable values and
// flickered grass above eye level). Sees Sodium's per-section + per-face camera-direction culling,
// at a 1-frame lag. See CLAUDE.md (VERY IMPORTANT election).
const uint GRASS_FACE_PX  = 1u << 0; // +x
const uint GRASS_FACE_NX  = 1u << 1; // -x
const uint GRASS_FACE_TOP = 1u << 2; // +y
const uint GRASS_FACE_NY  = 1u << 3; // -y (bottom; elects on overhangs viewed from below)
const uint GRASS_FACE_PZ  = 1u << 4; // +z
const uint GRASS_FACE_NZ  = 1u << 5; // -z

// Axis-unit normal -> its face bit (used by the GS write).
uint grass_face_bit(vec3 dir) {
    if (dir.y >  0.5) return GRASS_FACE_TOP;
    if (dir.y < -0.5) return GRASS_FACE_NY;
    if (dir.x >  0.5) return GRASS_FACE_PX;
    if (dir.x < -0.5) return GRASS_FACE_NX;
    if (dir.z >  0.5) return GRASS_FACE_PZ;
    return GRASS_FACE_NZ;
}

// Bitmask of THIS block's camera-drawn faces (0 if its cell is stale / never written). drawn =
// stamp is this frame or last (cyclic age <= 1; 0 = never written, RESERVED).
uint grass_block_faces(vec3 block_center) {
    ivec3 cell = grass_mask_cell(block_center);
    // DOUBLE-BUFFER read: the GS writes A on even frames, B on odd - so read the OTHER one, the
    // buffer NOT being written this frame. A clean cross-frame read (last frame's completed buffer)
    // instead of reading the buffer the same pass is atomically writing (that flickered).
    uint v = ((frameCounter & 1) == 0) ? texelFetch(grass_face_sampler_b, cell, 0).x
                                       : texelFetch(grass_face_sampler_a, cell, 0).x;
    uint stamp = v >> 6;
    if (stamp == 0u || (grass_stamp_now() + 65520u - stamp) % 65520u > 1u) {
        return 0u;
    }
    return v & 0x3Fu;
}
#elif PROCEDURAL_GEOMETRY_MODE >= 3
// ----- Mode 3 (Mask, shadow pass) -----
// True if this grass-block face toward `dir` was meshed in the shadow pass (it stamped the air
// cell it faces). Unlike the deduced neighbour read it isn't blind to fully-enclosed blocks;
// unlike the camera mask it still can't see the camera's direction culling. See CLAUDE.md.
bool grass_face_rendered(vec3 block_center, vec3 dir) {
    vec3 vp = scene_to_voxel_space(block_center + dir);
    if (!is_inside_voxel_volume(vp)) {
        return false;
    }
    return texelFetch(grass_face_sampler, ivec3(vp), 0).x != 0u;
}
#endif

#if PROCEDURAL_GEOMETRY_MODE >= 4
// Mode 4 election. Reads THIS block's per-block face bitmask (grass_block_faces) - every face is
// UNAMBIGUOUS (each block owns its mask cell; no 6-way air-cell sharing). TOP if its bit is set
// (preferred grower), else the MOST camera-facing DRAWN side. Most-camera-facing - NOT first in a
// fixed order - is what keeps the side grower STABLE. A cull-zone block (top culled) is drawn by the
// camera EVERY frame on its dominant (high-dot) side, but its grazing/marginal sides flicker in and
// out of the drawn set frame-to-frame (TAA jitters the projection -> Sodium's per-section/back-face
// cull margin wobbles). Fixed order would pick a flickering marginal side whenever it sorts before
// the dominant one -> the grower SWAPS sides every few frames (the positional jitter). Picking max
// dot makes the dominant side - drawn every frame - always win, so marginal flicker can't change the
// result. Strict > with fixed iteration order breaks the 45-degree corner tie deterministically
// (first wins), so a static camera never churns and rotation switches once at the symmetric angle.
// (The "most-camera-facing churns" warning was the AIR-CELL era: its candidate set had fluctuating
// FALSE POSITIVES; the clean per-block bitmask has none, so the dominant side is rock-stable.)
// y FAST-PATH first: a top below the camera is always drawn. See CLAUDE.md (VERY IMPORTANT election).
vec3 grass_grower_dir(vec3 block_center) {
    // Fast path: top face below the camera -> always camera-drawn -> top, no mask read.
    if (block_center.y + 0.5 < 0.0) {
        return vec3(0.0, 1.0, 0.0);
    }
    uint faces = grass_block_faces(block_center); // exactly which of THIS block's faces were drawn
    if ((faces & GRASS_FACE_TOP) != 0u) {
        return vec3(0.0, 1.0, 0.0); // TOP - preferred grower (a rendered top must win)
    }
    // Else the MOST camera-facing drawn side OR BOTTOM (stable against marginal-side flicker; see
    // above). The bottom (-Y) is a candidate too: an overhanging grass block viewed from below has
    // its top culled and its bottom drawn, so the bottom is the only face the camera amplifies there.
    // It only ever enters the drawn set when the block actually overhangs air, so a normal grass
    // block (enclosed bottom) never elects it.
    const vec3 dirs[5] = vec3[5](
        vec3(1.0, 0.0, 0.0), vec3(-1.0, 0.0, 0.0),
        vec3(0.0, 0.0, 1.0), vec3(0.0, 0.0, -1.0),
        vec3(0.0, -1.0, 0.0)
    );
    const uint bits[5] = uint[5](GRASS_FACE_PX, GRASS_FACE_NX, GRASS_FACE_PZ, GRASS_FACE_NZ, GRASS_FACE_NY);
    vec3 best = vec3(0.0, 1.0, 0.0); // nothing drawn -> top (grows nothing; no camera geometry)
    float best_dot = 0.0;            // best_dot starts at 0 -> only camera-facing faces qualify
    for (int i = 0; i < 5; ++i) {
        if ((faces & bits[i]) == 0u) {
            continue;
        }
        float facing = dot(dirs[i], -block_center); // distance cancels (same block) -> ~cos(angle)
        if (facing > best_dot) {     // strict > -> first in fixed order wins exact ties (45 deg)
            best_dot = facing;
            best = dirs[i];
        }
    }
    return best;
}
#else
// ----- Modes 2 (Deduced) / 3 (Mask) election -----
// Top face must be this many blocks above the camera before we grow from a side instead of the
// top (these modes can't see camera-direction culling, so they approximate with height +
// most-camera-facing). Mode 4 has the real camera mask and uses neither knob.
#define GRASS_SIDE_GROWER_HEIGHT 1.0
vec3 grass_grower_dir(vec3 block_center) {
    // 1. top
    if (block_center.y + 0.5 < GRASS_SIDE_GROWER_HEIGHT) {
        return vec3(0.0, 1.0, 0.0);
    }
    // 2. closest (most camera-facing) exposed side, if any; else top. No bottom step.
    const vec3 dirs[4] = vec3[4](
        vec3(1.0, 0.0, 0.0), vec3(-1.0, 0.0, 0.0),
        vec3(0.0, 0.0, 1.0), vec3(0.0, 0.0, -1.0)
    );
    float best = -1e9;
    vec3 best_dir = vec3(0.0, 1.0, 0.0); // top if no exposed side
    for (int i = 0; i < 4; ++i) {
        vec3 d = dirs[i];
#if PROCEDURAL_GEOMETRY_MODE >= 3
        if (!grass_face_rendered(block_center, d)) {
            continue; // shadow-pass mask: face not meshed -> not a real exposed side
        }
#else
        if (grass_voxel_is_solid(grass_voxel_at(block_center + d))) {
            continue; // neighbour read: a block is against this side -> not exposed
        }
#endif
        float s = dot(d, -block_center);
        if (s > best) {
            best = s;
            best_dir = d;
        }
    }
    return best_dir;
}
#endif

#endif // COLORED_LIGHTS && PROCEDURAL_GEOMETRY_MODE >= 2

// Does THIS face grow the grass? Exactly one face does (the elected one) - no double draw.
// Mode 1 (Top Only) and the no-Colored-Lights fallback grow on grass-block tops only.
bool grass_is_grower(vec3 block_center, vec3 face_normal) {
#if defined COLORED_LIGHTS && PROCEDURAL_GEOMETRY_MODE >= 2
    if (!is_inside_voxel_volume(scene_to_voxel_space(block_center))) {
        return face_normal.y > 0.9; // outside voxel range: top only
    }
    return dot(face_normal, grass_grower_dir(block_center)) > 0.5;
#else
    return face_normal.y > 0.9; // Top Only (mode 1), or no Colored Lights
#endif
}

#endif // INCLUDE_MISC_GRASS_ELECTION
