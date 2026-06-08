#if !defined INCLUDE_LIGHTING_LPV_VOXELIZATION
#define INCLUDE_LIGHTING_LPV_VOXELIZATION

const ivec3 voxel_volume_size = ivec3(VOXEL_VOLUME_SIZE);

#ifdef COLORED_LIGHTS
const float voxelDistance = 32.0;
#endif

vec3 get_voxel_volume_center(vec3 look_direction) {
#if VOXEL_VOLUME_CENTER == VOXEL_VOLUME_CENTER_AHEAD
    // Center the voxel volume in front of the player
    // Returns the integer offsets towards the center from the scene space
    // origin

    // Fraction of the voxel volume size that is behind the player
    const float voxelization_fraction_behind_player = 0.15; // blocks

    return floor(
        look_direction * voxel_volume_size
        * (0.5 - voxelization_fraction_behind_player)
        * rcp(max_of(abs(look_direction)))
    );
#else
    // Voxel volume is centered on the player (origin in scene space)
    return vec3(0.0);
#endif
}

vec3 scene_to_voxel_space(vec3 scene_pos) {
    vec3 to_center = get_voxel_volume_center(gbufferModelViewInverse[2].xyz);
    return scene_pos + fract(cameraPosition) + (0.5 * vec3(voxel_volume_size))
        + to_center;
}

vec3 voxel_to_scene_space(vec3 voxel_pos) {
    vec3 to_center = get_voxel_volume_center(gbufferModelViewInverse[2].xyz);
    return voxel_pos - fract(cameraPosition) - (0.5 * vec3(voxel_volume_size))
        - to_center;
}

bool is_inside_voxel_volume(vec3 voxel_pos) {
    voxel_pos *= rcp(vec3(voxel_volume_size));
    return clamp01(voxel_pos) == voxel_pos;
}

#ifdef PROGRAM_SHADOW
bool is_voxelized(uint block_id, bool vertex_at_grid_corner) {
    #if !defined COLORWHEEL
    bool is_terrain = any(equal(
        ivec4(renderStage),
        ivec4(
            MC_RENDER_STAGE_TERRAIN_SOLID,
            MC_RENDER_STAGE_TERRAIN_TRANSLUCENT,
            MC_RENDER_STAGE_TERRAIN_CUTOUT,
            MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED
        )
    ));
    #else
    bool is_terrain = true;
    #endif

    bool is_transparent_block = block_id == 1u || // Water
        block_id == 18u || // Transparent metal objects
        block_id == 28u || // Transparent copper objects
        block_id == 30u || // Transparent wood objects
        block_id == 80u; // Miscellaneous transparent

    bool is_light_emitting_block = 32u <= block_id && block_id < 64u;

    // Shader Grass: also voxelize small plants (short_grass etc., material 2) so
    // the grass geometry shader can detect where they grow. Their vertices are
    // not at block-grid corners, so they receive the +128 "transparent" marker
    // below -> identical to air for the LPV (no colored-light impact), but still
    // readable as material 2 by the grass shader's voxel lookup.
    bool is_small_plant = block_id == 2u;
    // Shader Grass: tall_grass/large_fern (materials 82/83) are voxelized the same way, so
    // the bushiness bake can find them and lift the grass-block-top blades taller there.
    bool is_tall_grass = block_id == 82u || block_id == 83u;

    return (vertex_at_grid_corner || is_light_emitting_block || is_small_plant
            || is_tall_grass)
        && is_terrain && !is_transparent_block;
}

bvec3 disjunction(bvec3 a, bvec3 b) {
    // a || b compiles on Nvidia but apparently not with other vendors
    return bvec3(a.x || b.x, a.y || b.y, a.z || b.z);
}

// Returns true if pos is within `tolerance` of a corner of the unit cube
bool is_corner(vec3 pos, float tolerance) {
    return all(disjunction(
        lessThan(pos, vec3(tolerance)),
        greaterThan(pos, vec3(1.0 - tolerance))
    ));
}

void update_voxel_map(uint block_id) {
    // Shader Grass: small plants (short_grass/flowers, material 2) MUST always be
    // stored with the transparent (+128) marker below, never as a bare corner id.
    // A plant's cross-quad has some vertices inside the is_corner() tolerance and
    // some outside, so different vertices of the SAME plant would otherwise store
    // 2 (corner -> "solid") and 130 (non-corner -> "transparent") into the same
    // voxel cell. Those writes race with no sync, so the cell flips 2<->130 every
    // frame -> grass_voxel_is_solid() flips -> grass_air_above() flips -> the whole
    // grass block's blades blink on/off (only on blocks with a plant on top,
    // inconsistently, regardless of the camera). Forcing the marker removes the
    // race. This also matches the documented intent (plants are transparent to the
    // LPV, zero colored-light impact) and is still read back as material 2 via the
    // `& 127u` mask in grass_read_voxel.
    bool small_plant = block_id == 2u || block_id == 82u || block_id == 83u; // small plants + tall grass

    vec3 model_pos = gl_Vertex.xyz + at_midBlock * rcp(64.0);
    vec3 view_pos = transform(gl_ModelViewMatrix, model_pos);
    vec3 scene_pos = transform(shadowModelViewInverse, view_pos);
    vec3 voxel_pos = scene_to_voxel_space(scene_pos);

    // Work out whether this vertex is in the lower corner of the block grid
    vec3 block_pos = transform(gl_ModelViewMatrix, gl_Vertex.xyz);
    block_pos = transform(shadowModelViewInverse, block_pos);
    block_pos = fract(block_pos + cameraPosition);
    bool vertex_at_grid_corner = is_corner(block_pos, rcp(16.0) - 1e-3);

    bool is_voxelized = is_voxelized(block_id, vertex_at_grid_corner);

    // Prevent blocks that aren't part of another category in shaders.properties
    // from being treated as air
    block_id = max(block_id, 1u);

    // Warped and crimson stem emission
    uint is_warped_stem = uint(19 <= block_id && block_id < 23);
    uint is_crimson_stem = uint(23 <= block_id && block_id < 27);
    block_id = block_id * (1u - is_warped_stem) + 46 * is_warped_stem;
    block_id = block_id * (1u - is_crimson_stem) + 58 * is_crimson_stem;

    // SSS blocks
    if (
        block_id == 5u || // Leaves
        block_id == 14u || // Strong SSS
        block_id == 15u // Weak SSS
    ) {
        block_id = 79; // light gray tint
    }

    // Mark transparent light sources (and always-transparent small plants)
    block_id = (vertex_at_grid_corner && !small_plant)
        ? block_id
        : clamp(block_id + 128u, 0u, 255u);

    if (is_voxelized && is_inside_voxel_volume(voxel_pos)) {
        imageStore(voxel_img, ivec3(voxel_pos), uvec4(block_id, 0u, 0u, 0u));
    }
}

// Shader Grass: snapshot each grass-block TOP's biome tint (gl_Color) + the shared
// grass_top atlas tile into camera-relative buffers, so the grass geometry shader
// can colour blades grown from ANY face with the real top colour. The sun renders
// every top each frame, and this VSH image store is NOT depth tested, so the tint
// is captured even when the top is occluded from the sun or culled for the player
// camera. Storing the literal gl_Color means biome + biome-blend mods are tracked
// exactly, and because it is keyed to the block (not the face) the colour can't
// change as the player moves across Sodium's top<->side face-cull transition.
void update_grass_tint(uint block_id) {
    if (block_id != 81u) { // MATERIAL_GRASS_BLOCK
        return;
    }
    if (gl_Normal.y < 0.5) {
        return; // only the top face carries the biome grass tint
    }

    vec3 model_pos = gl_Vertex.xyz + at_midBlock * rcp(64.0);
    vec3 view_pos = transform(gl_ModelViewMatrix, model_pos);
    vec3 world = transform(shadowModelViewInverse, view_pos) + cameraPosition;

    // Camera-relative XZ cell. MUST match the read in gbuffers_terrain.gsh: same
    // 256-wide window, same floor(cameraPosition.xz) (NOT the split camera, so the
    // two passes agree bit-for-bit), same +128 centre.
    ivec2 cell = ivec2(floor(world.xz) - floor(cameraPosition.xz)) + 128;
    if (any(lessThan(cell, ivec2(0))) || any(greaterThanEqual(cell, ivec2(256)))) {
        return;
    }

    imageStore(grass_tint_img, cell, vec4(gl_Color.rgb, 1.0));

    // The grass_top atlas tile is identical for every grass block, so one shared
    // cell is enough; side-grown blades sample the real grass texture from it.
    vec2 uv_minus_mid = gl_MultiTexCoord0.xy - mc_midTexCoord;
    vec2 tile_offset = min(gl_MultiTexCoord0.xy, mc_midTexCoord - uv_minus_mid);
    vec2 tile_scale = abs(uv_minus_mid) * 2.0;
    imageStore(grass_tile_img, ivec2(0), vec4(tile_offset, tile_scale));
}

// Shader Grass: record which faces of a grass block the shadow pass meshes, so the
// election can require a side be CONFIRMED rendered instead of deducing it from the
// neighbour voxel read (blind to fully-enclosed blocks - see CLAUDE.md). Each rendered
// grass-block face stamps the air cell it faces; the election reads block_center +
// side_dir. Grass blocks within GRASS_RANGE only, to keep the write count down.
// MODE 3 (Mask) ONLY: mode 4 (Camera) stamps the mask from the gbuffer GS instead (the shadow
// pass can't see the camera's per-section direction culling), so it owns grass_face_img_a/b there
// and this shadow-pass write must stay out of the way.
#if defined SHADER_GRASS && PROCEDURAL_GEOMETRY_MODE == 3
void update_grass_faces(uint block_id) {
    if (block_id != 81u) { // MATERIAL_GRASS_BLOCK
        return;
    }
    vec3 model_pos = gl_Vertex.xyz + at_midBlock * rcp(64.0);
    vec3 view_pos = transform(gl_ModelViewMatrix, model_pos);
    vec3 scene_pos = transform(shadowModelViewInverse, view_pos);
    if (dot(scene_pos, scene_pos) > GRASS_RANGE * GRASS_RANGE) {
        return;
    }
    ivec3 face_cell = ivec3(scene_to_voxel_space(scene_pos)) + ivec3(round(gl_Normal));
    if (is_inside_voxel_volume(vec3(face_cell))) {
        imageStore(grass_face_img, face_cell, uvec4(1u, 0u, 0u, 0u));
    }
}
#endif
#endif

#endif // INCLUDE_LIGHTING_LPV_VOXELIZATION
