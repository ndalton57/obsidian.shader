#if !defined INCLUDE_MISC_MATERIAL_MASKS
#define INCLUDE_MISC_MATERIAL_MASKS

// Macros providing readable names for common material IDs

#define MATERIAL_WATER 1
#define MATERIAL_SMALL_PLANTS 2
#define MATERIAL_TALL_PLANTS_LOWER 3
#define MATERIAL_TALL_PLANTS_UPPER 4
#define MATERIAL_LEAVES 5
// Shader Grass: grass_block tagged in block.properties so the solid terrain
// geometry shader can detect grass-block tops. Not used by Tachyon's shading -
// the GS resets it to 0 on the block's own (passthrough) geometry.
#define MATERIAL_GRASS_BLOCK 81
// Shader Grass: tall_grass/large_fern, split out of MATERIAL_TALL_PLANTS so the grass
// shader can detect them colour-independently and lift the grass-block-top blades taller
// where they sit (reusing the bushiness field - no extra geometry). Detection-only like
// grass_block: the flat cross is hidden on grass blocks; beyond range it stays a tall plant.
#define MATERIAL_TALL_GRASS_LOWER 82
#define MATERIAL_TALL_GRASS_UPPER 83
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
