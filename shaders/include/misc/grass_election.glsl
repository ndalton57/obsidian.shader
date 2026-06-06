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

// True if the camera DREW this grass-block face last frame (the GS stamped it with the current
// stamp; drawn = stamp is this frame or last, cyclic age <= 1; 0 = never). The only test that
// sees Sodium's per-section CAMERA-direction culling, at the cost of a 1-frame lag. See CLAUDE.md.
bool grass_face_rendered(vec3 block_center, vec3 dir) {
    uint stamp = texelFetch(grass_face_sampler, grass_mask_cell(block_center + dir), 0).x;
    return stamp != 0u && (grass_stamp_now() + 65520u - stamp) % 65520u <= 1u;
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
// Mode 4 election. The camera mask IS what the camera drew, so no y APPROXIMATION - but a y
// FAST-PATH: a top below the camera is always drawn, so skip the mask and grow from the TOP.
// Otherwise: TOP if drawn, else the FIRST drawn side in a FIXED order (not "most camera-facing"
// - that flipped sides every few degrees of rotation and, with the 1-frame lag, read as
// flicker). See CLAUDE.md gotcha #9.
vec3 grass_grower_dir(vec3 block_center) {
    // Fast path: top face below the camera -> always camera-drawn -> top, no mask reads.
    if (block_center.y + 0.5 < 0.0) {
        return vec3(0.0, 1.0, 0.0);
    }
    if (grass_face_rendered(block_center, vec3(0.0, 1.0, 0.0))) {
        return vec3(0.0, 1.0, 0.0);
    }
    const vec3 dirs[4] = vec3[4](
        vec3(1.0, 0.0, 0.0), vec3(-1.0, 0.0, 0.0),
        vec3(0.0, 0.0, 1.0), vec3(0.0, 0.0, -1.0)
    );
    for (int i = 0; i < 4; ++i) {
        if (grass_face_rendered(block_center, dirs[i])) {
            return dirs[i]; // first drawn side, fixed priority
        }
    }
    return vec3(0.0, 1.0, 0.0); // nothing drawn -> top (grows nothing if the top isn't drawn)
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
