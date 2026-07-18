/*
--------------------------------------------------------------------------------

  Tachyon Shader

  program/p1_water_sim_tick.csh:
  Water ripple simulation - per-step bookkeeping: latches the all-calm flag,
  converts player movement into whole-texel grid scrolls, and sizes the
  splash source from player/vehicle speed

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

layout (local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

const ivec3 workGroups = ivec3(1, 1, 1);

#if WATER_INTERACTION == 2

#include "/include/surface/water_sim_state.glsl"

uniform vec3 cameraPosition;
uniform vec3 relativeEyePosition;
uniform float frameTimeCounter;
uniform float frameTime;

uniform bool onWaterSurface;
uniform int vehicleId;
uniform vec3 relativeVehiclePosition;
uniform bool isRiding;

// see entity.properties
#define ENTITY_BOAT 10101

vec2 getPlayerMovementOffset() {
    vec2 currentPos = cameraPosition.xz;

    if (isRiding) {
        currentPos -= relativeVehiclePosition.xz;
    } else {
        currentPos -= relativeEyePosition.xz;
    }

    vec2 previousPos = previousCameraPositionWave2.xz;
    vec2 movement = currentPos - previousPos;
#if WATER_SIM_SCALE == 0
    return -20.0 * movement;
#else
    return -40.0 * movement * WATER_SIM_SCALE;
#endif
}

void main() {
    if (abs(frameTimeCounter - lastFrameTimeCount) > WATER_SIM_FRAMETIME) {
        noSimOngoing = noSimOngoingCheck;
        noSimOngoingCheck = true;

        bool inBoat = vehicleId == ENTITY_BOAT;

        vec2 playerMovement = getPlayerMovementOffset();
        water_move_compensation_counter_SSBO += playerMovement;

        water_move_compensationSSBO = ivec2(0);
        ivec2 offset = ivec2(trunc(water_move_compensation_counter_SSBO));
        if (any(notEqual(offset, ivec2(0)))) {
            water_move_compensationSSBO = offset;
            water_move_compensation_counter_SSBO -= vec2(offset);
        }

        if (onWaterSurface) {
            vec3 position = cameraPosition - previousCameraPositionWave;
            if (isRiding) {
                position -= relativeVehiclePosition;
            } else {
                position -= relativeEyePosition;
            }

            vec3 velocity = position / frameTime;
            velocity.y *= 1.2;
            float speed = length(velocity);

            float size = 10.0;
            if (inBoat) {
                size += 23.0;
            } else {
                size += 10.0 * smoothstep(0.1, 13.0, speed);
            }

#if WATER_SIM_SCALE == 0
            size *= 0.5;
#else
            size *= WATER_SIM_SCALE;
#endif

            if (speed < 0.15 && isRiding) size = 0.01;

            waterRoundSize = size;
        }
    }
}

#else

void main() {}

#endif
