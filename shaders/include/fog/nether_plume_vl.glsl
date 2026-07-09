#if !defined INCLUDE_FOG_NETHER_PLUME_VL
#define INCLUDE_FOG_NETHER_PLUME_VL

/*
  Nether volumetrics: a 16-sample exponential march of three layers, together:
    - the lava plumes: dense fog hugging the lava-sea level (y ~ 31) that
      gets wind-sheared upward and eroded into rising wisps, self-shadowed
      and lit lava-orange
    - the haze: a uniform scattering veil tinted by the biome fog color
      (red in the wastes, teal in soul sand valleys), at 0.25
      gain. It scatters but never absorbs, so it reads as ambient glow
      between the plumes rather than opacity — it is also what keeps the
      plumes' high-frequency erosion detail from standing at full contrast
      against dark backdrops
    - the ceiling smoke: a faint layer ramping in above y ~ 40 at
      0.1 brightness, absorbing at half weight so it glows through
      half-occluded fog

  The analytic nether fog (NETHER_FOG, simple_fog.glsl) still provides the
  base distance ambience; these layers sit inside it.
*/

#include "/include/utility/fast_math.glsl"

#include "/include/fog/fog_density_noise.glsl"

// The plume field: dense at the lava sea, wind-sheared upward, eroded into
// wisps; the roof-falloff term is mostly gated away by the height falloff in
// the march below, leaving the floor plumes dominant
float nether_plume_field(in vec3 pos) {
    vec3 samplePos = pos * vec3(1.0, 1.0 / 48.0, 1.0);

    float Wind = pow(max(pos.y - 30.0, 0.0) / 15.0, 2.1);

    float Plumes = texture(CLOUD_NOISETEX, (samplePos.xz + Wind) / 256.0).b;
    float floorPlumes = clamp(0.3 - exp(Plumes * -6.0), 0.0, 1.0);
    Plumes *= Plumes;

    float Erosion = densityAtPosFog(
                        samplePos * 400.0 - frameTimeCounter * 10.0
                        - Wind * 10.0
                    )
            * 0.7
        + 0.3;

    float RoofToFloorDensityFalloff = exp(max(100.0 - pos.y, 0.0) / -15.0);
    float FloorDensityFalloff = pow(exp(max(pos.y - 31.0, 0.0) / -3.0), 2.0);

    return max(
        (RoofToFloorDensityFalloff - Plumes * (1.0 - Erosion)) * 2.0,
        clamp((FloorDensityFalloff - floorPlumes * 0.5) * Erosion, 0.0, 1.0)
    );
}

mat2x3 raymarch_nether_plumes(
    vec3 world_start_pos,
    vec3 world_end_pos,
    bool sky,
    float dither
) {
    vec3 dVWorld = world_end_pos - world_start_pos;

    float maxLength
        = min(length(dVWorld), min(far, 12.0 * 16.0)) / length(dVWorld);
    dVWorld *= maxLength;

    float dL = length(dVWorld);
    const float expFactor = 11.0;
    const int SAMPLECOUNT = 16;

    vec3 color = vec3(0.0);
    float absorbance = 1.0;

    // biome fog chroma at 0.25 gain: the veil is a chroma accent — the
    // nether ambient already carries the biome color at NETHER_S
    // saturation, so a full-strength veil on top drowns the distance in
    // saturated color
    vec3 hazeColor = normalize(fogColor + 1e-6) * 0.25;

    for (int i = 0; i < SAMPLECOUNT; i++) {
        float d = (pow(expFactor, float(i + dither) / float(SAMPLECOUNT))
                       / expFactor
                   - 1.0 / expFactor)
            / (1.0 - 1.0 / expFactor);
        float dd = pow(expFactor, float(i + dither) / float(SAMPLECOUNT))
            * log(expFactor) / float(SAMPLECOUNT) / (expFactor - 1.0);

        vec3 progressW = world_start_pos + d * dVWorld;

#ifdef NETHER_PLUME
        float densityVol = nether_plume_field(progressW);
        float clearArea = 1.0
            - min(max(1.0 - length(progressW - cameraPosition) / 24.0, 0.0),
                  1.0);

        float plumeDensity = min(
            densityVol
                * pow(min(max(100.0 - progressW.y, 0.0) / 30.0, 1.0), 4.0),
            pow(clamp(1.0 - length(progressW - cameraPosition) / far, 0.0, 1.0),
                5.0)
        );
        plumeDensity *= NETHER_PLUME_DENSITY;

        float plumeVolumeCoeff = exp(-plumeDensity * dd * dL);

        // lava-orange, self-shadowed by the plume density itself
        vec3 lighting = vec3(1.0, 0.4, 0.2) * exp(-15.0 * densityVol)
            * (clearArea * clearArea * 0.9 + 0.1);

        color += (lighting - lighting * plumeVolumeCoeff) * absorbance;
        absorbance *= plumeVolumeCoeff;
#endif

#ifdef NETHER_HAZE
        // ------ haze effect
        // the haze does not contribute to absorbance
        float hazeDensity = 0.001 * NETHER_HAZE_DENSITY;
        float hazeVolumeCoeff = exp(-hazeDensity * dd * dL);

        vec3 hazeLighting = hazeColor;

        color += (hazeLighting - hazeLighting * hazeVolumeCoeff) * absorbance;

        // ------ ceiling smoke effect
        // rides the shared haze intensity; the smoke define is a relative trim
        float ceilingSmokeDensity = 0.001
            * pow(min(max(progressW.y - 40.0, 0.0) / 50.0, 1.0), 3.0);
        ceilingSmokeDensity *= NETHER_CEILING_SMOKE_DENSITY * NETHER_HAZE_DENSITY;
        float ceilingSmokeVolumeCoeff = exp(-ceilingSmokeDensity * dd * dL);

        // smoke brightness 0.1 — anything near white washes out the
        // upper nether
        vec3 ceilingSmoke = vec3(0.1);

        color += (ceilingSmoke - ceilingSmoke * ceilingSmokeVolumeCoeff)
            * (absorbance * 0.5 + 0.5);
        absorbance *= ceilingSmokeVolumeCoeff;
#endif
    }

    return mat2x3(color, vec3(absorbance));
}

#endif // INCLUDE_FOG_NETHER_PLUME_VL
