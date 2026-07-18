/*
--------------------------------------------------------------------------------

  Tachyon Shader

  program/p3_water_sim_b.csh:
  Water ripple simulation - second half-step of the wave equation. Reads the
  intermediate field (waveSim), integrates again, injects the splash source
  and writes the final field with its surface gradient (waveSim2), which the
  water surface samples for ripple normals

  Base water ripple shader from https://www.shadertoy.com/view/wdtyDH
  (heavily edited)

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

layout (local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

#if WATER_SIM_SCALE == 0
    #if WATER_SIM_DISTANCE == 1
        const ivec3 workGroups = ivec3(16, 16, 1);
    #elif WATER_SIM_DISTANCE == 2
        const ivec3 workGroups = ivec3(32, 32, 1);
    #elif WATER_SIM_DISTANCE == 3
        const ivec3 workGroups = ivec3(48, 48, 1);
    #else
        const ivec3 workGroups = ivec3(64, 64, 1);
    #endif
#elif WATER_SIM_SCALE == 1
    #if WATER_SIM_DISTANCE == 1
        const ivec3 workGroups = ivec3(32, 32, 1);
    #elif WATER_SIM_DISTANCE == 2
        const ivec3 workGroups = ivec3(64, 64, 1);
    #elif WATER_SIM_DISTANCE == 3
        const ivec3 workGroups = ivec3(96, 96, 1);
    #else
        const ivec3 workGroups = ivec3(128, 128, 1);
    #endif
#else
    #if WATER_SIM_DISTANCE == 1
        const ivec3 workGroups = ivec3(64, 64, 1);
    #elif WATER_SIM_DISTANCE == 2
        const ivec3 workGroups = ivec3(128, 128, 1);
    #elif WATER_SIM_DISTANCE == 3
        const ivec3 workGroups = ivec3(192, 192, 1);
    #else
        const ivec3 workGroups = ivec3(256, 256, 1);
    #endif
#endif

#if WATER_INTERACTION == 2

layout (rg16f) uniform readonly image2D waveSim;
layout (rgba16f) uniform image2D waveSim2;

const ivec2 resolution = ivec2(workGroups.x * 32, workGroups.y * 32);

uniform int frameCounter;
uniform float frameTimeCounter;

#include "/include/surface/water_sim_state.glsl"

// Make this a smaller number for a smaller timestep.
// Don't make it bigger than 1.4 or the universe will explode.
#if WATER_SIM_SCALE == 0
    const float delta = 0.6;
#elif WATER_SIM_SCALE == 1
    const float delta = 1.0;
#else
    const float delta = 1.4;
#endif

uniform bool onWaterSurface;
uniform vec3 vehicleLookVector;
uniform bool isRiding;
uniform int vehicleId;

// see entity.properties
#define ENTITY_BOAT 10101

void main() {
    if (abs(frameTimeCounter - lastFrameTimeCount) > WATER_SIM_FRAMETIME && (!noSimOngoing || onWaterSurface)) {
        ivec2 imgCoord = ivec2(gl_GlobalInvocationID.xy);
        float dist = length(imgCoord - 0.5 * resolution);
        if (dist >= resolution.x) return;

        ivec2 sampledCoord = imgCoord;
        sampledCoord = clamp(sampledCoord, ivec2(1), resolution - ivec2(1));

        vec2 oldState = imageLoad(waveSim, sampledCoord).rg;

        float pressure = oldState.x;
        float pVel = oldState.y;

        #if WATER_SIM_FRAMERATE == 30
            const int offset = 2;
        #else
            const int offset = 1;
        #endif

        float p_down = imageLoad(waveSim, clamp(sampledCoord + ivec2(0, -offset), ivec2(offset), resolution - ivec2(offset))).r;
        float p_left = imageLoad(waveSim, clamp(sampledCoord + ivec2(-offset, 0), ivec2(offset), resolution - ivec2(offset))).r;
        float p_right = imageLoad(waveSim, clamp(sampledCoord + ivec2(offset, 0), ivec2(offset), resolution - ivec2(offset))).r;
        float p_up = imageLoad(waveSim, clamp(sampledCoord + ivec2(0, offset), ivec2(offset), resolution - ivec2(offset))).r;

        // Apply horizontal wave function
        pVel += delta * (-2.0 * pressure + p_right + p_left) / 4.0;
        // Apply vertical wave function (these could just as easily have been one line)
        pVel += delta * (-2.0 * pressure + p_up + p_down) / 4.0;

        // Change pressure by pressure velocity
        pressure += delta * pVel;

        // "Spring" motion. This makes the waves look more like water waves and less like sound waves.
        pVel -= 0.0014 * delta * pressure;

        // Velocity damping so things eventually calm down
        pVel *= 1.0 - 0.006 * delta;

        // Pressure damping to prevent it from building up forever.
        float distFade = smoothstep(0.49 * resolution.x, 0.25 * resolution.x, dist);
        pressure *= 0.985 * distFade;
        pVel *= distFade;

        if (onWaterSurface) {
            if (isRiding && vehicleId == ENTITY_BOAT) {
                vec2 p = imgCoord - 0.5 * resolution;
                vec2 f = normalize(vehicleLookVector.xz);

                float t = dot(p, f);

                t = clamp(t, -waterRoundSize * 0.73, waterRoundSize * 0.73);

                float dist = length(p - f * t);

                float shape = smoothstep(waterRoundSize, 0.7 * waterRoundSize, dist);

                pressure += shape * (smoothstep(-waterRoundSize * 0.75, waterRoundSize * 0.75, t) * 2.0 - 1.0);
            } else {
                pressure += smoothstep(waterRoundSize, 0.7 * waterRoundSize, dist);
            }
        }

        imageStore(waveSim2, imgCoord, vec4(pressure, pVel, (p_right - p_left) / 2.0, (p_up - p_down) / 2.0));
    }
}

#else

void main() {}

#endif
