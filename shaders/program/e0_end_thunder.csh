/*
--------------------------------------------------------------------------------

  Tachyon Shader

  program/e0_end_thunder:
  Per-frame End thunder state.

  Three temporally-blended texels drive the thunder (they live in the
  persistent end_state_img):
    - a countdown timer: on expiry the flash fires for one frame and the
      timer rearms to hash(frameCounter)^5 * 5 seconds (bursty waits)
    - the flash value, blended toward the trigger with 4*frameTime per frame
      (each strike bumps it ~0.07 at 60fps and it decays at 4/s — isolated
      strikes are dim blips, rapid bursts pump it toward ~0.3)
    - the light position: a RANDOM WALK in the [0,1]-encoded space. Every
      frame the same hash step (re-rolled each 50 frames) is added, so the
      position accumulates drift far beyond one cell — the wide wander only
      works because the walk is NOT clamped to [0,1]; the storage clamp
      floors it at encoded 0 (decoded -1). While the timer is young (a long
      wait just started) the walk is pulled back to encoded zero.

  Texel layout of end_state_img (2x1 rgba32f):
    texel (0,0): x = timer, y = blended flash
    texel (1,0): xyz = walked position ([0,1]-encoded)

--------------------------------------------------------------------------------
*/

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
const ivec3 workGroups = ivec3(1, 1, 1);

layout(rgba32f) uniform image2D end_state_img;

uniform float frameTime;
uniform int frameCounter;

// Hash without sine (Dave Hoskins)
float thunder_hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

vec3 thunder_hash31(float p) {
    vec3 p3 = fract(vec3(p) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xxy + p3.yzz) * p3.zyx);
}

void main() {
    vec4 state0 = imageLoad(end_state_img, ivec2(0, 0));
    vec4 state1 = imageLoad(end_state_img, ivec2(1, 0));

    const float maxWaitTime = 5.0;

    // ---------------------- TIMER ----------------------
    float Timer = state0.x;
    Timer -= frameTime;

    float flash = 0.0;
    if (Timer <= 0.0) {
        flash = 1.0;
        Timer = pow(thunder_hash11(float(frameCounter)), 5.0) * maxWaitTime;
    }

    float flash_blended
        = mix(state0.y, flash, clamp(4.0 * frameTime, 0.0, 1.0));

    // ---------------------- POSITION ----------------------
    vec3 LastPos = state1.xyz * 2.0 - 1.0;

    LastPos += (thunder_hash31(float(frameCounter / 50)) * 2.0 - 1.0);
    LastPos = LastPos * 0.5 + 0.5;

    if (Timer > maxWaitTime * 0.7) {
        LastPos = vec3(0.0);
    }

    vec3 pos_blended
        = mix(state1.xyz, LastPos, clamp(500.0 * frameTime, 0.0, 1.0));

    // The storage clamp's 0 floor is what stops the position walk at
    // decoded -1 — the wander breaks if this clamp is widened
    imageStore(
        end_state_img,
        ivec2(0, 0),
        clamp(vec4(Timer, flash_blended, 0.0, 0.0), 0.0, 65000.0)
    );
    imageStore(
        end_state_img,
        ivec2(1, 0),
        clamp(vec4(pos_blended, 0.0), 0.0, 65000.0)
    );
}
