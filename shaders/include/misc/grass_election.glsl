#if !defined INCLUDE_MISC_GRASS_ELECTION
#define INCLUDE_MISC_GRASS_ELECTION

/*
--------------------------------------------------------------------------------

  Tachyon Shader (a fork of SixthSurge's Photon Shaders)

  include/misc/grass_election.glsl:
  Shader Grass. Single source of truth for the "which face grows the grass"
  election, shared by the SOLID terrain TCS and GS so they can never disagree.

  Sodium culls a chunk section's face-direction buckets per camera position; the
  grass-block TOP faces vanish whenever the camera is at/below the section, which
  used to make whole sections of field grass pop out. To survive this, each
  visible face of a grass block independently consults the persistent voxel
  buffer (written in the shadow pass) and elects ONE grower face - the most
  camera-facing face that is actually exposed (so Sodium submits it). Every
  submitted face computes the same answer, so exactly one grows: no inter-stage
  communication, no double density.

  The includer MUST have already declared `voxel_sampler` and included
  /include/lighting/lpv/voxelization.glsl (this only happens with COLORED_LIGHTS,
  which is what builds the voxel volume).

--------------------------------------------------------------------------------
*/

#ifdef COLORED_LIGHTS

// Raw voxel material id at a scene-space position (0 = air / outside volume).
uint grass_voxel_at(vec3 scene_p) {
    vec3 vp = scene_to_voxel_space(scene_p);
    if (!is_inside_voxel_volume(vp)) {
        return 0u;
    }
    return texelFetch(voxel_sampler, ivec3(vp), 0).x;
}

// A full opaque block is voxelized at grid corners as its material id in
// [1, 127]. Air is 0; transparent/non-corner entries are id + 128 (>= 128) and
// are treated as see-through (a face against them is still submitted by Sodium).
bool grass_voxel_is_solid(uint v) {
    return v != 0u && v < 128u;
}

// True if the block directly above `block_center` is open (so the top is a real
// grass surface, not buried).
bool grass_air_above(vec3 block_center) {
    return !grass_voxel_is_solid(grass_voxel_at(block_center + vec3(0.0, 1.0, 0.0)));
}

// Elect the grower face - the simple rule that worked, and nothing more:
//   * camera ABOVE the block's top plane -> grow from the TOP (the grass surface)
//   * camera at/below the top            -> grow from the horizontal SIDE you face
//                                           most, skipping any side that has a
//                                           block right beside it (occluded:
//                                           Sodium won't submit an interior face)
//
// block_center is camera-relative with the camera at the scene origin, so the top
// plane (block_center.y + 0.5) is above the camera exactly when block_center.y <
// -0.5. Below that, dir_to_cam = -block_center and we take the most camera-facing
// of the four EXPOSED horizontal sides.
//
// DO NOT add a "predict Sodium's per-face submission" face-plane test, the bottom
// face, or +Y in the side fallback. Each of those, when tried, made the elector
// pick faces you weren't looking at and flip between them, and reintroduced pop-in.
// The only voxel read that belongs here is the occlusion (block-beside) skip. If it
// ever still pops, the back-pocket fix is to grow from EVERY submitted face (see
// CLAUDE.md), not to make this prediction cleverer.
vec3 grass_grower_dir(vec3 block_center) {
    if (block_center.y < -0.5) {
        return vec3(0.0, 1.0, 0.0); // camera above the top -> top face
    }

    const vec3 dirs[4] = vec3[4](
        vec3(1.0, 0.0, 0.0), vec3(-1.0, 0.0, 0.0),
        vec3(0.0, 0.0, 1.0), vec3(0.0, 0.0, -1.0)
    );
    float best = -1e9;
    vec3 best_dir = vec3(0.0, 0.0, block_center.z > 0.0 ? -1.0 : 1.0);
    for (int i = 0; i < 4; ++i) {
        vec3 d = dirs[i];
        if (grass_voxel_is_solid(grass_voxel_at(block_center + d))) {
            continue; // block directly beside this face -> occluded, skip it
        }
        float s = dot(d, -block_center); // most camera-facing exposed side
        if (s > best) {
            best = s;
            best_dir = d;
        }
    }
    return best_dir;
}

#endif // COLORED_LIGHTS

// Should THIS face (world geometric normal `face_normal`) grow the block's grass?
// Falls back to top-only when the omnidirectional fix is disabled or the block is
// outside the voxel volume (graceful degrade to the original behaviour).
bool grass_is_grower(vec3 block_center, vec3 face_normal) {
#if defined COLORED_LIGHTS && defined GRASS_FIX_FACE_CULL
    if (!is_inside_voxel_volume(scene_to_voxel_space(block_center))) {
        return face_normal.y > 0.9; // outside voxel range: top only
    }
    return dot(face_normal, grass_grower_dir(block_center)) > 0.5;
#else
    return face_normal.y > 0.9; // legacy: grass-block tops only
#endif
}

#endif // INCLUDE_MISC_GRASS_ELECTION
