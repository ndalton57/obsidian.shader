#if !defined INCLUDE_MISC_CHERRY_GROVE
#define INCLUDE_MISC_CHERRY_GROVE

#include "/include/misc/material_masks.glsl"

// Cherry Grove pink grass: recolor cherry grove grass toward CHERRY_GROVE_PINK_*.
// Cherry grove grass/foliage uses a HARDCODED colour (#B6DB61) that no other vanilla
// biome and no resource-pack colormap produces (MC-260264), so matching that tint
// picks out cherry grove grass directly from its colour - independent of where the
// player stands.
//
// At biome borders Minecraft blends grass colours per block, so the tint there is a
// cherry/neighbour MIX. Rather than blend pink<->green (which passes through grey,
// since they are near-opposite hues), we DITHER: each element - per blade in the
// geometry shader, per TEXEL on the ground - is chosen fully pink or fully its own
// green, with `weight` as the chance of pink. The transition then reads as mixed pink
// & green specks with no grey. Leaves are excluded so cherry blossoms are untouched.

// Stable, well-distributed pseudo-random in [0, 1) from a world-space key, for the
// pink/green dither. Dave Hoskins' "hash without sine": a sine-based hash visibly bands
// into diagonal/triangular streaks on the regular blade/texel grid (nearby keys stay
// correlated), so the dither clumps; this scatters it into an even random sprinkle. The
// vec2 form keys blades by their world xz; the vec3 form keys ground texels (3D so it
// works on every face, not just tops).
float cherry_grove_dither(vec2 key) {
    vec3 p3 = fract(vec3(key.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float cherry_grove_dither(vec3 key) {
    key = fract(key * 0.1031);
    key += dot(key, key.zyx + 31.32);
    return fract((key.x + key.y) * key.z);
}

vec3 cherry_grove_pink_grass(vec3 grass_tint, uint material_id, float dither_random) {
    if (material_id == MATERIAL_LEAVES) {
        return grass_tint;
    }

    // Distance from cherry grove's hardcoded grass colour. CHERRY_GROVE_PINK_SPREAD
    // (slider) is the outer edge of the transition band; the full-pink core is half of
    // it. Wider = the dithered transition reaches further into the blended border
    // grass; narrower = hugs pure cherry grove grass.
    const vec3 cherry_grass = vec3(182.0, 219.0, 97.0) / 255.0;
    const float match_none = CHERRY_GROVE_PINK_SPREAD;
    const float match_full = CHERRY_GROVE_PINK_SPREAD * 0.5;
    float weight
        = 1.0 - smoothstep(match_full, match_none, distance(grass_tint, cherry_grass));

    // Dither, don't blend: fully pink or fully the original tint, never a grey mix.
    const vec3 pink
        = vec3(CHERRY_GROVE_PINK_R, CHERRY_GROVE_PINK_G, CHERRY_GROVE_PINK_B);
    return dither_random < weight ? pink : grass_tint;
}

#endif // INCLUDE_MISC_CHERRY_GROVE
