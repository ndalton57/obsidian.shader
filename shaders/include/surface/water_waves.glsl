#if !defined INCLUDE_SURFACE_WATER_WAVES
#define INCLUDE_SURFACE_WATER_WAVES

// Water wave field: a 3-octave rotated-noise heightmap modulated by a very
// large "patchiness" mask (largeWaves), so open water rolls in broad swells
// while patchy areas stay calmer. The same heightmap drives the surface
// normals (finite differences), the parallax displacement of the surface
// texture, and the projected caustics pattern, so all three always agree.
// Samples CLOUD_NOISETEX (image/cloud_noises.png) - its .b channel is the
// wave noise; noisetex is NOT interchangeable here (its .b is blue noise).
// Hosts that already bind the sampler define CLOUD_NOISETEX first;
// otherwise it is declared here.

#ifndef CLOUD_NOISETEX
uniform sampler2D cloud_noisetex;
#define CLOUD_NOISETEX cloud_noisetex
#endif

const vec2 wave_size[3] = vec2[](
    vec2(48., 12.),
    vec2(12., 48.),
    vec2(32., 32.)
);

const float water_wave_radiance = 2.39996;

float waterCaustics(vec3 worldPos, vec3 sunVec, float surfacePos) {
    vec3 projectedPos = worldPos + (sunVec / abs(sunVec.y)) * surfacePos;
    vec2 pos = projectedPos.xz;

    float movement = frameTimeCounter * 0.035 * WATER_WAVE_SPEED;

    mat2 rotationMatrix = mat2(
        vec2(cos(water_wave_radiance), -sin(water_wave_radiance)),
        vec2(sin(water_wave_radiance), cos(water_wave_radiance))
    );

    float largeWaves = texture(CLOUD_NOISETEX, pos / 600.0).b;
    float largeWavesCurved = pow(1.0 - pow(1.0 - largeWaves, 2.5), 4.5);
    largeWavesCurved
        = mix(1.0 - largeWavesCurved, largeWavesCurved, PATCHY_WAVE_BLEND);

    float heightSum = 0.0;
    for (int i = 0; i < 3; i++) {
        pos = rotationMatrix * pos;
        heightSum += pow(
            abs(abs(texture(CLOUD_NOISETEX,
                            pos / wave_size[i] + largeWavesCurved * 0.5
                                + movement)
                            .b
                        * 2.0
                    - 1.0)
                    * 2.0
                - 1.0),
            1.0 + largeWavesCurved
        );
    }

    return exp(
        (1.0 + 5.0 * sqrt(largeWavesCurved)) * (heightSum / 3.0 - 0.5)
    );
}

float getWaterHeightmap(
    vec2 posxz,
    in float largeWaves,
    in float largeWavesCurved
) {
    vec2 pos = posxz;

    float movement = frameTimeCounter * 0.035 * WATER_WAVE_SPEED;

    mat2 rotationMatrix = mat2(
        vec2(cos(water_wave_radiance), -sin(water_wave_radiance)),
        vec2(sin(water_wave_radiance), cos(water_wave_radiance))
    );

    float heightSum = 0.0;
    for (int i = 0; i < 3; i++) {
        pos = rotationMatrix * pos;
        heightSum += texture(
            CLOUD_NOISETEX,
            pos / wave_size[i] + largeWavesCurved * 0.5 + movement
        ).b;
    }

    return (heightSum / 4.5) * max(largeWavesCurved, 0.3);
}

vec3 getWaveNormal(vec3 waterPos, vec3 playerpos) {
    float largeWaves = texture(CLOUD_NOISETEX, waterPos.xy / 600.0).b;
    float largeWavesCurved = pow(1.0 - pow(1.0 - largeWaves, 2.5), 4.5);
    largeWavesCurved
        = mix(1.0 - largeWavesCurved, largeWavesCurved, PATCHY_WAVE_BLEND);

#ifdef HYPER_DETAILED_WAVES
    float deltaPos = 0.025;
#else
    float deltaPos = mix(WAVES_A_RADIUS, WAVES_B_RADIUS, largeWavesCurved);
    // reduce high frequency detail as distance increases. reduces noise on
    // waves. why have more details than pixels?
    float range = min(length(playerpos) / (16.0 * 24.0), 3.0);
    deltaPos += range;
#endif

    vec2 coord = waterPos.xy;

    float h0 = getWaterHeightmap(coord, largeWaves, largeWavesCurved);
    float h1
        = getWaterHeightmap(coord + vec2(deltaPos, 0.0), largeWaves, largeWavesCurved);
    float h3
        = getWaterHeightmap(coord + vec2(0.0, deltaPos), largeWaves, largeWavesCurved);

    float xDelta = (h1 - h0) / deltaPos;
    float yDelta = (h3 - h0) / deltaPos;

    vec3 wave
        = normalize(vec3(xDelta, yDelta, 1.0 - pow(abs(xDelta + yDelta), 2.0)));

    return wave;
}

// Parallax the wave heightmap along the tangent-space view vector, so the
// surface detail has depth instead of reading as a flat scroll.
vec3 getParallaxDisplacement(vec3 waterPos, vec3 tangentViewVector) {
    float largeWaves = texture(CLOUD_NOISETEX, waterPos.xy / 600.0).b;
    float largeWavesCurved = pow(1.0 - pow(1.0 - largeWaves, 2.5), 4.5);
    largeWavesCurved
        = mix(1.0 - largeWavesCurved, largeWavesCurved, PATCHY_WAVE_BLEND);

    float waterHeight
        = getWaterHeightmap(waterPos.xy, largeWaves, largeWavesCurved);
    waterHeight = exp(-7.0 * exp(-7.0 * waterHeight)) * 0.25;

    vec3 parallaxPos = waterPos;
    parallaxPos.xy
        += (tangentViewVector.xy / -tangentViewVector.z) * waterHeight;

    return parallaxPos;
}

#endif // INCLUDE_SURFACE_WATER_WAVES
