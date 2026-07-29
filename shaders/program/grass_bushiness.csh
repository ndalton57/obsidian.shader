/*
--------------------------------------------------------------------------------

  Obsidian Shader

  program/grass_bushiness.csh:
  Shader Grass bushiness bake. Once per voxel cell, spread the vanilla short_grass
  markers (material 2 in voxel_sampler) into a smooth [0,1] grass-height influence
  field, so the terrain geometry shader can read the height boost with ONE field
  lookup per blade instead of an N*N neighbour scan per blade (which was GS-bound and
  tanked FPS). Runs as a world0 shadowcomp, after the shadow pass has voxelized the
  scene.

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

layout(local_size_x = 32) in;

#if VOXEL_VOLUME_SIZE == 64
const ivec3 workGroups = ivec3(2, 64, 64);
#elif VOXEL_VOLUME_SIZE == 96
const ivec3 workGroups = ivec3(3, 96, 96);
#elif VOXEL_VOLUME_SIZE == 128
const ivec3 workGroups = ivec3(4, 128, 128);
#elif VOXEL_VOLUME_SIZE == 256
const ivec3 workGroups = ivec3(8, 256, 256);
#elif VOXEL_VOLUME_SIZE == 512
const ivec3 workGroups = ivec3(16, 512, 512);
#endif

#if defined COLORED_LIGHTS && defined SHADER_GRASS
uniform usampler3D voxel_sampler;
writeonly uniform image3D grass_bushiness_img;

#ifdef GRASS_FLOWERS
writeonly uniform image3D grass_flower_field_img;
writeonly uniform uimage3D grass_flower_spots_img;
uniform sampler3D grass_tint_sampler;
uniform vec3 cameraPosition;
uniform ivec3 cameraPositionInt;
uniform vec3 cameraPositionFract;
uniform mat4 gbufferModelViewInverse;

#include "/include/lighting/lpv/voxelization.glsl"

// MUST match grass_hash2 in gbuffers_terrain.gsh bit for bit - the geometry
// shader recomputes each claimed spot's hashes from the packed flower
// coordinate + k, and the two sides have to agree.
vec2 bake_hash2(ivec2 c) {
    uvec2 u = uvec2(c);
    uint h = u.x * 0x8da6b343u ^ u.y * 0xd8163841u;
    h = (h ^ (h >> 13)) * 0x9E3779B1u;
    h ^= h >> 16;
    return vec2(h & 0xFFFFu, h >> 16) * (1.0 / 65535.0);
}

// Spot radius for a hash h in [0,1): the inverse CDF of the dye falloff
// treated as an AREA density - uniform within 0.5 of the bloom, then the
// same 1-t^2 taper to zero at 1.5 the dye (and the grass heights) use.
// Stalk density therefore tracks the dye falloff, and the count slider is a
// budget for the bloom's WHOLE patch: blocks missing from the patch (stone,
// air) simply drop their share - the centre block's density never changes.
float bake_spot_radius(float h) {
    if (h < 0.1765) {
        return 0.5 * sqrt(h * (1.0 / 0.1765));
    }
    if (h < 0.392) {
        return mix(0.5, 0.75, (h - 0.1765) * (1.0 / (0.392 - 0.1765)));
    }
    if (h < 0.654) {
        return mix(0.75, 1.0, (h - 0.392) * (1.0 / (0.654 - 0.392)));
    }
    if (h < 0.892) {
        return mix(1.0, 1.25, (h - 0.654) * (1.0 / (0.892 - 0.654)));
    }
    return mix(1.25, 1.5, (h - 0.892) * (1.0 / (1.0 - 0.892)));
}

// Mirrors the fallback table in gbuffers_terrain.gsh (flower_palette); tall-
// flower lowers (109-112) map onto their base bloom family first
vec3 bake_flower_palette(uint family) {
    if (family == 109u) { family = 104u; }                   // rose bush
    if (family == 110u) { family = 105u; }                   // sunflower
    if (family == 111u || family == 112u) { family = 107u; } // lilac, peony
    if (family == 55u) {
        return vec3(0.72, 0.55, 0.95);                       // amethyst (constant glow dye)
    }
    if (family == 114u) {
        return vec3(1.00, 0.62, 0.16);                       // firefly bush (amber)
    }
    if (family >= 120u && family <= 123u) {
        return vec3(0.97, 0.60, 0.76);                       // pink petals mat
    }
    if (family >= 116u && family <= 119u) {
        return vec3(0.98, 0.83, 0.18);                       // wildflowers mat
    }
    if (family == 104u) { return vec3(0.80, 0.10, 0.06); } // red
    if (family == 105u) { return vec3(0.96, 0.80, 0.14); } // yellow
    if (family == 106u) { return vec3(0.28, 0.42, 0.92); } // blue
    if (family == 107u) { return vec3(0.78, 0.48, 0.90); } // purple
    return vec3(0.96, 0.95, 0.90);                         // white
}

// The bloom's petal tone for the dye field: brightest of the 4 captured
// sprite texels in the flower's tint cell (the ring-tone guards live in the
// geometry shader; the dye only needs the light tone), family fallback when
// uncaptured.
vec3 bake_flower_tone(ivec3 flower_voxel_cell, uint family) {
    vec3 tone = bake_flower_palette(family);
    vec3 scene_center
        = voxel_to_scene_space(vec3(flower_voxel_cell) + 0.5);
    vec3 fvp = scene_to_grass_tint_space(scene_center);
    if (any(lessThan(fvp, vec3(0.0)))
        || any(greaterThanEqual(fvp, vec3(GRASS_TINT_SIZE)))) {
        return tone;
    }
    ivec3 fc = ivec3(fvp);
    ivec2 fb = ivec2(fc.x * 2, fc.z * 2);
    const vec3 lw = vec3(0.2126, 0.7152, 0.0722);
    float best = 1e-3;
    for (int i = 0; i < 4; ++i) {
        vec3 c = texelFetch(
            grass_tint_sampler,
            ivec3(fb.x + (i & 1), fb.y + (i >> 1), fc.y), 0
        ).rgb;
        float l = dot(c, lw);
        if (l > best) {
            best = l;
            tone = c;
        }
    }
    return tone;
}
#endif

void main() {
    ivec3 cell = ivec3(gl_GlobalInvocationID);

    // One thread per cell -> the strongest decal falloff from any cell within
    // GRASS_BUSHINESS_REACH in the SAME y-layer (the boost spreads horizontally, the way grass
    // tufts out across neighbouring block tops). TWO channels: R = proximity to short_grass
    // (material 2), G = proximity to tall_grass/large_fern (material 82, the lower half). The GS
    // lifts the grass-block-top blades by SHORT_GRASS_HEIGHT / TALL_GRASS_HEIGHT respectively. The
    // reach is FIXED here - the height sliders set how TALL, not how far. 1 - t^2 from full at the
    // decal cell to 0 at reach.
    float reach = GRASS_BUSHINESS_REACH; // blocks (fixed; raise for a wider spread)
#ifdef GRASS_BUSHINESS_DYNAMIC_SCAN
    // Scan half-width. falloff(d) = 1 - t^2 with t = clamp((d - 0.5) /
    // (reach - 0.5), 0, 1) is EXACTLY 0 for every cell at d >= reach, and a
    // zero falloff contributes nothing anywhere below (max() no-ops, and the
    // strict `falloff > flower_inf` never claims a flower at 0) - so cells at
    // integer offset ceil(reach) and beyond are dead taps. ceil(reach) - 1
    // covers every contributing cell; the floor of 1 keeps the +/-1 ring that
    // the stalk-spot assignment always needs (spots reach 1.5 blocks from
    // their flower independently of the falloff). At the default reach 1.5
    // this scans 3x3 instead of 5x5 - 9 fetches per cell instead of 25, for
    // every cell of the volume, every frame, with identical output.
    int n = clamp(int(ceil(reach)) - 1, 1, GRASS_BUSHINESS_MAX_CELLS);
#else
    const int n = GRASS_BUSHINESS_MAX_CELLS; // compile-time -> the loop unrolls
#endif
    float short_inf = 0.0; // R: short_grass proximity
    float tall_inf = 0.0;  // G: tall_grass / large_fern proximity
#ifdef GRASS_FLOWERS
    // Flower dye field: the strongest nearby bloom's falloff + its petal
    // tone, so blades across neighbouring blocks know how LIKELY they are to
    // take the tip dye and which colour it is (see the per-blade roll in
    // gbuffers_terrain.gsh). Same falloff shape as the grass heights.
    float flower_inf = 0.0;
    ivec3 flower_cell = ivec3(0);
    uint flower_id = 0u;
    // B/A of the bushiness field: proximity to the GLOW dye sources, so the
    // blade pass reads them with the taps it already does
    float firefly_inf = 0.0;  // B: firefly bush (blinking amber tips)
    float amethyst_inf = 0.0; // A: amethyst (constant purple tips)
    // Stalk spots landing on THIS cell's block, baked ONCE here instead of
    // being re-derived by every grower sub-triangle (that per-blade scan of
    // every nearby flower's whole spot list was a massive FPS sink in dense
    // flower fields). Packed per spot: valid 1 | x 8 | z 8 | k 6 | family 5
    // | flower offset 4 - the geometry shader recomputes the spot's hashes
    // from the flower coordinate + k, so the result is identical.
    uint spot_slots[8]
        = uint[8](0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u);
    int n_spots = 0;
    vec3 cell_scene = voxel_to_scene_space(vec3(cell) + 0.5);
#endif
    for (int dx = -n; dx <= n; ++dx) {
        for (int dz = -n; dz <= n; ++dz) {
            ivec3 nc = cell + ivec3(dx, 0, dz);
            if (any(lessThan(nc, ivec3(0)))
                || any(greaterThanEqual(nc, ivec3(VOXEL_VOLUME_SIZE)))) {
                continue; // outside the volume
            }
            uint m = texelFetch(voxel_sampler, nc, 0).x & 127u;
            bool is_flower = m >= 104u && m <= 123u; // flowers, tall lowers, ground blooms
            bool is_amethyst = m == 55u; // amethyst buds/cluster: dye only
            if (m != 85u && m != 82u && !is_flower && !is_amethyst) { // 85 = short_grass (MATERIAL_SHORT_GRASS), 82 = tall grass lower
                continue;
            }
            float d = length(vec2(float(dx), float(dz))); // cell distance (blocks)
            float t = clamp((d - 0.5) / max(reach - 0.5, 1e-3), 0.0, 1.0);
            float falloff = 1.0 - t * t;
            if (m == 85u) {
                short_inf = max(short_inf, falloff);
            } else if (is_flower || is_amethyst) {
#ifdef GRASS_FLOWERS
                // A bloom lifts the surrounding grass exactly like a
                // short_grass decal does, on top of driving the dye field.
                // Amethyst drives the dye ONLY - crystals don't bush out
                // the grass.
                if (is_flower) {
                    short_inf = max(short_inf, falloff);
                }
                if (falloff > flower_inf) {
                    flower_inf = falloff;
                    flower_cell = nc;
                    flower_id = m;
                }
                if (is_amethyst) {
                    amethyst_inf = max(amethyst_inf, falloff);
                } else if (m == 114u) {
                    firefly_inf = max(firefly_inf, falloff);
                }

                // Spot assignment: heads for everything except the glow-only
                // sources; spots reach 1.5 blocks, so only flowers within
                // +/-1 can land on this block
                if (is_flower && m != 114u && abs(dx) <= 1 && abs(dz) <= 1
                    && n_spots < 8) {
                    vec3 f_scene = voxel_to_scene_space(vec3(nc) + 0.5);
                    ivec2 ffk = cameraPositionInt.xz
                        + ivec2(floor(f_scene.xz + cameraPositionFract.xz));
                    int keff = GRASS_FLOWER_DENSITY;
                    if (m >= 116u && m <= 123u) { // segment-scaled mats
                        int amt = int(m - 116u) % 4 + 1;
                        keff = max((GRASS_FLOWER_DENSITY * amt) / 4, 1);
                    }
                    for (int k = 0; k < keff && n_spots < 8; ++k) {
                        vec2 sh = bake_hash2(
                            ffk * 7 + ivec2(k * 131 + 37, k * 61 + 91));
                        float rad = bake_spot_radius(sh.y);
                        float ang = tau * sh.x;
                        vec2 sp_local = f_scene.xz
                            + vec2(cos(ang), sin(ang)) * rad
                            - (cell_scene.xz - 0.5);
                        if (clamp(sp_local, 0.0, 1.0) != sp_local) {
                            continue; // lands on another block
                        }
                        spot_slots[n_spots] = 0x80000000u
                            | (uint(sp_local.x * 255.0 + 0.5) << 23)
                            | (uint(sp_local.y * 255.0 + 0.5) << 15)
                            | (uint(k) << 9)
                            | ((m - 104u) << 4)
                            | uint((dx + 1) * 3 + (dz + 1));
                        n_spots++;
                    }
                }
#endif
            } else {
                tall_inf = max(tall_inf, falloff);
            }
        }
    }
#ifdef GRASS_FLOWERS
    imageStore(grass_bushiness_img, cell,
               vec4(short_inf, tall_inf, firefly_inf, amethyst_inf));
    vec3 flower_tone = vec3(0.0);
    if (flower_inf > 0.0) {
        flower_tone = bake_flower_tone(flower_cell, flower_id);
    }
    // PREMULTIPLIED by the falloff, so the read side's bilinear interpolation
    // averages tones correctly (rgb / a recovers the full-strength tone)
    imageStore(grass_flower_field_img, cell,
               vec4(flower_tone * flower_inf, flower_inf));
    imageStore(grass_flower_spots_img, ivec3(cell.x * 2, cell.y, cell.z),
               uvec4(spot_slots[0], spot_slots[1], spot_slots[2],
                     spot_slots[3]));
    imageStore(grass_flower_spots_img, ivec3(cell.x * 2 + 1, cell.y, cell.z),
               uvec4(spot_slots[4], spot_slots[5], spot_slots[6],
                     spot_slots[7]));
#else
    imageStore(grass_bushiness_img, cell, vec4(short_inf, tall_inf, 0.0, 0.0));
#endif
}
#else
void main() {}
#endif
