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
    4 Race      - first drawn face to reach the pipeline claims the block (FCFS); default.
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
// ----- Mode 4 (Race / FCFS) -----
// The FIRST grass-block face to reach the terrain pipeline this frame CLAIMS the whole block and
// grows its blades; every other face of that block backs off. The claim is written and read within
// this SAME pass - decided and acted on immediately, no lag. Because the relabel plants every face's
// blades at the IDENTICAL top positions, it does not matter WHICH face wins, so the winner can change
// frame to frame with zero visible effect; and only DRAWN faces ever reach the pipeline, so a
// camera-culled face is never chosen. The claim cell holds, packed in an r32ui,
// (frame_stamp << 3) | winning_face_id (0..5).

// ABSOLUTE world-index claim cell (Iris split camera, exact far from spawn). Absolute - not
// camera-relative - so every face of one block hits the SAME texel; mod GRASS_MASK_SIZE, the claim's
// OWN size (256) DECOUPLED from the LPV, big enough that no two blocks within GRASS_RANGE alias.
ivec3 grass_mask_cell(vec3 scene_p) {
    ivec3 idx = cameraPositionInt + ivec3(floor(scene_p + cameraPositionFract));
    return ((idx % GRASS_MASK_SIZE) + GRASS_MASK_SIZE) % GRASS_MASK_SIZE;
}

// Per-frame stamp, 0 RESERVED so an uninitialised (zero) cell never reads as claimed-this-frame.
// The claim is same-frame, so the stamp's only job is telling "claimed this frame" from "stale".
uint grass_stamp_now() {
    return 1u + uint(frameCounter);
}

// Axis-unit face normal -> a 0..5 face id, packed into the claim cell.
uint grass_face_index(vec3 n) {
    if (n.y >  0.5) return 0u; // +y top
    if (n.y < -0.5) return 1u; // -y bottom
    if (n.x >  0.5) return 2u; // +x
    if (n.x < -0.5) return 3u; // -x
    if (n.z >  0.5) return 4u; // +z
    return 5u;                 // -z
}

// FCFS claim -> the block's winning face id this frame (6 = unclaimed). The first candidate face to
// reach the cell CAS-claims it (stale -> stamp|me); later faces see the claim and read the winner.
// The TCS reaches it first (earliest pipeline stage), so it drives which face TESSELLATES; the GS
// runs the same call but, finding the block already claimed, breaks before any atomic and just reads
// - a bare imageLoad there. Running the CAS in BOTH stages (not trusting a cross-stage read) makes it
// robust: a CAS always tests TRUE memory, so even if a coherent imageLoad lagged the TCS write, the
// CAS still resolves to the real winner. The cutout never grows blades, so its body is stubbed (no
// image) - it needs neither the image binding nor the extension.
uint grass_claim(ivec3 cell, uint my_face) {
#ifdef PROGRAM_GBUFFERS_TERRAIN_SOLID
    uint stamp = grass_stamp_now();
    uint cur = imageLoad(grass_claim_img, cell).x;
    // Bounded CAS: claim if the cell is stale (a new frame), else read who already claimed it. At
    // most 6 faces ever contend for a cell, so this settles in ~1-2 iterations; once a block is
    // claimed this frame the first check breaks before any atomic (so a confirming read is cheap).
    for (int i = 0; i < 8; ++i) {
        if ((cur >> 3) == stamp) {
            break; // already claimed this frame
        }
        uint prev = imageAtomicCompSwap(grass_claim_img, cell, cur, (stamp << 3) | my_face);
        if (prev == cur) {
            cur = (stamp << 3) | my_face; // we won the claim
            break;
        }
        cur = prev; // retry against the winner's value
    }
    return ((cur >> 3) == stamp) ? (cur & 7u) : 6u; // winner this frame, or 6 = unclaimed
#else
    return 6u; // cutout: never claims (no blade growing)
#endif
}
#elif PROCEDURAL_GEOMETRY_MODE >= 3
// ----- Mode 3 (Mask, shadow pass) -----
// True if this grass-block face toward `dir` was meshed in the shadow pass (it stamped the air
// cell it faces). Unlike the deduced neighbour read it isn't blind to fully-enclosed blocks;
// unlike mode 4 (Race) it still can't see the camera's per-section direction culling. See CLAUDE.md.
bool grass_face_rendered(vec3 block_center, vec3 dir) {
    vec3 vp = scene_to_voxel_space(block_center + dir);
    if (!is_inside_voxel_volume(vp)) {
        return false;
    }
    return texelFetch(grass_face_sampler, ivec3(vp), 0).x != 0u;
}
#endif

#if PROCEDURAL_GEOMETRY_MODE <= 3
// ----- Modes 2 (Deduced) / 3 (Mask) election -----
// Top face must be this many blocks above the camera before we grow from a side instead of the
// top (these modes can't see camera-direction culling, so they approximate with height +
// most-camera-facing). Mode 4 (Race) instead lets the first drawn face claim the block.
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

// Does THIS face grow the grass? Exactly one face of a block does - the elected grower (modes 2/3)
// or the FCFS claim winner (mode 4) - so there's no double draw. Mode 1 (Top Only) and the
// no-Colored-Lights fallback grow on grass-block tops only.
bool grass_is_grower(vec3 block_center, vec3 face_normal) {
#if defined COLORED_LIGHTS && PROCEDURAL_GEOMETRY_MODE >= 2
    if (!is_inside_voxel_volume(scene_to_voxel_space(block_center))) {
        return face_normal.y > 0.9; // outside voxel range: top only
    }
#if PROCEDURAL_GEOMETRY_MODE >= 4
    // Mode 4 (Race / FCFS): this face grows iff it wins (TCS claim) / won (GS read) the block's race.
    uint my_face = grass_face_index(face_normal);
    return grass_claim(grass_mask_cell(block_center), my_face) == my_face;
#else
    return dot(face_normal, grass_grower_dir(block_center)) > 0.5;
#endif
#else
    return face_normal.y > 0.9; // Top Only (mode 1), or no Colored Lights
#endif
}

#endif // INCLUDE_MISC_GRASS_ELECTION
