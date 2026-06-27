#if !defined INCLUDE_LIGHTING_LPV_LIGHT_COLORS
#define INCLUDE_LIGHTING_LPV_LIGHT_COLORS

const vec3[40] light_color = vec3[40](
    vec3(1.00, 1.00, 1.00) * 12.0, // Strong white light
    vec3(1.00, 1.00, 1.00) * 6.0, // Medium white light
    vec3(1.00, 1.00, 1.00) * 1.0, // Weak white light
    vec3(1.00, 0.55, 0.27) * 14.0, // Strong golden light
    vec3(1.00, 0.57, 0.30) * 8.0, // Medium golden light
    vec3(1.00, 0.57, 0.30) * 6.0, // Weak golden light
    vec3(1.00, 0.18, 0.10) * 5.0, // Redstone components
    vec3(1.00, 0.38, 0.10) * 7.0, // Lava
    vec3(1.00, 0.45, 0.10) * 9.0, // Medium orange light
    vec3(1.00, 0.63, 0.15) * 4.0, // Brewing stand
    vec3(1.00, 0.57, 0.30) * 12.0, // Medium golden light
    vec3(0.45, 0.73, 1.00) * 6.0, // Soul lights
    vec3(0.45, 0.73, 1.00) * 14.0, // Beacon
    vec3(0.75, 1.00, 0.83) * 3.0, // Sculk
    vec3(0.75, 1.00, 0.83) * 1.0, // End portal frame
    vec3(0.60, 0.10, 1.00) * 2.5, // Pink glow
    vec3(0.75, 1.00, 0.50) * 1.0, // Sea pickle
    vec3(1.00, 0.50, 0.25) * 4.0, // Nether plants
    vec3(1.00, 0.57, 0.30) * 8.0, // Medium golden light
    vec3(1.00, 0.65, 0.30) * 8.0, // Ochre froglight
    vec3(0.86, 1.00, 0.44) * 8.0, // Verdant froglight
    vec3(0.75, 0.44, 1.00) * 8.0, // Pearlescent froglight
    vec3(0.60, 0.10, 1.00) * 2.0, // Enchanting table
    vec3(0.75, 0.44, 1.00) * 4.0, // Amethyst cluster
    vec3(0.75, 0.44, 1.00) * 4.0, // Calibrated sculk sensor
    vec3(0.75, 1.00, 0.83) * 6.0, // Active sculk sensor
    vec3(1.00, 0.18, 0.10) * 3.3, // Redstone block
    vec3(1.00, 0.50, 0.25) * 3.0, // Open eyeblossom
    vec3(0.85, 1.3, 1.0) * 3.9, // Copper torch and lanterns
    vec3(1.00, 0.57, 0.30) * 8.0, // Copper Bulbs
    vec3(0.60, 0.10, 1.00) * 12.0, // Nether portal
    vec3(0.0), // End portal
    // Glowing ores (GLOWING_ORE): dim per-ore pools, colored to match each
    // vein (normalize(color) precomputed - const initializers need literals).
    // Voxelization remaps ore blocks 86-92 to emitter IDs 96-102 -> these
    // indices 32-38. GLOWING_ORE_INTENSITY only dims (1.0 = ceiling), and
    // scales the pool with the vein glow so they stay matched
    vec3(0.049, 0.988, 0.148) * GLOWING_ORE_INTENSITY, // Emerald ore
    vec3(0.092, 0.370, 0.924) * GLOWING_ORE_INTENSITY, // Diamond ore
    vec3(0.619, 0.722, 0.309) * GLOWING_ORE_INTENSITY, // Copper ore
    vec3(0.000, 0.083, 0.996) * GLOWING_ORE_INTENSITY, // Lapis ore
    vec3(0.797, 0.598, 0.080) * GLOWING_ORE_INTENSITY, // Gold ore
    vec3(0.814, 0.465, 0.349) * GLOWING_ORE_INTENSITY, // Iron ore
    vec3(0.999, 0.050, 0.000) * GLOWING_ORE_INTENSITY, // Redstone ore
    vec3(0.0) // (free slot)
);

const vec3[16] tint_color = vec3[16](
    vec3(1.0, 0.1, 0.1), // Red
    vec3(1.0, 0.5, 0.1), // Orange
    vec3(1.0, 1.0, 0.1), // Yellow
    vec3(0.7, 0.7, 0.0), // Brown
    vec3(0.1, 1.0, 0.1), // Green
    vec3(0.5, 1.0, 0.5), // Lime
    vec3(0.1, 0.1, 1.0), // Blue
    vec3(0.5, 0.5, 1.0), // Light blue
    vec3(0.1, 1.0, 1.0), // Cyan
    vec3(0.7, 0.1, 1.0), // Purple
    vec3(1.0, 0.1, 1.0), // Magenta
    vec3(1.0, 0.5, 1.0), // Pink
    vec3(0.1, 0.1, 0.1), // Black
    vec3(0.9, 0.9, 0.9), // White
    vec3(0.3, 0.3, 0.3), // Gray
    vec3(0.7, 0.7, 0.7) // Light gray
);

#endif // INCLUDE_LIGHTING_LPV_LIGHT_COLORS
