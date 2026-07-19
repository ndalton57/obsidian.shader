#if !defined INCLUDE_FOG_END_FOG_VL
#define INCLUDE_FOG_END_FOG_VL

/*
  End storm volumetrics.

  One 16-sample exponential march renders, together:
    - the swirling storm clouds orbiting the main island (pseudo-3D noise
      swirled around the origin, carved so the island itself and a torus ring
      around it stay clear — the fog "surrounds" the dragon island)
    - the void fog rising from below y = -60
    - the chaotic End thunder: a wandering light source near the camera
      (snapped to 200-block world cells) that flashes at hashed intervals and
      hands over to a static vortex light at the world origin inside
      END_LIGHTNING range
    - a faint blue distance haze (END_HAZE_DENSTIY)

  The flash lighting path (endFogPhase, LightSourceLighting, and the thunder
  state in program/e0_end_thunder.csh): a tight exp(-L/50) phase (wider halo
  variants wash out the strike), a fixed-step fog-shadow march with
  exp(-7*shadow) extinction, and a chromatic multi-scatter term that carries
  the flash through the cloud interior.

  Terrain lighting is untouched — all light here is fog-internal, colored by
  Obsidian's settings (VORTEX_LIGHT_COL_*, END_LIGHTNING_COL_*), with
  END_FOG_BRIGHTNESS as the single bridge into Obsidian's exposure.
*/

#include "/include/utility/fast_math.glsl"
#include "/include/utility/random.glsl"

const float vortexBoundRange = 300.0;

#include "/include/fog/fog_density_noise.glsl"

// Create a rising swirl centered around the world origin
void SwirlAroundOrigin(inout vec3 alteredOrigin, vec3 origin) {
    float radiance = 2.39996 + alteredOrigin.y / 1.5 + frameTimeCounter / 50.0;
    mat2 rotationMatrix = mat2(
        vec2(cos(radiance), -sin(radiance)),
        vec2(sin(radiance), cos(radiance))
    );

    // make the swirl only happen within a radius
    float SwirlBounds = clamp(
        sqrt(length(vec3(origin.x, origin.y - 100.0, origin.z)) / 200.0 - 1.0),
        0.0,
        1.0
    );

    alteredOrigin.xz
        = mix(alteredOrigin.xz * rotationMatrix, alteredOrigin.xz, SwirlBounds);
}

// Control where the fog volume should and should not be using a sphere and a
// torus — this carves the island and a clear ring around it out of the storm
void VolumeBounds(inout float Volume, vec3 Origin) {
    vec3 Origin2 = (Origin - vec3(0.0, 100.0, 0.0));
    Origin2.y *= 0.8;
    float Center1 = length(Origin2);

    float Bounds = max(1.0 - Center1 / 75.0, 0.0) * 5.0;

    float radius = 150.0;
    float thickness = 50.0 * radius;
    float Torus = (thickness
                   - clamp(
                       pow(length(vec2(length(Origin.xz) - radius, Origin2.y)),
                           2.0)
                           - radius,
                       0.0,
                       thickness
                   ))
        / thickness;

    Volume = max(Volume - Bounds - Torus, 0.0);
}

// The storm volume shape
float fogShape(in vec3 pos) {
    float vortexBounds = clamp(vortexBoundRange - length(pos), 0.0, 1.0);
    vec3 samplePos = pos * vec3(1.0, 1.0 / 48.0, 1.0);

    // this is below down where you fall to your death
    float voidZone = max(exp2(-1.0 * sqrt(max(pos.y - -60.0, 0.0))), 0.0);

    // swirly swirly :DDDDDDDDDDD
    SwirlAroundOrigin(samplePos, pos);

    float noise = densityAtPosFog(samplePos * 12.0);
    float erosion = 1.0
        - densityAtPosFog(
            (samplePos - frameTimeCounter / 20.0) * (124.0 + (1.0 - noise) * 7.0)
        );

    float clumpyFog = max(
        exp(noise * -mix(10.0, 4.0, vortexBounds)) * mix(2.0, 1.0, vortexBounds)
            - erosion * 0.3,
        0.0
    );

    VolumeBounds(clumpyFog, pos);

    return clumpyFog + voidZone;
}

float endFogPhase(vec3 LightPos) {
    float mie = exp(length(LightPos) / -50.0);

    return (mie * 10.0) * (mie * 10.0);
}

vec3 LightSourceColors(float vortexBounds, float lightningflash) {
    vec3 vortexColor
        = vec3(VORTEX_LIGHT_COL_R, VORTEX_LIGHT_COL_G, VORTEX_LIGHT_COL_B);
    vec3 lightningColor
        = vec3(END_LIGHTNING_COL_R, END_LIGHTNING_COL_G, END_LIGHTNING_COL_B)
        * lightningflash;

    return mix(lightningColor, vortexColor, vortexBounds);
}

// Position of the currently active light source, as a vector from the light
// to worldPos. Inside the vortex range this is the static vortex light at the
// world origin; outside it is the wandering thunder source near the camera.
vec3 LightSourcePosition(
    vec3 worldPos,
    vec3 cameraPos,
    float vortexBounds,
    vec3 lightning_offset
) {
    vec3 vortexPos = worldPos - vec3(0.0, 200.0, 0.0);

    vec3 lightningPos = worldPos - cameraPos;

    // snap-to coordinates in worldspace
    float cellSize = 200.0;
    lightningPos += fract(cameraPos / cellSize) * cellSize - cellSize * 0.5;

    lightningPos -= lightning_offset;

    return mix(lightningPos, vortexPos, vortexBounds);
}

vec3 LightSourceLighting(
    vec3 startPos,
    vec3 lightPos,
    float noise,
    float density,
    vec3 lightColor,
    float vortexBound
) {
    float phase = endFogPhase(lightPos);
    float shadow = 0.0;

    for (int j = 0; j < 3; j++) {
        vec3 shadowSamplePos = startPos - lightPos * (0.05 + j * 0.25);
        shadow += fogShape(shadowSamplePos);
    }

    // Direct light with fog self-shadowing, plus a chromatic multi-scatter
    // term inside dense fog: the vec3(0.6, 2.0, 2.0) absorption lets red
    // penetrate deepest, so flash light visibly diffuses through the cloud
    // body instead of stopping at its surface
    vec3 finalLighting = lightColor * phase * exp(-7.0 * shadow);

    finalLighting += lightColor * phase * phase
        * (1.0 - exp(-shadow * vec3(0.6, 2.0, 2.0)))
        * (1.0 - exp(-density * density));

    return finalLighting;
}

mat2x3 raymarch_end_fog(
    vec3 world_start_pos,
    vec3 world_end_pos,
    bool sky,
    float dither
) {
    float dither2 = fract(dither * golden_ratio);

    // ------------- raymarching setup -------------

    vec3 dVWorld = world_end_pos - world_start_pos;

    float maxLength = min(length(dVWorld), 32.0 * 12.0) / length(dVWorld);
    dVWorld *= maxLength;

    float dL = length(dVWorld);
    const float expFactor = 11.0;
    const int SAMPLECOUNT = 16;

    // ------------- thunder schedule -------------

    // The thunder state (countdown timer, temporally-blended flash,
    // random-walk position) is updated once per frame by
    // program/e0_end_thunder.csh into the persistent end_state_img:
    //   lightningflash = flash texel; the offset = position texel * 2 - 1
    //   (the walk exceeds [0,1], so the decoded offset ranges far past ±1).
    float lightningflash = 0.0;
    vec3 lightning_offset = vec3(0.0);
#ifdef END_LIGHTNING
    lightningflash = texelFetch(end_state_sampler, ivec2(0, 0), 0).y;
    lightning_offset
        = (texelFetch(end_state_sampler, ivec2(1, 0), 0).xyz * 2.0 - 1.0)
        * 2.5;
#endif

    // ------------- color/lighting -------------

    vec3 color = vec3(0.0);
    float absorbance = 1.0;

    float skyPhase = 0.5
        + pow(clamp(normalize(dVWorld).y * 0.5 + 0.5, 0.0, 1.0), 4.0) * 5.0;

    for (int i = 0; i < SAMPLECOUNT; i++) {
        float d = (pow(expFactor, float(i + dither) / float(SAMPLECOUNT))
                       / expFactor
                   - 1.0 / expFactor)
            / (1.0 - 1.0 / expFactor);
        float dd = pow(expFactor, float(i + dither) / float(SAMPLECOUNT))
            * log(expFactor) / float(SAMPLECOUNT) / (expFactor - 1.0);

        vec3 progressW = world_start_pos + d * dVWorld;

        // ------ end storm effect

        // determine where the vortex area ends and the chaotic lightning
        // area begins
#ifdef END_LIGHTNING
        float vortexBounds
            = clamp(vortexBoundRange - length(progressW), 0.0, 1.0);
#else
        const float vortexBounds = 1.0;
#endif

        vec3 lightPosition = LightSourcePosition(
            progressW, cameraPosition, vortexBounds, lightning_offset
        );
        vec3 lightColors = LightSourceColors(vortexBounds, lightningflash);

        float volumeDensity = fogShape(progressW);

        float clearArea = 1.0
            - min(max(1.0 - length(progressW - cameraPosition) / 100.0, 0.0),
                  1.0);
        float stormDensity
            = min(volumeDensity, clearArea * clearArea * END_STORM_DENSTIY);

        float volumeCoeff = exp(-stormDensity * dd * dL);

        vec3 lightsources = LightSourceLighting(
            progressW, lightPosition, dither2, volumeDensity, lightColors,
            vortexBounds
        );
        vec3 indirect = vec3(0.5, 0.75, 1.0) * 0.2
            * (exp((volumeDensity * volumeDensity) * -50.0) * 0.9 + 0.1);
        vec3 stormLighting = indirect + lightsources;

        color += (stormLighting - stormLighting * volumeCoeff) * absorbance;
        absorbance *= volumeCoeff;

        // ------ haze effect
        // the haze does not contribute to absorbance
        float hazeDensity = 0.001 * END_HAZE_DENSTIY;
        vec3 hazeLighting = vec3(0.3, 0.6, 1.0) * skyPhase;
        color += (hazeLighting - hazeLighting * exp(-hazeDensity * dd * dL))
            * absorbance;
    }

    color *= END_FOG_BRIGHTNESS;

    return mat2x3(color, vec3(absorbance));
}

#endif // INCLUDE_FOG_END_FOG_VL
