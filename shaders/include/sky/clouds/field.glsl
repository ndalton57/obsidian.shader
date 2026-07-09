#if !defined INCLUDE_SKY_CLOUDS_FIELD
#define INCLUDE_SKY_CLOUDS_FIELD

/*
  Volumetric cloud field: three cloud layers rendered by one marcher.

  Three layers:
    layer 0 — large cumulus slab,  CloudLayer0_height .. +100 blocks
    layer 1 — small cumulus slab,  CloudLayer1_height .. +100 blocks
    layer 2 — flat altostratus plane at CloudLayer2_height

  Rain drives the overcast directly: coverage/density blend toward
  Rain_coverage / storm values with rainStrength (see the LAYERn_* globals).

  Transport around the field: quarter-res checkerboard render in
  d1_clouds, temporal upscaling in d2 (which needs the apparent_distance this
  file accumulates), and distance-based compositing in d4. The clouds are
  NEVER rendered into the d0 sky map: that map feeds the ambient SH and the
  sky reflections, and cloud cover must not change ambient brightness - storm
  darkening comes from the cloud shadow map on the sun instead, so sky-map
  reflections stay cloudless by design.

  Cloud shapes sample CLOUD_NOISETEX (image/cloud_noises.png, an Iris
  customTexture sampler named cloud_noisetex — every colortex slot is taken by
  a real buffer in the deferred stage) — NOT noisetex, whose channels
  hold different content. Host programs must define CLOUD_NOISETEX before
  including this file.

  renderLayer accumulates an opacity-weighted mean hit distance for the
  temporal reprojection, and terrain intersection uses the caller-supplied
  distance_to_terrain (Voxy-aware in d1) rather than reconstructing it from
  the depth buffer.

  WsunVec is the world light vector flipped to the active shadow light —
  light_dir; SignedWsunvec is sun_dir. LightColor/SkyColor come from the host
  program's sun_color/moon_color/sky_color.
*/

#include "/include/sky/clouds/common.glsl"

#ifdef Daily_Weather
// Day-to-day weather profiles: ten day slots selected by
// worldDay, hard-switched at dawn (the temporal accumulation cross-fades the
// deck over a second). The .w components carry per-day fog densities,
// reserved for the storm fog and unused by the cloud layers themselves.
#ifdef CHOOSE_RANDOM_WEATHER_PROFILE
float daily_weather_hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}
#endif

int daily_weather_profile(float day) {
#ifdef CHOOSE_RANDOM_WEATHER_PROFILE
    return int(clamp(daily_weather_hash11(mod(day, 1000.0)) * 10.0, 0.0, 10.0));
#else
    return int(mod(day, 10.0));
#endif
}

int daily_weather_day = daily_weather_profile(float(worldDay));
int daily_weather_day_prev = daily_weather_profile(float(worldDay) - 1.0 + 1000.0);

// A hard switch at dawn would pop, so the day change eases from yesterday's
// profile across the first 400 ticks after the day rolls over (roughly a
// ten-second fade) — frame-rate independent, and identical after a reload
// mid-transition.
float daily_weather_blend = smoothstep(0.0, 400.0, float(worldTime));

vec4 daily_weather_coverage(int day) {
    vec4 table[10] = vec4[](
        vec4(DAY0_l0_coverage, DAY0_l1_coverage, DAY0_l2_coverage, DAY0_ufog_density),
        vec4(DAY1_l0_coverage, DAY1_l1_coverage, DAY1_l2_coverage, DAY1_ufog_density),
        vec4(DAY2_l0_coverage, DAY2_l1_coverage, DAY2_l2_coverage, DAY2_ufog_density),
        vec4(DAY3_l0_coverage, DAY3_l1_coverage, DAY3_l2_coverage, DAY3_ufog_density),
        vec4(DAY4_l0_coverage, DAY4_l1_coverage, DAY4_l2_coverage, DAY4_ufog_density),
        vec4(DAY5_l0_coverage, DAY5_l1_coverage, DAY5_l2_coverage, DAY5_ufog_density),
        vec4(DAY6_l0_coverage, DAY6_l1_coverage, DAY6_l2_coverage, DAY6_ufog_density),
        vec4(DAY7_l0_coverage, DAY7_l1_coverage, DAY7_l2_coverage, DAY7_ufog_density),
        vec4(DAY8_l0_coverage, DAY8_l1_coverage, DAY8_l2_coverage, DAY8_ufog_density),
        vec4(DAY9_l0_coverage, DAY9_l1_coverage, DAY9_l2_coverage, DAY9_ufog_density)
    );
    return table[day];
}

vec4 daily_weather_density(int day) {
    vec4 table[10] = vec4[](
        vec4(DAY0_l0_density, DAY0_l1_density, DAY0_l2_density, DAY0_cfog_density),
        vec4(DAY1_l0_density, DAY1_l1_density, DAY1_l2_density, DAY1_cfog_density),
        vec4(DAY2_l0_density, DAY2_l1_density, DAY2_l2_density, DAY2_cfog_density),
        vec4(DAY3_l0_density, DAY3_l1_density, DAY3_l2_density, DAY3_cfog_density),
        vec4(DAY4_l0_density, DAY4_l1_density, DAY4_l2_density, DAY4_cfog_density),
        vec4(DAY5_l0_density, DAY5_l1_density, DAY5_l2_density, DAY5_cfog_density),
        vec4(DAY6_l0_density, DAY6_l1_density, DAY6_l2_density, DAY6_cfog_density),
        vec4(DAY7_l0_density, DAY7_l1_density, DAY7_l2_density, DAY7_cfog_density),
        vec4(DAY8_l0_density, DAY8_l1_density, DAY8_l2_density, DAY8_cfog_density),
        vec4(DAY9_l0_density, DAY9_l1_density, DAY9_l2_density, DAY9_cfog_density)
    );
    return table[day];
}

vec4 dailyWeatherParams0 = mix(
    daily_weather_coverage(daily_weather_day_prev),
    daily_weather_coverage(daily_weather_day),
    daily_weather_blend
);
vec4 dailyWeatherParams1 = mix(
    daily_weather_density(daily_weather_day_prev),
    daily_weather_density(daily_weather_day),
    daily_weather_blend
);
#else
// Static layer settings; rain blends toward storm values below, same as the
// daily path.
vec4 dailyWeatherParams0 = vec4(
    CloudLayer0_coverage,
    CloudLayer1_coverage,
    CloudLayer2_coverage,
    0.0
);
vec4 dailyWeatherParams1 = vec4(
    CloudLayer0_density,
    CloudLayer1_density,
    CloudLayer2_density,
    0.0
);
#endif

float LAYER0_width = 100.0;
float LAYER0_minHEIGHT = CloudLayer0_height;
float LAYER0_maxHEIGHT = LAYER0_width + LAYER0_minHEIGHT;

float LAYER1_width = 100.0;
float LAYER1_minHEIGHT = max(CloudLayer1_height, LAYER0_maxHEIGHT);
float LAYER1_maxHEIGHT = LAYER1_width + LAYER1_minHEIGHT;

float LAYER2_HEIGHT = max(CloudLayer2_height, LAYER1_maxHEIGHT);

float LAYER0_COVERAGE = mix(dailyWeatherParams0.x, Rain_coverage, rainStrength);
float LAYER1_COVERAGE = mix(dailyWeatherParams0.y, 0.0, rainStrength);
float LAYER2_COVERAGE = mix(dailyWeatherParams0.z, 1.5, rainStrength);

float LAYER0_DENSITY = mix(dailyWeatherParams1.x, 1.0, rainStrength);
float LAYER1_DENSITY = mix(dailyWeatherParams1.y, 0.0, rainStrength);
float LAYER2_DENSITY = mix(dailyWeatherParams1.z, 0.05, rainStrength);

// cloud_time is the smoothed tick/24 clock from shaders.properties — raw
// worldTime snaps on server time-sync corrections, teleporting the deck
float cloud_movement = cloud_time * Cloud_Speed;

// 3D noise from the 2D noise texture (y/x channel pair, y-sliced)
float densityAtPos(in vec3 pos) {
    pos /= 18.0;
    pos.xz *= 0.5;

    vec3 p = floor(pos);
    vec3 f = fract(pos);

    vec2 uv = p.xz + f.xz + p.y * vec2(0.0, 193.0);
    vec2 coord = uv / 512.0;

    // the y channel has an offset to avoid using two texture fetches
    vec2 xy = texture(CLOUD_NOISETEX, coord).yx;

    return mix(xy.r, xy.g, f.y);
}

float GetAltostratusDensity(vec3 pos) {
    float large = 1.0
        - texture(CLOUD_NOISETEX, (pos.xz + cloud_movement) / 100000.0).b;
    large = max(large + LAYER2_COVERAGE - 0.7, 0.0);

    float medium = 1.0
        - texture(
                CLOUD_NOISETEX,
                (pos.xz - cloud_movement) / 7500.0
                    + vec2(-large, 1.0 - large) / 5.0
        )
              .b;

    float shape = max(large - medium * 0.4 * clamp(1.5 - large, 0.0, 1.0), 0.0);

    return shape * shape;
}

float cloudCov(
    int layer,
    in vec3 pos,
    vec3 samplePos,
    float minHeight,
    float maxHeight
) {
    float FinalCloudCoverage = 0.0;
    float coverage = 0.0;
    float Topshape = 0.0;
    float Baseshape = 0.0;

    vec2 SampleCoords0 = vec2(0.0);
    vec2 SampleCoords1 = vec2(0.0);
    float CloudSmall = 0.0;

    if (layer == 0) {
        SampleCoords0 = (samplePos.xz + cloud_movement) / 5000.0;
        SampleCoords1 = (samplePos.xz - cloud_movement) / 500.0;
        CloudSmall = texture(CLOUD_NOISETEX, SampleCoords1).r;
    }

    if (layer == 1) {
        SampleCoords0 = -((samplePos.zx + cloud_movement * 2.0) / 10000.0);
        SampleCoords1 = -((samplePos.zx - cloud_movement * 2.0) / 2500.0);
        CloudSmall = texture(CLOUD_NOISETEX, SampleCoords1).b;
    }

    float CloudLarge = texture(CLOUD_NOISETEX, SampleCoords0).b;

    if (layer == 0) {
        coverage = abs(CloudLarge * 2.0 - 1.2) * 0.5 - (1.0 - CloudSmall);

        float layer0 = min(
            min(coverage + LAYER0_COVERAGE,
                clamp(maxHeight - pos.y, 0.0, 1.0)),
            1.0 - clamp(minHeight - pos.y, 0.0, 1.0)
        );

        Topshape = max(pos.y - (maxHeight - 75.0), 0.0) / 200.0;
        Topshape += max(pos.y - (maxHeight - 10.0), 0.0) / 15.0;
        Baseshape = max(minHeight + 12.5 - pos.y, 0.0) / 50.0;

        FinalCloudCoverage
            = max(layer0 - Topshape - Baseshape * (1.0 - rainStrength), 0.0);
    }

    if (layer == 1) {
        coverage = abs(CloudLarge - 0.8) - CloudSmall;

        float layer1 = min(
            min(coverage + LAYER1_COVERAGE - 0.5,
                clamp(maxHeight - pos.y, 0.0, 1.0)),
            1.0 - clamp(minHeight - pos.y, 0.0, 1.0)
        );

        Topshape = max(pos.y - (maxHeight - 75.0), 0.0) / 200.0;
        Topshape += max(pos.y - (maxHeight - 10.0), 0.0) / 15.0;
        Baseshape = max(minHeight + 15.5 - pos.y, 0.0) / 50.0;

        FinalCloudCoverage = max(
            layer1 - Topshape * Topshape - Baseshape * (1.0 - rainStrength),
            0.0
        );
    }

    return FinalCloudCoverage;
}

// Erode coverage with the pseudo-3D noise; the actual cloud density value
float cloudVol(
    int layer,
    in vec3 pos,
    in vec3 samplePos,
    in float cov,
    in int LoD,
    float minHeight,
    float maxHeight
) {
    float otherlayer
        = max(pos.y - (CloudLayer0_height + 99.5), 0.0) > 0.0 ? 0.0 : 1.0;
    float upperPlane = otherlayer;

    float noise = 0.0;

    samplePos.xz -= cloud_movement / 4.0;
    samplePos.xz += pow(max(pos.y - (minHeight + 20.0), 0.0) / 20.0, 1.50);

    noise += (1.0 - densityAtPos(samplePos * mix(100.0, 200.0, upperPlane)))
        * sqrt(1.0 - cov);

    if (LoD > 0) {
        noise
            += abs(densityAtPos(samplePos * mix(450.0, 600.0, upperPlane))
                   - (1.0 - clamp((maxHeight - pos.y) / 100.0, 0.0, 1.0)))
            * 0.75 * (1.0 - cov);
    }

    noise = noise * noise;
    float cloud = max(cov - noise * noise * fbmAmount, 0.0);

    return cloud;
}

float GetCumulusDensity(
    int layer,
    in vec3 pos,
    in int LoD,
    float minHeight,
    float maxHeight
) {
    vec3 samplePos = pos * vec3(1.0, 1.0 / 48.0, 1.0) / 4.0;

    float coverageSP = cloudCov(layer, pos, samplePos, minHeight, maxHeight);

    if (coverageSP > 0.001) {
        if (LoD < 0) {
            return max(coverageSP - 0.27 * fbmAmount, 0.0);
        }
        return cloudVol(layer, pos, samplePos, coverageSP, LoD, minHeight,
                        maxHeight);
    } else {
        return 0.0;
    }
}

// ----------------------------------------------------------------------------
//   Cloud shadows (sampled by the p0 shadow-map generator)
// ----------------------------------------------------------------------------

// Density-to-transmittance along light_dir from a world position.
// x = all layers, y = cumulus layers only.
// CLOUD_SHADOWS_INTENSITY is applied by the consumer, get_cloud_shadows().
vec2 cloud_shadow_map_values(vec3 playerPos) {
    float cumulus = 0.0;

#ifdef CloudLayer0
    vec3 lowShadowStart = playerPos
        + (light_dir / max(abs(light_dir.y), 0.02))
            * max((CloudLayer0_height + 30.0) - playerPos.y, 0.0);
    cumulus += GetCumulusDensity(0, lowShadowStart, 0, CloudLayer0_height,
                                 CloudLayer0_height + 100.0)
        * LAYER0_DENSITY;
#endif
#ifdef CloudLayer1
    vec3 higherShadowStart = playerPos
        + (light_dir / max(abs(light_dir.y), 0.02))
            * max((CloudLayer1_height + 50.0) - playerPos.y, 0.0);
    cumulus += GetCumulusDensity(1, higherShadowStart, 0, CloudLayer1_height,
                                 CloudLayer1_height + 100.0)
        * LAYER1_DENSITY;
#endif

    float all_layers = cumulus;

#ifdef CloudLayer2
    vec3 highShadowStart = playerPos
        + (light_dir / max(abs(light_dir.y), 0.02))
            * max(CloudLayer2_height - playerPos.y, 0.0);
    all_layers += GetAltostratusDensity(highShadowStart) * CloudLayer2_density
        * (1.0 - abs(light_dir.y));
#endif

    all_layers = clamp(all_layers, 0.0, 1.0);
    cumulus = clamp(cumulus, 0.0, 1.0);

    return exp2(vec2(all_layers * all_layers, cumulus * cumulus) * -100.0);
}

// ----------------------------------------------------------------------------
//   Rendering
// ----------------------------------------------------------------------------

#ifndef CLOUDS_SHADOW_FUNCTIONS_ONLY

// Mie phase function (identical to henyey_greenstein_phase; kept local so the
// field code is self-contained)
float phaseg(float x, float g) {
    float gg = g * g;
    return (gg * -0.25 + 0.25) * pow(-2.0 * (g * x) + (gg + 1.0), -1.5) / 3.14;
}

vec3 DoCloudLighting(
    float density,
    vec3 skyLightCol,
    float skyScatter,
    float sunShadows,
    vec3 sunScatter,
    vec3 sunMultiScatter,
    float distantfog
) {
    float powder = 1.0 - exp(-10.0 * density);
    vec3 directLight = sunScatter * exp(-10.0 * sunShadows)
        + sunMultiScatter * exp(-3.0 * sunShadows) * powder;

    vec3 indirectLight = skyLightCol
        * mix(1.0,
              2.0 * (1.0 - sqrt((skyScatter * skyScatter * skyScatter) * density)),
              pow(distantfog, 1.0 - rainStrength * 0.5));

#ifdef CLOUDS_DEBUG_DECOMPOSE
    // False-colour diagnostic (define CLOUDS_DEBUG_DECOMPOSE in settings.glsl;
    // also bypasses the softness mip in sampling.glsl):
    //   R = flat lighting        -> structure here = the density/march itself
    //   G = sun self-shadow term -> structure here = the exp(-10x) direct shading
    //   B = ambient gradient     -> structure here = the skyScatter mix factor
    return vec3(
        0.5,
        0.5 * (exp(-10.0 * sunShadows) + exp(-3.0 * sunShadows) * powder),
        0.25
            * mix(1.0,
                  2.0
                      * (1.0
                         - sqrt((skyScatter * skyScatter * skyScatter)
                                * density)),
                  pow(distantfog, 1.0 - rainStrength * 0.5))
    );
#else
    return directLight + indirectLight;
#endif
}

vec4 renderLayer(
    int layer,
    in vec3 rayProgress,
    in vec3 dV_view,
    in float mult,
    in float dither,
    int QUALITY,
    float minHeight,
    float maxHeight,
    in vec3 dV_Sun,
    float cloudDensity,
    in vec3 skyLightCol,
    in vec3 sunScatter,
    in vec3 sunMultiScatter,
    in float distantfog,
    bool notVisible,
    float lViewPosM,
    inout float dist_sum,
    inout float weight_sum
) {
    vec3 COLOR = vec3(0.0);
    float TOTAL_EXTINCTION = 1.0;
    bool IntersecTerrain = false;

    if (layer == 2) {
        IntersecTerrain = length(rayProgress - cameraPosition) > lViewPosM;

        if (notVisible || IntersecTerrain) {
            return vec4(COLOR, TOTAL_EXTINCTION);
        }

        float signFlip = mix(-1.0, 1.0, clamp(cameraPosition.y - minHeight, 0.0, 1.0));

        if (max(signFlip * normalize(dV_view).y, 0.0) <= 0.0) {
            float altostratus = GetAltostratusDensity(rayProgress);

            float AltoWithDensity = altostratus * cloudDensity;

            if (altostratus > 1e-5) {
                float muE = altostratus * cloudDensity;

                float directLight = 0.0;
                for (int j = 0; j < 2; j++) {
                    // lower the step size as the sun gets higher in the sky
                    vec3 shadowSamplePos_high = rayProgress
                        + dV_Sun * (1.0 + j * dither)
                            / (pow(abs(dV_Sun.y * 0.5), 3.0) * 0.995 + 0.005);

                    // lower density as the sun gets higher in the sky
                    directLight += GetAltostratusDensity(shadowSamplePos_high)
                        * cloudDensity * (1.0 - abs(dV_Sun.y));
                }

                vec3 lighting = DoCloudLighting(
                    AltoWithDensity, skyLightCol, 0.5, directLight, sunScatter,
                    sunMultiScatter, distantfog
                );

                float added_opacity
                    = TOTAL_EXTINCTION * (1.0 - exp(-mult * muE));
                dist_sum += added_opacity * length(rayProgress - cameraPosition);
                weight_sum += added_opacity;

                COLOR += max(lighting - lighting * exp(-mult * muE), 0.0)
                    * TOTAL_EXTINCTION;
                TOTAL_EXTINCTION *= max(exp(-mult * muE), 0.0);
            }
        }

        return vec4(COLOR, TOTAL_EXTINCTION);

    } else {
#if defined CloudLayer1 && defined CloudLayer0
        float upperLayerOcclusion = layer == 0
            ? GetCumulusDensity(
                  1,
                  rayProgress
                      + vec3(0.0, 1.0, 0.0)
                          * max((LAYER1_minHEIGHT + 70.0 * dither)
                                    - rayProgress.y,
                                0.0),
                  0, LAYER1_minHEIGHT, LAYER1_maxHEIGHT
              )
            : 0.0;
        float skylightOcclusion = mix(
            1.0,
            (1.0 - LAYER1_DENSITY) * 0.8 + 0.2,
            (1.0 - exp2(-5.0 * (upperLayerOcclusion * upperLayerOcclusion)))
                * distantfog
        );
#else
        float skylightOcclusion = 1.0;
#endif

        for (int i = 0; i < QUALITY; i++) {
            IntersecTerrain = length(rayProgress - cameraPosition) > lViewPosM;

            // avoid overdraw
            if (notVisible || IntersecTerrain) {
                break;
            }

            // do not sample anything unless within the cloud's bounding box
            if (clamp(rayProgress.y - maxHeight, 0.0, 1.0) < 1.0
                && clamp(rayProgress.y - minHeight, 0.0, 1.0) > 0.0) {
                float cumulus = GetCumulusDensity(layer, rayProgress, 1,
                                                  minHeight, maxHeight);
                float fadedDensity = cloudDensity
                    * pow(clamp((rayProgress.y - minHeight) / 25.0, 0.0, 1.0),
                          2.0);
                float CumulusWithDensity = cloudDensity * cumulus;

                // make sure no work is done on pixels with no densities
                if (CumulusWithDensity > 1e-5) {
                    float muE = cumulus * fadedDensity;

                    float directLight = 0.0;
                    for (int j = 0; j < 3; j++) {
                        vec3 shadowSamplePos = rayProgress
                            + dV_Sun * (20.0 + j * (20.0 + dither * 20.0));
                        directLight
                            += GetCumulusDensity(layer, shadowSamplePos, 0,
                                                 minHeight, maxHeight)
                            * cloudDensity;
                    }

                    // shadows cast from one layer to another
                    // small cumulus -> large cumulus
#if defined CloudLayer1 && defined CloudLayer0
                    if (layer == 0) {
                        directLight += LAYER1_DENSITY * 2.0
                            * GetCumulusDensity(
                                1,
                                rayProgress
                                    + dV_Sun / max(abs(dV_Sun.y), 0.02)
                                        * max((LAYER1_minHEIGHT + 70.0 * dither)
                                                  - rayProgress.y,
                                              0.0),
                                0, LAYER1_minHEIGHT, LAYER1_maxHEIGHT
                            );
                    }
#endif
                    // altostratus -> cumulus
#ifdef CloudLayer2
                    vec3 HighAlt_shadowPos = rayProgress
                        + dV_Sun / max(abs(dV_Sun.y), 0.02)
                            * max(LAYER2_HEIGHT - rayProgress.y, 0.0);
                    float HighAlt_shadow
                        = GetAltostratusDensity(HighAlt_shadowPos)
                        * CloudLayer2_density * (1.0 - abs(light_dir.y));
                    directLight += HighAlt_shadow;
#endif

                    // linear gradient from bottom to top of the cloud layer
                    float skyScatter = clamp(
                        (maxHeight - rayProgress.y) / 100.0, 0.0, 1.0
                    );
                    vec3 lighting = DoCloudLighting(
                        CumulusWithDensity, skyLightCol * skylightOcclusion,
                        skyScatter, directLight, sunScatter, sunMultiScatter,
                        distantfog
                    );

                    float added_opacity
                        = TOTAL_EXTINCTION * (1.0 - exp(-mult * muE));
                    dist_sum
                        += added_opacity * length(rayProgress - cameraPosition);
                    weight_sum += added_opacity;

                    COLOR += max(lighting - lighting * exp(-mult * muE), 0.0)
                        * TOTAL_EXTINCTION;
                    TOTAL_EXTINCTION *= max(exp(-mult * muE), 0.0);

                    if (TOTAL_EXTINCTION < 1e-5) {
                        break;
                    }
                }
            }

            rayProgress += dV_view;
        }

        return vec4(COLOR, TOTAL_EXTINCTION);
    }
}

vec3 layerStartingPosition(
    vec3 dV_view,
    vec3 cameraPos,
    float dither,
    float minHeight,
    float maxHeight
) {
    // allow passing through/above/below the plane without limits
    float flip = mix(max(cameraPos.y - maxHeight, 0.0),
                     max(minHeight - cameraPos.y, 0.0),
                     clamp(dV_view.y, 0.0, 1.0));

    // orient the ray to be a flat plane facing up/down
    vec3 position = dV_view * dither + cameraPos + (dV_view / abs(dV_view.y)) * flip;

    return position;
}

CloudsResult renderClouds(
    vec3 ray_dir, // world-space unit view direction
    float distance_to_terrain, // real blocks; < 0 when the ray hits sky
    vec2 Dither
) {
    float total_extinction = 1.0;
    vec3 color = vec3(0.0);
    float dist_sum = 0.0;
    float weight_sum = 0.0;

    float heightRelativeToClouds = clamp(
        1.0 - max(cameraPosition.y - LAYER0_minHEIGHT, 0.0) / 100.0, 0.0, 1.0
    );

    //////////////////////////////////////////
    ////// Raymarching stuff
    //////////////////////////////////////////

    int maxIT_clouds = int(clamp(
        float(minRayMarchSteps) / sqrt(exp2(ray_dir.y)),
        0.0,
        float(maxRayMarchSteps)
    ));

    vec3 dV_view = ray_dir;

    // cloud curvature
    dV_view.y += 0.025 * heightRelativeToClouds;

    // keep the ray numerically off-horizontal: the 1/|y| slab projections
    // below go infinite at y == 0, and a single non-finite sky-map texel
    // poisons the d4a ambient-SH integral (screen-wide washout)
    dV_view.y = (dV_view.y >= 0.0 ? 1.0 : -1.0) * max(abs(dV_view.y), 0.01);

    vec3 dV_view_Alto = dV_view;
    dV_view_Alto *= 5.0 / abs(dV_view_Alto.y);
    float mult_alto = length(dV_view_Alto);

    vec3 dV_viewTEST = dV_view * (90.0 / abs(dV_view.y) / maxIT_clouds);
    float mult = length(dV_viewTEST);

    // terrain occlusion for the marches (d1 already caps
    // and LoD-extends the distance, so no far-plane special case here)
    float lViewPosM = distance_to_terrain > 0.0
        ? distance_to_terrain - 1.0
        : 100000000.0;

    //////////////////////////////////////////
    ////// lighting stuff
    //////////////////////////////////////////

    // light_dir is the active shadow light (sun by day, moon by night);
    // colors follow the same flip.
    //
    // Scale bridge: the cloud lighting formulas below expect dimmer inputs
    // than the pack's raw sun/sky colors — sky_color carries a tau*1.13
    // surface-ambient boost from the vertex stage, and the scattering sums
    // (the pi/2pi-weighted mie terms, the raw indirect term) amplify the
    // inputs a further ~7-9x. rcp(tau * 1.13) brings the deck back in line
    // with the sky's own brightness. Adjust HERE if the deck sits too bright
    // or too dark against the sky — never in the field math.
    float light_scale = rcp(tau * 1.13);

    vec3 dV_Sun = light_dir;
    // Fade the direct light out as its source nears the horizon, matching the
    // terrain light color (clamp01(light_dir.y / 0.02)). sun_color and
    // moon_color are raw exposure*tint with no horizon falloff, and light_dir /
    // the color flip at the sunAngle day-night threshold; without the fade the
    // deck snaps from dim moonlight straight to full (blue-hour-boosted)
    // sunlight the instant that flip happens at dawn/dusk, instead of ramping
    // through the horizon as both sources sit at y = 0.
    float light_horizon_fade = clamp01(rcp(0.02) * light_dir.y);
    vec3 LightColor = (sunAngle < 0.5 ? sun_color : moon_color) * light_scale
        * light_horizon_fade;
    vec3 SkyColor = sky_color * light_scale;

    float SdotV = dot(light_dir, ray_dir);

    float mieDay = phaseg(SdotV, 0.85) + phaseg(SdotV, 0.75);
    float mieDayMulti = (phaseg(SdotV, 0.35) + phaseg(-SdotV, 0.35) * 0.5);

    vec3 directScattering = LightColor * mieDay * 3.14;
    vec3 directMultiScattering = LightColor * mieDayMulti * 3.14 * 2.0;

    // use this to blend into the atmosphere's ground
    vec3 approxdistance = normalize(dV_viewTEST);
#ifdef SKY_GROUND
    float distantfog = mix(
        1.0,
        max(1.0
                - clamp(exp2(pow(abs(approxdistance.y),
                                 mix(1.5, 4.0, rainStrength))
                             * -mix(100.0, 35.0, rainStrength)),
                        0.0, 1.0),
            0.0),
        heightRelativeToClouds
    );
#else
    float distantfog = 1.0;
    float distantfog2 = mix(
        1.0,
        max(1.0 - clamp(exp(pow(abs(approxdistance.y), 1.5) * -35.0), 0.0, 1.0),
            0.0),
        heightRelativeToClouds
    );
#endif

    // approximate rayleigh scattering (coefficients 5.8 / 1.35 / 3.31)
    vec3 rC = vec3(5.8e-6, 1.35e-5, 3.31e-5) * 3.0;
    float atmosphere = exp(abs(approxdistance.y) * -5.0);
    vec3 scatter = distantfog * exp(-10000.0 * rC * atmosphere);

    directScattering *= scatter;
    directMultiScattering *= scatter;

    SkyColor *= mix(
        1.0,
        1.0 - pow(1.0 - clamp(sun_dir.y, 0.0, 1.0), 5.0) * 0.75 + 0.25,
        distantfog
    );

    //////////////////////////////////////////
    ////// render the cloud layers and do the blending orders
    //////////////////////////////////////////

    float MinHeight = LAYER0_minHEIGHT;
    float MaxHeight = LAYER0_maxHEIGHT;

    float MinHeight1 = LAYER1_minHEIGHT;
    float MaxHeight1 = LAYER1_maxHEIGHT;

    float Height2 = LAYER2_HEIGHT;

    int below_Layer0 = int(clamp(MaxHeight - cameraPosition.y, 0.0, 1.0));
    bool below_Layer1 = clamp(cameraPosition.y - MinHeight1, 0.0, 1.0) < 1.0;
    bool below_Layer2 = clamp(cameraPosition.y - Height2, 0.0, 1.0) < 1.0;

    bool altoNotVisible = false;

#ifdef CloudLayer0
    vec3 layer0_dV_view
        = dV_view * (LAYER0_width / abs(dV_view.y) / maxIT_clouds);
    vec3 layer0_start = layerStartingPosition(
        layer0_dV_view, cameraPosition, Dither.y, MinHeight, MaxHeight
    );
#endif

#ifdef CloudLayer1
    vec3 layer1_dV_view
        = dV_view * (LAYER1_width / abs(dV_view.y) / maxIT_clouds);
    vec3 layer1_start = layerStartingPosition(
        layer1_dV_view, cameraPosition, Dither.y, MinHeight1, MaxHeight1
    );
#endif
#ifdef CloudLayer2
    vec3 layer2_start = layerStartingPosition(
        dV_view_Alto, cameraPosition, Dither.y, Height2, Height2
    );
#endif

#ifdef CloudLayer0
    vec4 layer0 = renderLayer(
        0, layer0_start, layer0_dV_view, mult, Dither.x, maxIT_clouds,
        MinHeight, MaxHeight, dV_Sun, LAYER0_DENSITY, SkyColor,
        directScattering, directMultiScattering, distantfog, false, lViewPosM,
        dist_sum, weight_sum
    );
    total_extinction *= layer0.a;

    // stop overdraw
    bool notVisible = layer0.a < 1e-5 && below_Layer1;
    altoNotVisible = notVisible;
#else
    bool notVisible = false;
#endif

#ifdef CloudLayer1
    vec4 layer1 = renderLayer(
        1, layer1_start, layer1_dV_view, mult, Dither.x, maxIT_clouds,
        MinHeight1, MaxHeight1, dV_Sun, LAYER1_DENSITY, SkyColor,
        directScattering, directMultiScattering, distantfog, notVisible,
        lViewPosM, dist_sum, weight_sum
    );
    total_extinction *= layer1.a;

    // stop overdraw
    altoNotVisible = (layer1.a < 1e-5 || notVisible) && below_Layer1;
#endif

#ifdef CloudLayer2
    vec4 layer2 = renderLayer(
        2, layer2_start, dV_view_Alto, mult_alto, Dither.x, maxIT_clouds,
        Height2, Height2, dV_Sun, LAYER2_DENSITY, SkyColor,
        directScattering * (1.0 + rainStrength * 3.0),
        directMultiScattering * (1.0 + rainStrength * 3.0), distantfog,
        altoNotVisible, lViewPosM, dist_sum, weight_sum
    );
    total_extinction *= layer2.a;
#endif

    /// the blending order changes based on the player's position relative to
    /// the cloud layers; it all revolves around layer 0, the lowest layer.
    /// for layer 1, swap between back-to-front and front-to-back blending
    /// depending on being above or below layer 0; likewise for layer 2 with
    /// respect to layer 1.

    /// blend the altostratus first, so it is BEHIND all the cumulus clouds,
    /// when the player is below the cumulus clouds.
#if !defined CloudLayer1 && defined CloudLayer2
    if (below_Layer2) {
        color = color * layer2.a + layer2.rgb;
    }
#endif
#if defined CloudLayer1 && defined CloudLayer2
    if (below_Layer2) {
        layer1.rgb = layer2.rgb * layer1.a + layer1.rgb;
    }
#endif

    /// blend the cumulus layers together, swapping the order with the player
    /// position relative to the lowest layer.
#if defined CloudLayer0 && defined CloudLayer1
    color = mix(layer0.rgb, layer1.rgb, float(below_Layer0));
    color = mix(color * layer1.a + layer1.rgb, color * layer0.a + layer0.rgb,
                float(below_Layer0));
#endif

    /// handle the case of one of the cumulus layers being disabled.
#if defined CloudLayer0 && !defined CloudLayer1
    color = color * layer0.a + layer0.rgb;
#endif
#if !defined CloudLayer0 && defined CloudLayer1
    color = color * layer1.a + layer1.rgb;
#endif

    /// blend the altostratus last, so it is IN FRONT of all the cumulus
    /// clouds, when the player is above them.
#ifdef CloudLayer2
    if (!below_Layer2) {
        color = color * layer2.a + layer2.rgb;
    }
#endif

    float apparent_distance = weight_sum > 1e-6
        ? dist_sum / weight_sum
        : clouds_not_hit.apparent_distance;

    // scattering.w weights the lightning-flash glow on the cloud deck
#ifdef SKY_GROUND
    return CloudsResult(
        vec4(color, 1.0 - total_extinction),
        total_extinction,
        apparent_distance
    );
#else
    // no sky ground: fade the clouds out toward the horizon so they dissolve
    // into the atmosphere instead of meeting a ground plane
    vec4 faded = mix(vec4(vec3(0.0), 1.0), vec4(color, total_extinction),
                     clamp(distantfog2, 0.0, 1.0));
    return CloudsResult(
        vec4(faded.rgb, 1.0 - faded.a),
        faded.a,
        apparent_distance
    );
#endif
}

CloudsResult draw_clouds(
    vec3 ray_dir,
    float distance_to_terrain,
    float dither
) {
#if !defined CloudLayer0 && !defined CloudLayer1 && !defined CloudLayer2
    return clouds_not_hit;
#else
    return renderClouds(
        ray_dir,
        distance_to_terrain,
        vec2(dither, fract(dither * golden_ratio))
    );
#endif
}

#endif // CLOUDS_SHADOW_FUNCTIONS_ONLY

#endif // INCLUDE_SKY_CLOUDS_FIELD
