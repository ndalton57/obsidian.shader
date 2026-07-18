#if !defined INCLUDE_SURFACE_WATER_SIM_STATE
#define INCLUDE_SURFACE_WATER_SIM_STATE

// Persistent state for the interactive water-ripple simulation
// (WATER_INTERACTION mode 2). The ripple field lives in the waveSim/waveSim2
// image pair; this buffer carries everything that must survive between
// frames: the sim-step timer, the camera anchor the grid is pinned to,
// whole-texel scroll compensation for player movement, the splash source
// radius, and the all-calm flag that lets the passes idle while every ripple
// has died down.
layout(std430, binding = 4) buffer WaterSimState {
    float waterRoundSize;                      // splash source radius (sim texels)
    float lastFrameTimeCount;                  // timestamp of the last sim step
    vec3 previousCameraPositionWave;           // per-frame player anchor (speed)
    vec3 previousCameraPositionWave2;          // per-step player anchor (grid pin)
    bool noSimOngoing;                         // no pressure anywhere last step
    bool noSimOngoingCheck;                    // accumulator for the flag above
    ivec2 water_move_compensationSSBO;         // whole-texel grid scroll this step
    vec2 water_move_compensation_counter_SSBO; // fractional-texel remainder
};

#endif // INCLUDE_SURFACE_WATER_SIM_STATE
