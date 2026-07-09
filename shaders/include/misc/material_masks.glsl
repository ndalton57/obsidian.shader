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
// Thin cutout plants: small/tall plants, leaves, plus the Shader Grass split-outs of
// tall/short grass. Sub-block-thin geometry: SSS models treat these as thin surfaces
// (full transmission baseline; no solid-cube rim, no silhouette-burial occlusion).
bool is_thin_plant_mask(uint mask) {
    return (2u <= mask && mask <= 5u)
        || mask == uint(MATERIAL_TALL_GRASS_LOWER)
        || mask == uint(MATERIAL_TALL_GRASS_UPPER)
        || mask == uint(MATERIAL_SHORT_GRASS);
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
