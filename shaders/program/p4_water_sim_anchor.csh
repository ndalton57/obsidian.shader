/*
--------------------------------------------------------------------------------

  Obsidian Shader

  program/p4_water_sim_anchor.csh:
  Water ripple simulation - after a sim step, stamp the step timestamp and
  re-pin the grid anchor to the player (or their vehicle); the per-frame
  anchor updates every frame so the tick pass can measure player speed

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

layout (local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

const ivec3 workGroups = ivec3(1, 1, 1);

#if WATER_INTERACTION == 2

#include "/include/surface/water_sim_state.glsl"

uniform float frameTimeCounter;
uniform vec3 cameraPosition;
uniform vec3 relativeEyePosition;

uniform vec3 relativeVehiclePosition;
uniform bool isRiding;

void main() {
    if (abs(frameTimeCounter - lastFrameTimeCount) > WATER_SIM_FRAMETIME) {
        lastFrameTimeCount = frameTimeCounter;

        if (isRiding) {
            previousCameraPositionWave2 = cameraPosition - relativeVehiclePosition;
        } else {
            previousCameraPositionWave2 = cameraPosition - relativeEyePosition;
        }
    }

    if (isRiding) {
        previousCameraPositionWave = cameraPosition - relativeVehiclePosition;
    } else {
        previousCameraPositionWave = cameraPosition - relativeEyePosition;
    }
}

#else

void main() {}

#endif
