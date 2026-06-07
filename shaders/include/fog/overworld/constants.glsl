#if !defined INCLUDE_FOG_OVERWORLD_CONSTANTS
#define INCLUDE_FOG_OVERWORLD_CONSTANTS

const uint air_fog_min_step_count = 8;
const uint air_fog_max_step_count = 25;
const float air_fog_step_count_growth = 0.1;

// Current world's height, used to scale the bedrock fog's upward dissipation rate
// so the fog rises to the same fraction of any world (see bedrock_fog_half_life).
// This is the REAL height of whatever world is loaded - not a hardcoded reference.
// Iris-exclusive; reads 0 on OptiFine / older Iris, in which case the dissipation
// is left unscaled.
uniform int heightLimit;

// The world's REAL floor (Iris bedrockLevel). The bedrock fog anchors here so it
// pools at the very bottom of ANY world - including ones extended far below -64.
// Reads 0 on OptiFine / older Iris (and dimensions without it); we fall back to the
// SEA_LEVEL setting then. See air_fog_anchor().
uniform int bedrockLevel;

const float air_fog_volume_top = 320.0;
const vec2 air_fog_falloff_half_life
    = vec2(AIR_FOG_RAYLEIGH_FALLOFF_HALF_LIFE, AIR_FOG_MIE_FALLOFF_HALF_LIFE);

// Anchor (floor) for the air fog. With BEDROCK_FOG it is the world's real bedrock
// level, so the fog sits at the bottom of any world no matter how far it extends
// below -64. Without it (stock Photon air fog), or when bedrockLevel is unavailable,
// it is the SEA_LEVEL setting - i.e. stock behaviour is unchanged.
float air_fog_anchor() {
#if defined BEDROCK_FOG
    if (bedrockLevel != 0) {
        return float(bedrockLevel);
    }
#endif
    return SEA_LEVEL;
}

vec2 air_fog_falloff_start() {
    return vec2(AIR_FOG_RAYLEIGH_FALLOFF_START, AIR_FOG_MIE_FALLOFF_START)
        + air_fog_anchor();
}

float air_fog_volume_bottom() { return air_fog_anchor() - 24.0; }

// The bedrock fog's upward dissipation rate (the falloff half-life), scaled to the
// current world's height so the fog reaches the same FRACTION of any world and
// always sits low - per the request to scale dissipation by world height. The
// dense base is anchored at the world floor (bedrockLevel), so this
// changes only how fast the fog thins UPWARD; it never thins the base, so the fog
// stays visible in any world. BEDROCK_FOG_DISSIPATION is the rayleigh half-life as
// a fraction of world height; the rayleigh:mie ratio (the density shape) is kept.
// Falls back to the unscaled half-life when the bedrock fog is off or the world
// height is unavailable - the fog still works, just at a fixed dissipation rate.
vec2 bedrock_fog_half_life() {
#if defined BEDROCK_FOG
    if (heightLimit > 0) {
        return air_fog_falloff_half_life
            * (BEDROCK_FOG_DISSIPATION * float(heightLimit)
               / air_fog_falloff_half_life.x);
    }
#endif
    return air_fog_falloff_half_life;
}

#endif // INCLUDE_FOG_OVERWORLD_CONSTANTS
