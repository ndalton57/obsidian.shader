#if !defined INCLUDE_MISC_GRASS_ELECTION
#define INCLUDE_MISC_GRASS_ELECTION

/*
--------------------------------------------------------------------------------

  Tachyon Shader (a fork of SixthSurge's Photon Shaders)

  include/misc/grass_election.glsl:
  Elects the ONE grass-block face that grows blades, shared by the solid terrain
  TCS and GS so they agree. The includer must have declared `voxel_sampler` and
  included voxelization.glsl (COLORED_LIGHTS only). See CLAUDE.md "Shader Grass"
  for the election rules and the voxel-buffer blind spot.

--------------------------------------------------------------------------------
*/

#ifdef COLORED_LIGHTS

// Raw voxel id at a scene position. 0 = air, outside the volume, or a fully-enclosed
// block (the buffer can't tell those apart - see CLAUDE.md).
uint grass_voxel_at(vec3 scene_p) {
    vec3 vp = scene_to_voxel_space(scene_p);
    if (!is_inside_voxel_volume(vp)) {
        return 0u;
    }
    return texelFetch(voxel_sampler, ivec3(vp), 0).x;
}

// Opaque block = id in [1, 127]. 0 (air/enclosed) and >= 128 (transparent) are
// treated as see-through.
bool grass_voxel_is_solid(uint v) {
    return v != 0u && v < 128u;
}

// True if the block above is open (so the top is a real grass surface).
bool grass_air_above(vec3 block_center) {
    return !grass_voxel_is_solid(grass_voxel_at(block_center + vec3(0.0, 1.0, 0.0)));
}

// Top face must be this many blocks above the camera before we stop growing from the
// top (top face = block_center.y + 0.5, camera-relative). Tuning knob - see CLAUDE.md.
#define GRASS_SIDE_GROWER_HEIGHT 1.0

// Elect the grower face (top face = block_center.y + 0.5 above the camera):
//   < GRASS_SIDE_GROWER_HEIGHT          -> TOP
//   >= and a horizontal side is exposed -> closest (most camera-facing) exposed side
//   >= and all sides covered            -> TOP
// No bottom step (the buffer can't tell buried dirt from real air); see CLAUDE.md.
vec3 grass_grower_dir(vec3 block_center) {
    // 1. top
    if (block_center.y + 0.5 < GRASS_SIDE_GROWER_HEIGHT) {
        return vec3(0.0, 1.0, 0.0);
    }

    // 2a. closest exposed horizontal side, if any
    const vec3 dirs[4] = vec3[4](
        vec3(1.0, 0.0, 0.0), vec3(-1.0, 0.0, 0.0),
        vec3(0.0, 0.0, 1.0), vec3(0.0, 0.0, -1.0)
    );
    float best = -1e9;
    vec3 best_dir = vec3(0.0, 1.0, 0.0);
    bool found_side = false;
    for (int i = 0; i < 4; ++i) {
        vec3 d = dirs[i];
        if (grass_voxel_is_solid(grass_voxel_at(block_center + d))) {
            continue; // a block sits against this side -> not exposed
        }
        float s = dot(d, -block_center); // most camera-facing
        if (s > best) {
            best = s;
            best_dir = d;
        }
        found_side = true;
    }
    if (found_side) {
        return best_dir;
    }

    // 2b. no exposed side -> top (no bottom step; see CLAUDE.md)
    return vec3(0.0, 1.0, 0.0);
}

#endif // COLORED_LIGHTS

// Does THIS face grow the grass? Exactly one face does (the elected one) - no double
// draw. Degrades to top-only outside the voxel volume / with the fix off.
bool grass_is_grower(vec3 block_center, vec3 face_normal) {
#if defined COLORED_LIGHTS && defined GRASS_FIX_FACE_CULL
    if (!is_inside_voxel_volume(scene_to_voxel_space(block_center))) {
        return face_normal.y > 0.9; // outside voxel range: top only
    }
    return dot(face_normal, grass_grower_dir(block_center)) > 0.5;
#else
    return face_normal.y > 0.9; // legacy: tops only
#endif
}

#endif // INCLUDE_MISC_GRASS_ELECTION
