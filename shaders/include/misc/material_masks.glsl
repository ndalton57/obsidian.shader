#if !defined INCLUDE_MISC_MATERIAL_MASKS
#define INCLUDE_MISC_MATERIAL_MASKS

// Macros providing readable names for common material IDs

#define MATERIAL_WATER 1
#define MATERIAL_SMALL_PLANTS 2
#define MATERIAL_TALL_PLANTS_LOWER 3
#define MATERIAL_TALL_PLANTS_UPPER 4
#define MATERIAL_LEAVES 5
// Shader Grass: grass_block tagged in block.properties so the solid terrain geometry shader
// can detect grass-block tops (to grow blades). The cube itself shades with GROUND_SSS, like
// the dirt around it (see material_from), so its sunlit edges glow via the edge-wrap rim.
#define MATERIAL_GRASS_BLOCK 81
// Shader Grass: tall_grass/large_fern, split out of MATERIAL_TALL_PLANTS so the grass
// shader can detect them colour-independently and lift the grass-block-top blades taller
// where they sit (reusing the bushiness field - no extra geometry). Detection-only like
// grass_block: the flat cross is hidden on grass blocks; beyond range it stays a tall plant.
#define MATERIAL_TALL_GRASS_LOWER 82
#define MATERIAL_TALL_GRASS_UPPER 83
// Shader Grass: the snow LAYER (minecraft:snow), split out of the transparent material so it
// VOXELIZES as a solid block - grass_air_above then treats it as a covering block above a grass
// block and grows no blades under it (a side grower otherwise pokes grass up through the snow).
// Read implicitly via grass_voxel_is_solid (any solid voxel above blocks grass), not by name.
#define MATERIAL_SNOW 84
// Shader Grass: short_grass / fern (vanilla), split out of MATERIAL_SMALL_PLANTS so the grass shader
// detects them BY MATERIAL (colour-independent) instead of by green tint - which failed on biome-
// recoloured grass (savanna's is yellow-brown). Behaves as a small plant otherwise: voxelized like
// material 2, waved like a small plant, and re-emitted as material 2 by the cutout so the fragment
// shading / cherry recolor are unchanged.
#define MATERIAL_SHORT_GRASS 85
// Shader Grass: vanilla small flowers, split out of MATERIAL_SMALL_PLANTS by bloom colour. The
// terrain geometry shader reads these ids from the voxel volume (the block above a grower) and
// grows a few taller stalks with colored flower heads above the grass canopy, so flowers stay
// visible through the dense field. The flat flower cross itself re-emits as material 2 (like
// short_grass above), so its own shading/waving is unchanged; these masks reach the fragment
// shader only on the generated head quads, which draw a procedural petal disc.
#define MATERIAL_FLOWER_RED 104
#define MATERIAL_FLOWER_YELLOW 105
#define MATERIAL_FLOWER_BLUE 106
#define MATERIAL_FLOWER_PURPLE 107
#define MATERIAL_FLOWER_WHITE 108
#define MATERIAL_FLOWER_FIRST 104
#define MATERIAL_FLOWER_LAST 108
// Tall-flower LOWER halves (rose_bush / sunflower / lilac / peony), split out
// of MATERIAL_TALL_PLANTS_LOWER so the grass shader can detect them and grow
// heads around them. The flat plant re-emits as material 3 (its rendering /
// waving is unchanged, and the bush is NOT hidden - it stands above the grass
// already); heads take the plant's BASE bloom family below, so these ids
// never reach the gbuffer.
#define MATERIAL_FLOWER_TALL_FIRST 109
#define MATERIAL_FLOWER_TALL_LAST 112
// Ground blooms: the firefly bush (re-emits as a small plant; bush kept,
// heads around it) and the wildflowers / pink_petals mats (re-emit as
// strong-SSS material 14; REPLACED near the camera by multicolor heads from
// curated palettes). Mats carry one id per SEGMENT COUNT (flower_amount
// 1-4): amount = (id - MAT_FIRST) % 4 + 1 scales the head budget.
#define MATERIAL_FLOWER_FIREFLY_BUSH 114
#define MATERIAL_FLOWER_MAT_FIRST 116
#define MATERIAL_FLOWER_MAT_PETALS_FIRST 120
#define MATERIAL_FLOWER_MAT_LAST 123
// Last id the head/dye detection scans for (whole flower id range)
#define MATERIAL_FLOWER_DETECT_LAST 123
// Glowing dyed grass-blade tips. Firefly-bush tips (126) blink: the dye
// amount pulses in the geometry shader on per-blade phases, and the amber
// glows via chroma-keyed emission. Amethyst-dyed tips (125) glow constantly
// in the crystal's purple; the crystal itself keeps its own mask (55, the
// LPV emitter group), and the vanilla firefly bush is left untouched.
#define MATERIAL_AMETHYST_BLADE 125
#define MATERIAL_FIREFLY_BLADE 126

bool is_flower_mask(uint mask) {
    return uint(MATERIAL_FLOWER_FIRST) <= mask
        && mask <= uint(MATERIAL_FLOWER_LAST);
}

// Base bloom family for any flower id (tall lowers and ground blooms map
// onto the small families; small families map to themselves)
uint flower_base_family(uint mask) {
    if (mask == 109u) { return uint(MATERIAL_FLOWER_RED); }    // rose bush
    if (mask == 110u) { return uint(MATERIAL_FLOWER_YELLOW); } // sunflower
    if (mask == 111u || mask == 112u) {
        return uint(MATERIAL_FLOWER_PURPLE);                   // lilac, peony
    }
    if (mask == uint(MATERIAL_FLOWER_FIREFLY_BUSH)) {
        return uint(MATERIAL_FLOWER_YELLOW);                   // amber
    }
    return mask;
}
// Thin cutout plants: small/tall plants, leaves, plus the Shader Grass split-outs of
// tall/short grass and the flower-head masks. Sub-block-thin geometry: SSS models treat
// these as thin surfaces (full transmission baseline; no solid-cube rim, no
// silhouette-burial occlusion).
bool is_thin_plant_mask(uint mask) {
    return (2u <= mask && mask <= 5u)
        || mask == uint(MATERIAL_TALL_GRASS_LOWER)
        || mask == uint(MATERIAL_TALL_GRASS_UPPER)
        || mask == uint(MATERIAL_SHORT_GRASS)
        || is_flower_mask(mask)
        || mask == uint(MATERIAL_AMETHYST_BLADE)
        || mask == uint(MATERIAL_FIREFLY_BLADE);
}

#define MATERIAL_LAVA 39
#define MATERIAL_OPEN_EYEBLOSSOM 59
#define MATERIAL_NETHER_PORTAL 62
#define MATERIAL_END_PORTAL 63
#define MATERIAL_ITEM 100
#define MATERIAL_BOAT 101
#define MATERIAL_LIGHTNING_BOLT 102

// Special material for dragon death beams
#define MATERIAL_DRAGON_BEAM 103

#endif // INCLUDE_MISC_MATERIAL_MASKS
