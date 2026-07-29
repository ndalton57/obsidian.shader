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

// SSS leak fix: map an axis-aligned face normal to its existence bit in a per-block
// face mask. Shared by the shadow-pass stamp (update_sss_faces) and the deferred read.
//   +x=bit0  -x=bit1  +y=bit2  -y=bit3  +z=bit4  -z=bit5
uint sss_face_bit(vec3 normal) {
    vec3 n = round(normal);
    if (n.x >  0.5) return 1u << 0u;
    if (n.x < -0.5) return 1u << 1u;
    if (n.y >  0.5) return 1u << 2u;
    if (n.y < -0.5) return 1u << 3u;
    if (n.z >  0.5) return 1u << 4u;
    return 1u << 5u;
}

// Shader Grass: ahead-centred cell for the per-block TOP tint buffer. Mirrors scene_to_voxel_space
// but uses GRASS_TINT_SIZE, so the tint buffer is DECOUPLED from the LPV's VOXEL_VOLUME_SIZE (the
// colored-lights resolution doesn't size it). At the default VOXEL_VOLUME_SIZE the two coincide. Used
// by BOTH the shadow-pass write (update_grass_tint) and the gbuffer read (grass_top_reproduce),
// so it lives here as the one shared definition. Same-frame (written then read within a frame), so the
// camera-relative fract(cameraPosition) and look-direction centre are consistent across the two passes.
vec3 scene_to_grass_tint_space(vec3 scene_pos) {
    vec3 dir = gbufferModelViewInverse[2].xyz;
#if VOXEL_VOLUME_CENTER == VOXEL_VOLUME_CENTER_AHEAD
    vec3 to_center
        = floor(dir * float(GRASS_TINT_SIZE) * (0.5 - 0.15) * rcp(max_of(abs(dir))));
#else
    vec3 to_center = vec3(0.0);
#endif
    return scene_pos + fract(cameraPosition) + 0.5 * vec3(GRASS_TINT_SIZE) + to_center;
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
    bool is_small_plant = block_id == 2u || block_id == 85u // mod grass (2) + short_grass (85)
        || (block_id >= 104u && block_id <= 123u); // flowers, tall-flower lowers, ground blooms
    // Shader Grass: tall_grass/large_fern (materials 82/83) are voxelized the same way, so
    // the bushiness bake can find them and lift the grass-block-top blades taller there.
    bool is_tall_grass = block_id == 82u || block_id == 83u;
    // Snow LAYER (84): voxelize as SOLID so the grass shader reads it as a covering block above
    // (grass_air_above) and grows NO blades under it. Voxelize at ALL verts (not just grid corners),
    // and force the bare/solid marker below - so a snow FIELD (interior layers mesh only their
    // non-corner top face) still registers. Same forced-marker pattern as small plants (gotcha #11).
    bool is_snow = block_id == 84u;
    // Redstone wire (93): voxelized at ALL verts and stored with a forced
    // marker below - its quad has both corner and inset vertices, so the
    // corner test would race the cell every frame (gotcha #11 class).
    bool is_redstone_wire = block_id == 93u;
    // Ground-cover plants (124: leaf litter, warped/crimson roots): thin
    // decor that must never read as a covering block above a grass block -
    // voxelized at ALL verts and stored with the forced transparent marker
    // below, so grass_air_above sees the cell as OPEN and the shader grass
    // keeps growing through them.
    bool is_ground_cover = block_id == 124u;

    return (vertex_at_grid_corner || is_light_emitting_block || is_small_plant
            || is_tall_grass || is_snow || is_redstone_wire || is_ground_cover)
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
    bool small_plant = block_id == 2u || block_id == 82u || block_id == 83u || block_id == 85u
        || (block_id >= 104u && block_id <= 123u) // small plants + tall/short grass
        // Amethyst buds/clusters (55, an LPV emitter): their cross quads mix
        // corner and inset vertices, so without the forced marker the cell
        // RACES solid<->transparent every frame (gotcha #11) and kills the
        // grass under them. Forced +128 keeps the cell open (grass grows)
        // while the LPV still reads the emitter id via & 127.
        || block_id == 55u
        // Ground-cover plants (leaf litter, warped/crimson roots): forced
        // transparent so the shader grass grows through them; their mixed
        // corner/inset vertices would otherwise race the cell (gotcha #11)
        || block_id == 124u;
    bool is_snow_layer = block_id == 84u; // snow layer: force the SOLID (bare id) marker, never +128

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

    // Redstone wire (93) stores as 58 (the redstone-block emitter, so the LPV
    // reuses its red light color). Forced SOLID below - one stable marker
    // (its mixed corner/inset verts would otherwise race the cell, blinking
    // the blades of the grass block under it), and solid means
    // grass_air_above() reads the wire as cover: no blades through circuits.
    bool is_redstone_wire = block_id == 93u;
    block_id = is_redstone_wire ? 58u : block_id;

#ifdef GLOWING_ORE
    // Glowing ores double as dim colored-light emitters: remap blocks
    // 86-92 into the second emitter ID range (96-102 -> light_color 32-38)
    uint is_glowing_ore = uint(86u <= block_id && block_id < 93u);
    block_id = block_id * (1u - is_glowing_ore) + (block_id + 10u) * is_glowing_ore;
#endif

    // SSS blocks
    if (
        block_id == 5u || // Leaves
        block_id == 14u || // Strong SSS
        block_id == 15u // Weak SSS
    ) {
        block_id = 79; // light gray tint
    }

    // Mark transparent light sources and always-transparent small plants (+128); the snow LAYER is
    // forced the other way - always SOLID (bare id) so it covers the grass below. Both force a fixed
    // marker to dodge the per-vertex marker RACE (gotcha #11): their verts span the cell (corner +
    // non-corner) so a corner-test marker would flip the cell solid<->transparent every frame.
    block_id = ((vertex_at_grid_corner && !small_plant) || is_snow_layer
                || is_redstone_wire)
        ? block_id
        : clamp(block_id + 128u, 0u, 255u);

    if (is_voxelized && is_inside_voxel_volume(voxel_pos)) {
        imageStore(voxel_img, ivec3(voxel_pos), uvec4(block_id, 0u, 0u, 0u));
    }
}

#ifdef SHADER_GRASS
// Shader Grass: snapshot each grass-block TOP's biome tint (gl_Color) AND lightmap (block + sky)
// + the shared grass_top atlas tile into camera-relative buffers, so the grass geometry shader can
// colour AND light blades grown from ANY face with the real top values. The sun renders every top
// each frame, and this VSH image store is NOT depth tested, so they are captured even when the top is
// occluded from the sun or culled for the player camera. Storing the literal gl_Color means biome +
// biome-blend mods are tracked exactly. Tint and light are stored per CORNER - a 2x2 XZ tile of texels
// per block, indexed by the sign of at_midBlock - in 3D buffers keyed by block X/Y/Z, so each of the 4
// top vertices writes its OWN texel (race-free, no atomics) AND vertically-stacked grass blocks never
// share a slot. The grass shader bilinearly blends the 4 corners to reproduce the top's smooth
// per-position colour and brightness for blades grown on any face.
#ifdef GRASS_FLOWERS
// Shader Grass: capture the REAL bloom colours of a small flower into ITS OWN
// (otherwise unused) cell of the grass-tint buffer - four texels probed from
// the flower's atlas sprite, one per corner slot. The generated flower heads
// read them back, so a head mirrors the actual flower texture (a poppy's reds,
// an allium's range of purples) instead of a canned palette. The cross's 8
// verts are race-free per slot: both verts sharing a corner compute the SAME
// probe uvs, so double-writes store identical values.
void update_flower_palette() {
    vec3 model_pos = gl_Vertex.xyz + at_midBlock * rcp(64.0);
    vec3 view_pos = transform(gl_ModelViewMatrix, model_pos);
    vec3 scene_center = transform(shadowModelViewInverse, view_pos);

    vec3 vp = scene_to_grass_tint_space(scene_center);
    if (any(lessThan(vp, vec3(0.0)))
        || any(greaterThanEqual(vp, vec3(GRASS_TINT_SIZE)))) {
        return;
    }
    ivec3 cell = ivec3(vp);

    vec2 uv_minus_mid = gl_MultiTexCoord0.xy - mc_midTexCoord;
    vec2 tile_half = abs(uv_minus_mid);
    if (max_of(tile_half) < 1e-6) {
        return;
    }

    // Which uv direction is the sprite's TOP (the bloom end): a vertex below
    // the block centre sits at the sprite's bottom edge, so its uv offset
    // from the tile centre points down-sprite - flip that.
    float v_up = (at_midBlock.y > 0.0 ? -1.0 : 1.0) * sign(uv_minus_mid.y);

    ivec2 corner = ivec2(at_midBlock.x < 0.0 ? 1 : 0, at_midBlock.z < 0.0 ? 1 : 0);
    vec2 cq = vec2(corner) * 2.0 - 1.0;

    // Probe a few texels in this corner's quadrant of the bloom half; keep
    // the most flower-like one (opaque and not stem-green). If every probe
    // misses the bloom, store nothing - the head falls back to its family
    // palette.
    vec3 best = vec3(0.0);
    float best_score = 0.05;
    bool found = false;
    for (int i = 0; i < 4; ++i) {
        vec2 o = vec2(
            cq.x * (0.10 + 0.16 * float(i & 1)),
            v_up * (0.04 + 0.15 * float(i >> 1))
        );
        vec4 s = textureLod(tex, mc_midTexCoord + o * tile_half * 2.0, 0.0);
        float greenness = s.g - max(s.r, s.b);
        float luma = dot(s.rgb, vec3(0.2126, 0.7152, 0.0722));
        // Luma-weighted: dark sprite outline/shadow texels lose to bright
        // petals; green stem texels are rejected outright
        float score = s.a * (0.25 + 1.3 * luma)
            - clamp(greenness, 0.0, 1.0) * 1.5;
        if (score > best_score) {
            best_score = score;
            best = s.rgb;
            found = true;
        }
    }
    if (!found) {
        return;
    }

    // gl_Color is 1.0 for vanilla flowers; folded in for tinted mod blooms
    ivec3 store_cell = ivec3(cell.x * 2 + corner.x, cell.z * 2 + corner.y, cell.y);
    imageStore(grass_tint_img, store_cell, vec4(best * gl_Color.rgb, 1.0));
}
#endif

void update_grass_tint(uint block_id) {
#ifdef GRASS_FLOWERS
    if (block_id >= 104u && block_id <= 114u) { // capturing flowers (the mats use curated palettes)
        update_flower_palette();
        return;
    }
#endif
    if (block_id != 81u) { // MATERIAL_GRASS_BLOCK
        return;
    }
    if (gl_Normal.y < 0.5) {
        return; // only the top face carries the biome grass tint
    }

    vec3 model_pos = gl_Vertex.xyz + at_midBlock * rcp(64.0);
    vec3 view_pos = transform(gl_ModelViewMatrix, model_pos);
    vec3 scene_center = transform(shadowModelViewInverse, view_pos); // block centre, scene space

    // 3D tint cell (ahead-centred voxel region; scene_to_grass_tint_space is decoupled from the LPV
    // size and is the SAME function the gbuffer read uses, so the two passes agree). The Y axis is
    // what stops vertically-stacked grass blocks (same XZ) from sharing a slot.
    vec3 vp = scene_to_grass_tint_space(scene_center);
    if (any(lessThan(vp, vec3(0.0)))
        || any(greaterThanEqual(vp, vec3(GRASS_TINT_SIZE)))) {
        return;
    }
    ivec3 cell = ivec3(vp);

    // Which of the top's 4 corners is this vertex? at_midBlock points from the vertex to the block
    // centre (world-axis-aligned for terrain), so its sign gives the corner: at_midBlock.x < 0 =>
    // the vertex sits on the +X side, etc. Each corner writes its OWN texel in the block's 2x2 XZ
    // tile within its Y layer - no shared slot, so race-free with no atomics.
    ivec2 corner = ivec2(at_midBlock.x < 0.0 ? 1 : 0, at_midBlock.z < 0.0 ? 1 : 0);
    ivec3 store_cell = ivec3(cell.x * 2 + corner.x, cell.z * 2 + corner.y, cell.y);
    imageStore(grass_tint_img, store_cell, vec4(gl_Color.rgb, 1.0));
    // Companion LIGHT buffer: the TOP's lightmap (block in R, sky in G) per corner. A side/bottom
    // grower reproduces THIS for its blades instead of using its own (racing FCFS) face's lightmap,
    // so blade brightness doesn't flicker as the winner changes - worst in dark/shade, where the
    // lightmap IS the lighting. gl_MultiTexCoord1.xy are the 0..240 lightmap coords; plain per-corner
    // values, so they bilinear-blend like the tint.
    vec2 top_light = clamp(gl_MultiTexCoord1.xy * (1.0 / 240.0), 0.0, 1.0);
    imageStore(grass_light_img, store_cell, vec4(top_light, 0.0, 0.0));

    // The grass_top atlas tile is identical for every grass block, so one shared
    // cell is enough; side-grown blades sample the real grass texture from it.
    // One corner vertex per top writes it (every top quad has all 4 corners,
    // and all of them compute the same value) - the other three skip the
    // store to the single contended texel.
    if (corner == ivec2(0)) {
        vec2 uv_minus_mid = gl_MultiTexCoord0.xy - mc_midTexCoord;
        vec2 tile_offset = min(gl_MultiTexCoord0.xy, mc_midTexCoord - uv_minus_mid);
        vec2 tile_scale = abs(uv_minus_mid) * 2.0;
        imageStore(grass_tile_img, ivec2(0), vec4(tile_offset, tile_scale));
    }
}
#endif

// SSS leak fix: record which faces of each OPAQUE terrain block were actually DRAWN in
// the shadow pass, as a per-block 6-bit mask stamped INWARD into the block's own cell.
// The deferred pass reads a block's own sun-side bit to tell an EXPOSED sun-side face
// from a BURIED (culled) one - a culled face is never drawn, so its bit is never set,
// at any distance, with no depth math and no shared-cell false positives. Uses
// imageAtomicOr because a block's six faces write different bits into one cell.
// Transparent blocks don't cover a neighbour from the sun, so they don't stamp.
void update_sss_faces(uint block_id) {
    // Only OPAQUE occluders stamp - blocks that can actually put a solid block between
    // a neighbour and the sun. Transparent AND cutout/thin blocks (plants, leaves) never
    // occlude, so they are skipped: the deferred gate then sees a non-stamping block as
    // "thin" and checks the neighbour toward the sun instead of its own face.
    bool is_non_occluder = block_id == 1u || block_id == 18u || block_id == 28u
        || block_id == 30u || block_id == 80u   // water / transparent objects / misc
        || block_id == 2u || block_id == 85u || block_id == 82u || block_id == 83u // small/tall grass, plants
        || (block_id >= 104u && block_id <= 123u) // flowers, tall-flower lowers, ground blooms
        || block_id == 3u || block_id == 4u      // tall plants (lower/upper)
        || block_id == 5u                        // leaves
        || block_id == 93u;                      // redstone wire (flat decal, never blocks the sun)

    if (is_non_occluder) {
        return;
    }

    vec3 model_pos = gl_Vertex.xyz + at_midBlock * rcp(64.0);
    vec3 view_pos = transform(gl_ModelViewMatrix, model_pos);
    vec3 scene_pos = transform(shadowModelViewInverse, view_pos);

    ivec3 cell = ivec3(scene_to_voxel_space(scene_pos)); // the face's OWN block cell

    // Snow LAYER (84): its flat bottom culls the covered block's top face, so that block
    // never stamps its own +y bit and the deferred edge-wrap rim has no sunlit top to wrap
    // from - the block under the snow (a snow_block on a mountain) stops glowing. Treat the
    // slab like glass for SSS: stamp the +y bit DOWNWARD into the covered block so its top
    // counts as exposed. The rim there stays sun- and skylight-gated in the deferred pass, so
    // no cave leak; paired with the snow discard in shadow.fsh so the sun reaches that top.
    if (block_id == 84u) {
        ivec3 below = cell - ivec3(0, 1, 0);
        if (is_inside_voxel_volume(vec3(below))) {
            imageAtomicOr(sss_face_img, below, sss_face_bit(vec3(0.0, 1.0, 0.0)));
        }
    }

    if (is_inside_voxel_volume(vec3(cell))) {
        // Stamp INWARD: set this face's bit in its own block, so the deferred pass
        // reads the block's own sun-side bit - no shared air cell, no false positives.
        imageAtomicOr(sss_face_img, cell, sss_face_bit(gl_Normal));
    }
}

// Shader Grass: record which faces of a grass block the shadow pass meshes, so the
// election can require a side be CONFIRMED rendered instead of deducing it from the
// neighbour voxel read (blind to fully-enclosed blocks). Each rendered
// grass-block face stamps the air cell it faces; the election reads block_center +
// side_dir. Grass blocks within GRASS_RANGE only, to keep the write count down.
// MODE 3 (Mask) ONLY: mode 4 (Race/FCFS) uses no shadow-pass mask at all - the grower is decided
// in the gbuffer TCS as faces race through the pipeline and CAS-claim their block - so this
// shadow-pass write is compiled out there.
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
